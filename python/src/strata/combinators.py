"""Dataflow and resilience combinators for Python Strata pipelines."""

from __future__ import annotations

from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeoutError
from time import sleep
from typing import TYPE_CHECKING, Any, Literal, cast, overload, override

from strata import mojo_strata
from strata.graph import Combinable, GroupMode, Task, TaskGroup, _Stage

if TYPE_CHECKING:
    from collections.abc import Callable


def _call_stage[I, O](stage: _Stage[I, O], msg: I) -> O:
    if isinstance(stage, mojo_strata.TaskGroup):
        return cast("O", stage.call(msg))
    return stage(msg)


class IdTask[T](Combinable, Task[T, T]):
    """Identity stage returning its input unchanged."""

    @override
    def __call__(self, msg: T, /) -> T:
        return msg


def identity[T]() -> IdTask[T]:
    """Create an identity pass-through stage (`T -> T`).

    Returns
    -------
    IdTask[T]
        Identity stage conforming to `Combinable` and `Task`.
    """
    return IdTask()


class SelectTask[I, O](Combinable, Task[I, O]):
    """Extract element `index` from an input sequence or tuple."""

    index: int

    def __init__(self, index: int) -> None:
        self.index = index

    @override
    def __call__(self, msg: I, /) -> O:
        seq = cast("Sequence[O]", msg)
        return seq[self.index]


@overload
def select[T0](index: Literal[0]) -> SelectTask[tuple[T0, *tuple[Any, ...]], T0]: ...


@overload
def select[T1](
    index: Literal[1],
) -> SelectTask[tuple[Any, T1, *tuple[Any, ...]], T1]: ...


@overload
def select[T2](
    index: Literal[2],
) -> SelectTask[tuple[Any, Any, T2, *tuple[Any, ...]], T2]: ...


@overload
def select(index: int) -> SelectTask[Sequence[Any], Any]: ...


def select(index: int) -> SelectTask[Any, Any]:
    """Create a projection stage selecting element `index` from a tuple or sequence.

    Parameters
    ----------
    index : int
        Zero-based index to extract.

    Returns
    -------
    SelectTask[Any, Any]
        Projection stage conforming to `Combinable`.
    """
    return SelectTask(index)


class SpreadTask[*Ts, O](Combinable, Task[tuple[*Ts], O]):
    """Unpack a tuple input into positional arguments of `inner_fn`."""

    inner_fn: Callable[[*Ts], O]

    def __init__(self, f: Callable[[*Ts], O]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, msg: tuple[*Ts], /) -> O:
        return self.inner_fn(*msg)


def spread[*Ts, O](f: Callable[[*Ts], O]) -> SpreadTask[*Ts, O]:
    """Decorate or wrap a multi-argument function to accept a tuple from `&`.

    Parameters
    ----------
    f : Callable[[*Ts], O]
        Function accepting unpacked positional arguments.

    Returns
    -------
    SpreadTask[*Ts, O]
        Composable stage taking `tuple[*Ts]` and returning `O`.
    """
    return SpreadTask(f)


class _ZipBranch[O]:
    """Internal indexed selector + stage runner for `ZipTask`."""

    index: int
    stage: _Stage[Any, O]

    def __init__(self, index: int, stage: _Stage[Any, O]) -> None:
        self.index = index
        self.stage = stage

    def __call__(self, msg: Sequence[Any], /) -> O:
        return _call_stage(self.stage, msg[self.index])


class ZipTask[I, O](Combinable, Task[I, O]):
    """Parallel product executing each stage on the matching tuple element."""

    stages: tuple[_Stage[Any, Any], ...]
    _runner: mojo_strata.TaskGroup[Any, Any]

    def __init__(self, *stages: _Stage[Any, Any]) -> None:
        if not stages:
            msg = "ZipTask requires at least one stage"
            raise ValueError(msg)
        self.stages = stages
        first_branch: Task[Any, Any] = _ZipBranch(0, stages[0])
        group_inner: mojo_strata.TaskGroup[Any, Any] = mojo_strata.TaskGroup(
            task=first_branch
        )
        for idx in range(1, len(stages)):
            branch_stage: Task[Any, Any] = _ZipBranch(idx, stages[idx])
            group_inner = group_inner.with_task(branch_stage, GroupMode.PARALLEL.value)
        self._runner = group_inner

    @override
    def __call__(self, msg: I, /) -> O:
        if len(self.stages) == 1:
            seq = cast("Sequence[Any]", msg)
            return cast("O", (_call_stage(self.stages[0], seq[0]),))
        return cast("O", self._runner.call(msg))


@overload
def zip_tasks[I1, O1, I2, O2](
    s1: _Stage[I1, O1],
    s2: _Stage[I2, O2],
) -> ZipTask[tuple[I1, I2], tuple[O1, O2]]: ...


@overload
def zip_tasks[I1, O1, I2, O2, I3, O3](
    s1: _Stage[I1, O1],
    s2: _Stage[I2, O2],
    s3: _Stage[I3, O3],
) -> ZipTask[tuple[I1, I2, I3], tuple[O1, O2, O3]]: ...


