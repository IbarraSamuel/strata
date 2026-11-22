from __future__ import annotations

from enum import IntEnum
from typing import TYPE_CHECKING, Any, Protocol, cast, overload, override

from strata import mojo_strata

if TYPE_CHECKING:
    from collections.abc import (
        AsyncIterable,
        AsyncIterator,
        Callable,
        Iterable,
        Iterator,
    )

    from strata.introspect import GraphStats


class GroupMode(IntEnum):
    UNDEFINED = -1
    SERIAL = 0
    PARALLEL = 1


class Task[I, O](Protocol):
    """Protocol representing a single runnable unit of work.

    Classes implementing `Task` must provide a `__call__(self, msg: I, /) -> O` method.
    Tasks can inherit from `Combinable` to support `|` (stream/pipe) and `&` (parallel)
    composition operators.
    """

    def __call__(self, msg: I, /) -> O: ...


type _Stage[I, O] = (
    Task[I, O]
    | ParTaskGroup[I, O]
    | SerTaskGroup[I, O]
    | TaskGroup[I, O]
    | mojo_strata.TaskGroup[I, O]
    | mojo_strata.NativeStage[I, O]
)

type _NonParStage[I, O] = (
    Task[I, O]
    | SerTaskGroup[I, O]
    | TaskGroup[I, O]
    | mojo_strata.TaskGroup[I, O]
    | mojo_strata.NativeStage[I, O]
)


def _resolve_native(obj: object) -> mojo_strata.NativeStage[Any, Any] | None:
    if isinstance(obj, mojo_strata.NativeStage):
        return obj
    inner_native = getattr(obj, "inner_native", None)
    if isinstance(inner_native, mojo_strata.NativeStage):
        return inner_native
    as_capsule = getattr(obj, "as_native_capsule", None)
    if callable(as_capsule):
        cap = as_capsule()
        stage_name = getattr(obj, "__name__", None) or type(obj).__name__
        return mojo_strata.native_from_capsule(cap, str(stage_name))
    if not callable(obj) and not isinstance(obj, mojo_strata.TaskGroup):
        try:
            return mojo_strata.native_from_capsule(obj, "native_capsule")
        except TypeError:
            return None
    return None


def _invoke_stage[I, O](stage: Any, msg: I) -> O:  # ruff: ignore[any-type]
    if isinstance(stage, mojo_strata.TaskGroup):
        return cast("O", stage.call(msg))
    native = _resolve_native(stage)
    if native is not None:
        return cast("O", native.call(msg))
    return cast("O", stage(msg))


def _try_native_map_list(
    stage: object,
    items: Iterable[Any],
    max_concurrency: int,
) -> list[Any] | None:
    native = _resolve_native(stage)
    if native is not None:
        return native.map_list(items, max_concurrency)
    tg: mojo_strata.TaskGroup[Any, Any] | None = None
    if isinstance(stage, _BaseTaskGroup):
        tg = cast("mojo_strata.TaskGroup[Any, Any]", stage.inner)
    elif isinstance(stage, mojo_strata.TaskGroup):
        tg = stage
    if tg is not None and tg.is_pure_native():
        return tg.map_list(items, max_concurrency)
    return None


def _build_task_group(
    tasks: list[Any],
    mode: int,
) -> mojo_strata.TaskGroup[Any, Any]:
    return mojo_strata.TaskGroup.from_tasks(tasks, mode)


class _RuntimeHelpers:
    graph_stats: Callable[[object], GraphStats] | None = None
    to_mermaid: Callable[..., str] | None = None
    to_dot: Callable[..., str] | None = None
    map_stage: Callable[..., list[Any]] | None = None
    stream_stage: Callable[..., Iterator[Any]] | None = None
    arun: Callable[..., Any] | None = None
    astream_stage: Callable[..., AsyncIterator[Any]] | None = None


_HELPERS = _RuntimeHelpers()


def _get_graph_stats_fn() -> Callable[[object], GraphStats]:
    if _HELPERS.graph_stats is None:
        from strata.introspect import (  # ruff: ignore[import-outside-top-level]
            graph_stats,
        )

        _HELPERS.graph_stats = graph_stats
    return _HELPERS.graph_stats


