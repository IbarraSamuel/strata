"""Asyncio coroutine task support (`AsyncTask`, `@async_task`, and `arun`)."""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from typing import TYPE_CHECKING, Any, cast, override

from strata import mojo_strata
from strata.combinators import (
    BranchTask,
    FallbackTask,
    MapTask,
    RetryTask,
    TimeoutTask,
    ZipTask,
)
from strata.graph import (
    Combinable,
    GroupedTask,
    GroupMode,
    Task,
    _BaseTaskGroup,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Coroutine, Sequence


class AsyncTask[I, O](Combinable, Task[I, O]):
    """Composable stage wrapping an `async def` coroutine function.

    - Inside synchronous execution (`pipeline(x)` or Mojo `TaskGroup`), runs the
      coroutine via `asyncio.run(...)` on the executing worker thread.
    - Inside async execution (`await arun(pipeline, x)` or `await pipeline.arun(x)`),
      awaits the coroutine directly on the caller's active asyncio event loop.
    """

    inner_fn: Callable[[I], Coroutine[Any, Any, O]]

    def __init__(self, f: Callable[[I], Coroutine[Any, Any, O]]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, msg: I, /) -> O:
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            return asyncio.run(self.inner_fn(msg))
        with ThreadPoolExecutor(max_workers=1) as pool:
            return cast("O", pool.submit(asyncio.run, self.inner_fn(msg)).result())

    async def arun_direct(self, msg: I, /) -> O:
        """Await the underlying coroutine directly on the active event loop.

        Parameters
        ----------
        msg : I
            Input value passed to the coroutine function.

        Returns
        -------
        O
            Coroutine return value.
        """
        return await self.inner_fn(msg)


def async_task[I, O](
    f: Callable[[I], Coroutine[Any, Any, O]],
) -> AsyncTask[I, O]:
    """Decorate or wrap an `async def` function as a composable `AsyncTask`.

    Parameters
    ----------
    f : Callable[[I], Coroutine[Any, Any, O]]
        Single-argument coroutine function.

    Returns
    -------
    AsyncTask[I, O]
        Composable async stage supporting `|`, `&`, sync call, and `arun`.
    """
    return AsyncTask(f)


def _unwrap_group(obj: object) -> mojo_strata.TaskGroup[Any, Any] | None:
    if isinstance(obj, _BaseTaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj.inner)
    if isinstance(obj, mojo_strata.TaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj)
    return None


async def _gather_parallel(
    coros: Sequence[Coroutine[Any, Any, object]],
) -> tuple[object, ...]:
    raw_results = await asyncio.gather(*coros, return_exceptions=True)
    errors = [r for r in raw_results if isinstance(r, BaseException)]
    if len(errors) == 1:
        raise errors[0]
    if len(errors) > 1:
        msg = "Parallel task failures"
        raise BaseExceptionGroup(msg, errors)
    return tuple(raw_results)


async def _arun_group(
    tg: mojo_strata.TaskGroup[Any, Any],
    msg: object,
) -> object:
    mode = tg.get_mode()
    children = tg.get_tasks()
    if not children:
        return msg
    if mode == GroupMode.PARALLEL.value:
        return await _gather_parallel([_arun_node(c, msg) for c in children])
    val = msg
    for child in children:
        val = await _arun_node(child, val)
    return val


async def _arun_map(stage: MapTask[Any, Any], msg: object) -> list[object]:
    items = cast("Sequence[object]", msg)
    if not items:
        return []
    if stage.max_concurrency == 1 or len(items) == 1:
        return [await _arun_node(stage.stage, item) for item in items]
    if stage.max_concurrency <= 0:
        res = await _gather_parallel([_arun_node(stage.stage, item) for item in items])
        return list(res)

    sem = asyncio.Semaphore(stage.max_concurrency)

    async def _bounded(item: object) -> object:
        async with sem:
            return await _arun_node(stage.stage, item)

    res = await _gather_parallel([_bounded(item) for item in items])
    return list(res)


async def _arun_retry(stage: RetryTask[Any, Any], msg: object) -> object:
    delay = stage.backoff
    for attempt in range(stage.max_attempts):
        try:
            return await _arun_node(stage.stage, msg)
        except stage.retry_on:
            if attempt + 1 >= stage.max_attempts:
                raise
            if delay > 0.0:
                await asyncio.sleep(delay)
                delay *= stage.backoff_multiplier
    err_msg = "unreachable"
    raise AssertionError(err_msg)  # pragma: no cover


async def _arun_zip(stage: ZipTask[Any, Any], msg: object) -> object:
    seq = cast("Sequence[object]", msg)
    coros = [_arun_node(child, seq[i]) for i, child in enumerate(stage.stages)]
    return await _gather_parallel(coros)


async def _arun_fallback(stage: FallbackTask[Any, Any], msg: object) -> object:
    try:
        return await _arun_node(stage.primary, msg)
    except stage.catch:
        return await _arun_node(stage.secondary, msg)


async def _arun_combinator(obj: object, msg: object) -> tuple[bool, object]:
    handlers: dict[type[object], Any] = {
        GroupedTask: lambda o, m: _arun_node(o.inner_stage, m),
        ZipTask: _arun_zip,
        MapTask: _arun_map,
        BranchTask: lambda o, m: _arun_node(
            o.on_true if o.predicate(m) else o.on_false, m
        ),
        RetryTask: _arun_retry,
        FallbackTask: _arun_fallback,
        TimeoutTask: lambda o, m: asyncio.wait_for(_arun_node(o.stage, m), o.seconds),
    }
    handler = handlers.get(type(obj))
    if handler is None:
        return (False, None)
    return (True, await handler(obj, msg))


async def _arun_node(obj: object, msg: object) -> object:
    tg = _unwrap_group(obj)
    if tg is not None:
        return await _arun_group(tg, msg)

    if isinstance(obj, AsyncTask):
        return await obj.arun_direct(msg)

    handled, result = await _arun_combinator(obj, msg)
    if handled:
        return result

    if isinstance(obj, mojo_strata.NativeStage):
        return await asyncio.to_thread(obj.call, msg)

    return await asyncio.to_thread(cast("Any", obj), msg)


async def arun[I, O](stage: Any, msg: I) -> O:  # ruff: ignore[any-type]
    """Execute any Strata task, combinator, or pipeline natively on asyncio.

    `AsyncTask` branches await cooperatively on the active event loop, while
    synchronous Python tasks and GIL-free `NativeTask` stages execute off the
    event loop via `asyncio.to_thread(...)`.

    Parameters
    ----------
    stage : Any
        Composable Strata task, combinator, or pipeline group.
    msg : I
        Input value.

    Returns
    -------
    O
        Pipeline output value.
    """
    return cast("O", await _arun_node(stage, msg))