@overload
def zip_tasks[I1, O1, I2, O2, I3, O3, I4, O4](
    s1: _Stage[I1, O1],
    s2: _Stage[I2, O2],
    s3: _Stage[I3, O3],
    s4: _Stage[I4, O4],
) -> ZipTask[tuple[I1, I2, I3, I4], tuple[O1, O2, O3, O4]]: ...


@overload
def zip_tasks(
    *stages: _Stage[Any, Any],
) -> ZipTask[tuple[Any, ...], tuple[Any, ...]]: ...


def zip_tasks(*stages: _Stage[Any, Any]) -> ZipTask[Any, Any]:
    """Create a parallel product stage `(I1, I2, ...) -> (O1, O2, ...)`.

    Parameters
    ----------
    *stages : _Stage[Any, Any]
        Stages applied concurrently to the matching elements of the input tuple.

    Returns
    -------
    ZipTask[Any, Any]
        Composable parallel product stage.
    """
    return ZipTask(*stages)


class _MapSlotTask[I, O]:
    """Internal per-index task for executing `MapTask` waves via Mojo `TaskGroup`."""

    stage: _Stage[I, O]
    index: int

    def __init__(self, stage: _Stage[I, O], index: int) -> None:
        self.stage = stage
        self.index = index

    def __call__(self, items: Sequence[I], /) -> O:
        return _call_stage(self.stage, items[self.index])


class MapTask[I, O](Combinable, Task[Sequence[I], list[O]]):
    """Dynamic parallel map applying `stage` to every item of a sequence."""

    stage: _Stage[I, O]
    max_concurrency: int

    def __init__(self, stage: _Stage[I, O], *, max_concurrency: int = 0) -> None:
        self.stage = stage
        self.max_concurrency = max(max_concurrency, 0)

    @override
    def __call__(self, items: Sequence[I], /) -> list[O]:
        total = len(items)
        if total == 0:
            return []
        if total == 1 or self.max_concurrency == 1:
            return [_call_stage(self.stage, item) for item in items]

        wave_size = self.max_concurrency if self.max_concurrency > 0 else total
        results: list[O] = []
        for wave_start in range(0, total, wave_size):
            wave_end = min(wave_start + wave_size, total)
            wave_len = wave_end - wave_start
            if wave_len == 1:
                results.append(_call_stage(self.stage, items[wave_start]))
                continue
            first_slot: Task[Sequence[I], O] = _MapSlotTask(self.stage, wave_start)
            tg: mojo_strata.TaskGroup[Sequence[I], Any] = TaskGroup(first_slot).inner
            for idx in range(wave_start + 1, wave_end):
                slot_task: Task[Sequence[I], O] = _MapSlotTask(self.stage, idx)
                tg = tg.with_task(slot_task, GroupMode.PARALLEL.value)
            wave_out = cast("tuple[O, ...]", tg.call(items))
            results.extend(wave_out)
        return results


def map_task[I, O](
    stage: _Stage[I, O],
    *,
    max_concurrency: int = 0,
) -> MapTask[I, O]:
    """Lift a stage `I -> O` into a dynamic parallel `MapTask`.

    Parameters
    ----------
    stage : _Stage[I, O]
        Element-wise stage to apply to every item.
    max_concurrency : int, optional
        Maximum items executed concurrently per wave (`0` means unbounded).

    Returns
    -------
    MapTask[I, O]
        Composable dynamic parallel map stage (`Sequence[I] -> list[O]`).
    """
    return MapTask(stage, max_concurrency=max_concurrency)


class BranchTask[I, O](Combinable, Task[I, O]):
    """Conditional routing stage dispatching between `on_true` and `on_false`."""

    predicate: Callable[[I], bool]
    on_true: _Stage[I, O]
    on_false: _Stage[I, O]

    def __init__(
        self,
        predicate: Callable[[I], bool],
        on_true: _Stage[I, O],
        on_false: _Stage[I, O],
    ) -> None:
        self.predicate = predicate
        self.on_true = on_true
        self.on_false = on_false

    @override
    def __call__(self, msg: I, /) -> O:
        if self.predicate(msg):
            return _call_stage(self.on_true, msg)
        return _call_stage(self.on_false, msg)


def branch[I, O](
    predicate: Callable[[I], bool],
    on_true: _Stage[I, O],
    on_false: _Stage[I, O],
) -> BranchTask[I, O]:
    """Create a conditional routing stage.

    Parameters
    ----------
    predicate : Callable[[I], bool]
        Predicate evaluated on each input.
    on_true : _Stage[I, O]
        Stage executed when `predicate(msg)` is truthy.
    on_false : _Stage[I, O]
        Stage executed when `predicate(msg)` is falsy.

    Returns
    -------
    BranchTask[I, O]
        Composable conditional router.
    """
    return BranchTask(predicate, on_true, on_false)