def _get_to_mermaid_fn() -> Callable[..., str]:
    if _HELPERS.to_mermaid is None:
        from strata.introspect import (  # ruff: ignore[import-outside-top-level]
            to_mermaid,
        )

        _HELPERS.to_mermaid = to_mermaid
    return _HELPERS.to_mermaid


def _get_to_dot_fn() -> Callable[..., str]:
    if _HELPERS.to_dot is None:
        from strata.introspect import to_dot  # ruff: ignore[import-outside-top-level]

        _HELPERS.to_dot = to_dot
    return _HELPERS.to_dot


def _get_map_stage_fn() -> Callable[..., list[Any]]:
    if _HELPERS.map_stage is None:
        from strata.streaming import map_stage  # ruff: ignore[import-outside-top-level]

        _HELPERS.map_stage = map_stage
    return _HELPERS.map_stage


def _get_stream_stage_fn() -> Callable[..., Iterator[Any]]:
    if _HELPERS.stream_stage is None:
        from strata.streaming import (  # ruff: ignore[import-outside-top-level]
            stream_stage,
        )

        _HELPERS.stream_stage = stream_stage
    return _HELPERS.stream_stage


def _get_arun_fn() -> Callable[..., Any]:
    if _HELPERS.arun is None:
        from strata.async_support import arun  # ruff: ignore[import-outside-top-level]

        _HELPERS.arun = arun
    return _HELPERS.arun


def _get_astream_stage_fn() -> Callable[..., AsyncIterator[Any]]:
    if _HELPERS.astream_stage is None:
        from strata.streaming import (  # ruff: ignore[import-outside-top-level]
            astream_stage,
        )

        _HELPERS.astream_stage = astream_stage
    return _HELPERS.astream_stage


def _unwrap_target[I, O](
    other: _Stage[I, O],
) -> Task[I, O] | mojo_strata.TaskGroup[I, O] | mojo_strata.NativeStage[I, O]:
    if isinstance(other, _BaseTaskGroup):
        return cast("mojo_strata.TaskGroup[I, O]", other.inner)
    if isinstance(other, mojo_strata.NativeStage):
        return other
    inner_native = getattr(other, "inner_native", None)
    if isinstance(inner_native, mojo_strata.NativeStage):
        return cast("mojo_strata.NativeStage[I, O]", inner_native)
    as_capsule = getattr(other, "as_native_capsule", None)
    if callable(as_capsule):
        cap = as_capsule()
        stage_name = getattr(other, "__name__", None) or type(other).__name__
        return cast(
            "mojo_strata.NativeStage[I, O]",
            mojo_strata.native_from_capsule(cap, str(stage_name)),
        )
    return other