class RetryTask[I, O](Combinable, Task[I, O]):
    """Retry a stage on matching exceptions with optional exponential backoff."""

    stage: _Stage[I, O]
    max_attempts: int
    backoff: float
    backoff_multiplier: float
    retry_on: tuple[type[BaseException], ...]

    def __init__(
        self,
        stage: _Stage[I, O],
        *,
        max_attempts: int = 3,
        backoff: float = 0.0,
        backoff_multiplier: float = 2.0,
        retry_on: tuple[type[BaseException], ...] = (Exception,),
    ) -> None:
        self.stage = stage
        self.max_attempts = max(max_attempts, 1)
        self.backoff = max(backoff, 0.0)
        self.backoff_multiplier = backoff_multiplier if backoff_multiplier > 0 else 1.0
        self.retry_on = retry_on

    @override
    def __call__(self, msg: I, /) -> O:
        delay = self.backoff
        for attempt in range(self.max_attempts):
            try:
                return _call_stage(self.stage, msg)
            except self.retry_on:
                if attempt + 1 >= self.max_attempts:
                    raise
                if delay > 0.0:
                    sleep(delay)
                    delay *= self.backoff_multiplier
        msg_0 = "unreachable"
        raise AssertionError(msg_0)  # pragma: no cover


def retry[I, O](
    stage: _Stage[I, O],
    *,
    max_attempts: int = 3,
    backoff: float = 0.0,
    backoff_multiplier: float = 2.0,
    retry_on: tuple[type[BaseException], ...] = (Exception,),
) -> RetryTask[I, O]:
    """Wrap a stage with automatic retry on matching exceptions.

    Parameters
    ----------
    stage : _Stage[I, O]
        Stage to retry on failure.
    max_attempts : int, optional
        Maximum total attempts (`>= 1`).
    backoff : float, optional
        Initial delay in seconds before the first retry.
    backoff_multiplier : float, optional
        Factor multiplying `backoff` after each retry.
    retry_on : tuple[type[BaseException], ...], optional
        Exception classes that trigger a retry.

    Returns
    -------
    RetryTask[I, O]
        Composable retrying stage.
    """
    return RetryTask(
        stage,
        max_attempts=max_attempts,
        backoff=backoff,
        backoff_multiplier=backoff_multiplier,
        retry_on=retry_on,
    )


class FallbackTask[I, O](Combinable, Task[I, O]):
    """Run `secondary` if `primary` raises a matching exception."""

    primary: _Stage[I, O]
    secondary: _Stage[I, O]
    catch: tuple[type[BaseException], ...]

    def __init__(
        self,
        primary: _Stage[I, O],
        secondary: _Stage[I, O],
        *,
        catch: tuple[type[BaseException], ...] = (Exception,),
    ) -> None:
        self.primary = primary
        self.secondary = secondary
        self.catch = catch

    @override
    def __call__(self, msg: I, /) -> O:
        try:
            return _call_stage(self.primary, msg)
        except self.catch:
            return _call_stage(self.secondary, msg)


def fallback[I, O](
    primary: _Stage[I, O],
    secondary: _Stage[I, O],
    *,
    catch: tuple[type[BaseException], ...] = (Exception,),
) -> FallbackTask[I, O]:
    """Run `secondary` when `primary` raises a matching exception.

    Parameters
    ----------
    primary : _Stage[I, O]
        Primary stage tried first.
    secondary : _Stage[I, O]
        Fallback stage invoked on matching error.
    catch : tuple[type[BaseException], ...], optional
        Exception classes handled by the fallback.

    Returns
    -------
    FallbackTask[I, O]
        Composable fallback stage.
    """
    return FallbackTask(primary, secondary, catch=catch)


class TimeoutTask[I, O](Combinable, Task[I, O]):
    """Enforce a wall-clock timeout on a Python stage."""

    stage: _Stage[I, O]
    seconds: float

    def __init__(self, stage: _Stage[I, O], seconds: float) -> None:
        if seconds <= 0:
            msg = "Timeout seconds must be positive"
            raise ValueError(msg)
        self.stage = stage
        self.seconds = seconds

    @override
    def __call__(self, msg: I, /) -> O:
        pool = ThreadPoolExecutor(max_workers=1)
        future = pool.submit(_call_stage, self.stage, msg)
        try:
            return cast("O", future.result(timeout=self.seconds))
        except FuturesTimeoutError as err:
            future.cancel()
            pool.shutdown(wait=False, cancel_futures=True)
            timeout_msg = f"Stage timed out after {self.seconds}s"
            raise TimeoutError(timeout_msg) from err
        else:
            pool.shutdown(wait=True)


def timeout[I, O](stage: _Stage[I, O], seconds: float) -> TimeoutTask[I, O]:
    """Wrap a stage with a wall-clock `TimeoutError` guard.

    Parameters
    ----------
    stage : _Stage[I, O]
        Stage to bound in time.
    seconds : float
        Maximum allowed duration in seconds (must be positive).

    Returns
    -------
    TimeoutTask[I, O]
        Composable timeout-guarded stage.
    """
    return TimeoutTask(stage, seconds)