class _BaseTaskGroup[I, O]:
    """Shared base wrapper around an immutable `mojo_strata.TaskGroup`."""

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __call__(self, msg: I, /) -> O:
        return self.inner.call(msg)

    def __or__[T](self, other: _Stage[O, T]) -> SerTaskGroup[I, T]:
        target = _unwrap_target(other)
        return SerTaskGroup[I, T](self.inner.with_task(target, GroupMode.SERIAL.value))

    def stats(self) -> GraphStats:
        """Return static topology metrics for this pipeline.

        Returns
        -------
        GraphStats
            Stage count, maximum parallel width, and critical path depth.
        """
        return _get_graph_stats_fn()(self)

    def to_mermaid(self, *, direction: str = "LR") -> str:
        """Render this pipeline topology as a Mermaid flowchart.

        Parameters
        ----------
        direction : str, optional
            Mermaid flowchart direction (`"LR"`, `"TD"`, etc.).

        Returns
        -------
        str
            Mermaid flowchart source string.
        """
        return _get_to_mermaid_fn()(self, direction=direction)

    def to_dot(self, *, name: str = "Strata", direction: str = "LR") -> str:
        """Render this pipeline topology as Graphviz DOT.

        Parameters
        ----------
        name : str, optional
            Graphviz `digraph` identifier.
        direction : str, optional
            Graphviz `rankdir` (`"LR"`, `"TB"`, etc.).

        Returns
        -------
        str
            Graphviz DOT source string.
        """
        return _get_to_dot_fn()(self, name=name, direction=direction)

    def map(self, items: Iterable[I], *, max_in_flight: int = 0) -> list[O]:
        """Run this pipeline concurrently across `items` and return ordered results.

        Parameters
        ----------
        items : Iterable[I]
            Input items to process.
        max_in_flight : int, optional
            Maximum items active concurrently (`0` chooses a CPU-scaled default).

        Returns
        -------
        list[O]
            Ordered list of pipeline outputs.
        """
        return cast(
            "list[O]", _get_map_stage_fn()(self, items, max_in_flight=max_in_flight)
        )

    def stream(
        self,
        items: Iterable[I],
        *,
        max_in_flight: int = 8,
        ordered: bool = True,
    ) -> Iterator[O]:
        """Stream `items` through this pipeline with bounded backpressure.

        Parameters
        ----------
        items : Iterable[I]
            Input iterable or generator.
        max_in_flight : int, optional
            Maximum items in flight simultaneously (`>= 1`).
        ordered : bool, optional
            Preserve input order (`True`) or yield in completion order (`False`).

        Returns
        -------
        Iterator[O]
            Lazy iterator yielding pipeline outputs.
        """
        return cast(
            "Iterator[O]",
            _get_stream_stage_fn()(
                self,
                items,
                max_in_flight=max_in_flight,
                ordered=ordered,
            ),
        )

    async def arun(self, msg: I, /) -> O:
        """Execute this pipeline natively on the active asyncio event loop.

        Parameters
        ----------
        msg : I
            Input value.

        Returns
        -------
        O
            Pipeline output value.
        """
        return cast("O", await _get_arun_fn()(self, msg))

    def astream(
        self,
        items: Iterable[I] | AsyncIterable[I],
        *,
        max_in_flight: int = 8,
        ordered: bool = True,
    ) -> AsyncIterator[O]:
        """Asynchronously stream `items` through this pipeline with backpressure.

        Parameters
        ----------
        items : Iterable[I] | AsyncIterable[I]
            Input synchronous or asynchronous iterable.
        max_in_flight : int, optional
            Maximum tasks in flight simultaneously (`>= 1`).
        ordered : bool, optional
            Preserve input order (`True`) or yield in completion order (`False`).

        Returns
        -------
        AsyncIterator[O]
            Async iterator yielding pipeline outputs.
        """
        return _get_astream_stage_fn()(
            self,
            items,
            max_in_flight=max_in_flight,
            ordered=ordered,
        )


class SerTaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A series composition of tasks.

    Represents a sequential pipeline where each stage passes its output
    to the next stage. Pipelines are directly callable and immutable under
    further composition.
    """

    @overload
    def __and__[*Os](
        self, other: ParTaskGroup[I, tuple[*Os]]
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[T](self, other: _NonParStage[I, T]) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__(self, other: _Stage[I, object]) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class ParTaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A parallel composition of tasks.

    Represents a flat parallel stage where tasks receive the same input and produce
    a flat tuple of results. Combining with another `ParTaskGroup` via `&` flattens
    associatively into one `TaskGroup`; wrap with `group(...)` to preserve nested
    tuple structure.
    """

    @overload
    def __and__[*Os, T1, T2](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2]]: ...

    @overload
    def __and__[*Os, T1, T2, T3](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2, T3]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2, T3]]: ...

    @overload
    def __and__[*Os, T1, T2, T3, T4](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2, T3, T4]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2, T3, T4]]: ...

    @overload
    def __and__[*Os](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[object, ...]],
    ) -> ParTaskGroup[I, tuple[object, ...]]: ...

    @overload
    def __and__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: _NonParStage[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]: ...

    def __and__(self, other: _Stage[I, object]) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class TaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A single-task or intermediate group wrapper.

    Acts as the entrypoint for composition when lifting a single `Task` into a group.
    Pipelines are directly callable and immutable under further composition.
    """

    def __init__(self, task: _Stage[I, O]) -> None:
        target = _unwrap_target(task)
        super().__init__(mojo_strata.TaskGroup(task=target))

    @overload
    def __and__[*Os](
        self, other: ParTaskGroup[I, tuple[*Os]]
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[T](self, other: _NonParStage[I, T]) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__(self, other: _Stage[I, object]) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class Combinable(Protocol):
    """Protocol / mixin providing pipeline operator overloads (`|`, `&`) for tasks."""

    def __or__[I, O, T](
        self: Task[I, O],
        other: _Stage[O, T],
    ) -> SerTaskGroup[I, T]:
        group_stage = TaskGroup(self)
        return group_stage | other

    @overload
    def __and__[I, O, *Os](
        self: Task[I, O],
        other: ParTaskGroup[I, tuple[*Os]],
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[I, O, T](
        self: Task[I, O],
        other: _NonParStage[I, T],
    ) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__[I, O](
        self: Task[I, O],
        other: _Stage[I, object],
    ) -> ParTaskGroup[I, tuple[object, ...]]:
        group_stage = TaskGroup(self)
        return cast(
            "ParTaskGroup[I, tuple[object, ...]]",
            cast("object", group_stage & other),
        )

    def map[I, O](
        self: Task[I, O],
        items: Iterable[I],
        *,
        max_in_flight: int = 0,
    ) -> list[O]:
        """Run this task concurrently across `items` and return ordered results.

        Parameters
        ----------
        items : Iterable[I]
            Input items to process.
        max_in_flight : int, optional
            Maximum items active concurrently (`0` chooses a CPU-scaled default).

        Returns
        -------
        list[O]
            Ordered list of outputs.
        """
        return cast(
            "list[O]", _get_map_stage_fn()(self, items, max_in_flight=max_in_flight)
        )

    def stream[I, O](
        self: Task[I, O],
        items: Iterable[I],
        *,
        max_in_flight: int = 8,
        ordered: bool = True,
    ) -> Iterator[O]:
        """Stream `items` through this task with bounded backpressure.

        Parameters
        ----------
        items : Iterable[I]
            Input iterable or generator.
        max_in_flight : int, optional
            Maximum items in flight simultaneously (`>= 1`).
        ordered : bool, optional
            Preserve input order (`True`) or yield in completion order (`False`).

        Returns
        -------
        Iterator[O]
            Lazy iterator yielding outputs.
        """
        return cast(
            "Iterator[O]",
            _get_stream_stage_fn()(
                self,
                items,
                max_in_flight=max_in_flight,
                ordered=ordered,
            ),
        )

    async def arun[I, O](self: Task[I, O], msg: I, /) -> O:
        """Execute this task natively on the active asyncio event loop.

        Parameters
        ----------
        msg : I
            Input value.

        Returns
        -------
        O
            Task output value.
        """
        return cast("O", await _get_arun_fn()(self, msg))

    def astream[I, O](
        self: Task[I, O],
        items: Iterable[I] | AsyncIterable[I],
        *,
        max_in_flight: int = 8,
        ordered: bool = True,
    ) -> AsyncIterator[O]:
        """Asynchronously stream `items` through this task with backpressure.

        Parameters
        ----------
        items : Iterable[I] | AsyncIterable[I]
            Input synchronous or asynchronous iterable.
        max_in_flight : int, optional
            Maximum tasks in flight simultaneously (`>= 1`).
        ordered : bool, optional
            Preserve input order (`True`) or yield in completion order (`False`).

        Returns
        -------
        AsyncIterator[O]
            Async iterator yielding outputs.
        """
        return _get_astream_stage_fn()(
            self,
            items,
            max_in_flight=max_in_flight,
            ordered=ordered,
        )


class GroupedTask[I, O](Combinable, Task[I, O]):
    """Opaque wrapper preventing `&` from flattening an inner `ParTaskGroup`.

    Use `group(a & b)` when you explicitly want nested tuple output such as
    `group(a & b) & group(c & d)` -> `tuple[tuple[O1, O2], tuple[O3, O4]]`.
    """

    inner_stage: _Stage[I, O]

    def __init__(self, stage: _Stage[I, O]) -> None:
        self.inner_stage = stage

    @override
    def __call__(self, msg: I, /) -> O:
        return _invoke_stage(self.inner_stage, msg)


def group[I, O](stage: _Stage[I, O]) -> GroupedTask[I, O]:
    """Wrap a stage as an opaque `GroupedTask` so `&` preserves nested tuples.

    Parameters
    ----------
    stage : _Stage[I, O]
        Stage or parallel group to keep nested under `&`.

    Returns
    -------
    GroupedTask[I, O]
        Opaque grouped stage wrapper.
    """
    return GroupedTask(stage)


class FnTask[I, O](Combinable, Task[I, O]):
    inner_fn: Callable[[I], O]

    def __init__(self, f: Callable[[I], O]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, v: I, /) -> O:
        return self.inner_fn(v)


def task[I, O](f: Callable[[I], O]) -> FnTask[I, O]:
    return FnTask(f)
