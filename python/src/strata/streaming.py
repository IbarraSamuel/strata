"""Streaming and software-pipelined batch execution with bounded backpressure."""

from __future__ import annotations

import asyncio
import os
from collections import deque
from collections.abc import Sized
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from typing import TYPE_CHECKING, Any, cast

from strata.async_support import arun
from strata.graph import _invoke_stage, _try_native_map_list

if TYPE_CHECKING:
    from collections.abc import (
        AsyncGenerator,
        AsyncIterable,
        AsyncIterator,
        Iterable,
        Iterator,
    )


def _default_in_flight() -> int:
    return min(32, (os.cpu_count() or 1) + 4)


def _pull_next[I](
    iterator: Iterator[I],
) -> tuple[bool, I | None, Exception | None]:
    try:
        return (True, next(iterator), None)
    except StopIteration:
        return (False, None, None)
    except Exception as exc:  # ruff: ignore[blind-except]
        return (False, None, exc)


async def _apull_next[I](
    async_iter: AsyncIterator[I],
) -> tuple[bool, I | None, Exception | None]:
    try:
        return (True, await anext(async_iter), None)
    except StopAsyncIteration:
        return (False, None, None)
    except Exception as exc:  # ruff: ignore[blind-except]
        return (False, None, exc)


def _close_sync_iter(iterator: object) -> None:
    close_fn = getattr(iterator, "close", None)
    if callable(close_fn):
        close_fn()


async def _close_async_iter(async_iter: object) -> None:
    aclose_fn = getattr(async_iter, "aclose", None)
    if callable(aclose_fn):
        await cast("Any", aclose_fn)()


def _stream_ordered[I, O](
    stage: object,
    iterator: Iterator[I],
    max_in_flight: int,
) -> Iterator[O]:
    pool = ThreadPoolExecutor(max_workers=max_in_flight)
    pending: deque[Future[object]] = deque()
    exhausted = False
    upstream_error: Exception | None = None
    completed = False
    try:
        while len(pending) < max_in_flight:
            has_item, item, err = _pull_next(iterator)
            if not has_item:
                exhausted = True
                upstream_error = err
                break
            pending.append(pool.submit(_invoke_stage, stage, item))

        while pending:
            fut = pending.popleft()
            yield cast("O", fut.result())
            if not exhausted:
                has_item, nxt, err = _pull_next(iterator)
                if not has_item:
                    exhausted = True
                    upstream_error = err
                else:
                    pending.append(pool.submit(_invoke_stage, stage, nxt))

        if upstream_error is not None:
            raise upstream_error
        completed = True
    finally:
        for fut in pending:
            fut.cancel()
        pool.shutdown(wait=completed, cancel_futures=True)


def _stream_unordered[I, O](
    stage: object,
    iterator: Iterator[I],
    max_in_flight: int,
) -> Iterator[O]:
    pool = ThreadPoolExecutor(max_workers=max_in_flight)
    pending: set[Future[object]] = set()
    exhausted = False
    upstream_error: Exception | None = None
    completed = False
    try:
        while len(pending) < max_in_flight:
            has_item, item, err = _pull_next(iterator)
            if not has_item:
                exhausted = True
                upstream_error = err
                break
            pending.add(pool.submit(_invoke_stage, stage, item))

        while pending:
            done, pending = wait(pending, return_when=FIRST_COMPLETED)
            for fut in done:
                yield cast("O", fut.result())
                if not exhausted:
                    has_item, nxt, err = _pull_next(iterator)
                    if not has_item:
                        exhausted = True
                        upstream_error = err
                    else:
                        pending.add(pool.submit(_invoke_stage, stage, nxt))

        if upstream_error is not None:
            raise upstream_error
        completed = True
    finally:
        for fut in pending:
            fut.cancel()
        pool.shutdown(wait=completed, cancel_futures=True)


def stream_stage[I, O](
    stage: Any,  # ruff: ignore[any-type]
    items: Iterable[I],
    *,
    max_in_flight: int = 8,
    ordered: bool = True,
) -> Iterator[O]:
    """Stream `items` through `stage` with bounded sliding-window backpressure.

    At most `max_in_flight` items are pulled from `items` and active at once,
    keeping memory usage `O(max_in_flight)` even for infinite generators.

    Parameters
    ----------
    stage : Any
        Strata task, combinator, or composed pipeline.
    items : Iterable[I]
        Input iterable or generator.
    max_in_flight : int, optional
        Maximum concurrent items in flight (`>= 1`). Defaults to `8`.
    ordered : bool, optional
        If `True` (default), yields outputs in input order. If `False`, yields
        outputs in completion order for lower tail latency.

    Yields
    ------
    O
        Transformed pipeline outputs.

    Raises
    ------
    ValueError
        If `max_in_flight < 1`.
    """
    if max_in_flight < 1:
        msg = "max_in_flight must be >= 1"
        raise ValueError(msg)
    effective_in_flight = max_in_flight
    if isinstance(items, Sized):
        n = len(items)
        if n == 0:
            return
        effective_in_flight = min(max_in_flight, n)
    iterator = iter(items)
    try:
        if effective_in_flight == 1:
            for item in iterator:
                yield _invoke_stage(stage, item)
            return
        if ordered:
            yield from _stream_ordered(stage, iterator, effective_in_flight)
        else:
            yield from _stream_unordered(stage, iterator, effective_in_flight)
    finally:
        _close_sync_iter(iterator)


def map_stage[I, O](
    stage: Any,  # ruff: ignore[any-type]
    items: Iterable[I],
    *,
    max_in_flight: int = 0,
) -> list[O]:
    """Apply `stage` across `items` concurrently and return ordered results.

    Parameters
    ----------
    stage : Any
        Strata task, combinator, or composed pipeline.
    items : Iterable[I]
        Input iterable.
    max_in_flight : int, optional
        Maximum concurrent items in flight (`0` selects a CPU-scaled default).

    Returns
    -------
    list[O]
        Ordered list of transformed results.

    Raises
    ------
    ValueError
        If `max_in_flight < 0`.
    """
    if max_in_flight < 0:
        msg = "max_in_flight must be >= 0"
        raise ValueError(msg)
    sized_items: Iterable[I] = items if isinstance(items, Sized) else list(items)
    n = len(cast("Sized", sized_items))
    if n == 0:
        return []
    if n == 1:
        return [_invoke_stage(stage, next(iter(sized_items)))]
    native_out = _try_native_map_list(stage, sized_items, max_in_flight)
    if native_out is not None:
        return cast("list[O]", native_out)
    limit = max_in_flight if max_in_flight > 0 else _default_in_flight()
    return list(stream_stage(stage, sized_items, max_in_flight=limit, ordered=True))


async def _cancel_tasks(tasks: Iterable[asyncio.Task[object]]) -> None:
    pending = list(tasks)
    for t in pending:
        if not t.done():
            t.cancel()
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


async def _astream_serial[I, O](
    stage: object,
    items: Iterable[I] | AsyncIterable[I],
) -> AsyncGenerator[O]:
    if hasattr(items, "__aiter__"):
        ait = aiter(cast("AsyncIterable[I]", items))
        try:
            async for item in ait:
                yield await arun(stage, item)
        finally:
            await _close_async_iter(ait)
    else:
        sit = iter(cast("Iterable[I]", items))
        try:
            for item in sit:
                yield await arun(stage, item)
        finally:
            _close_sync_iter(sit)


async def _astream_ordered[I, O](
    stage: object,
    items: Iterable[I] | AsyncIterable[I],
    max_in_flight: int,
) -> AsyncGenerator[O]:
    is_async = hasattr(items, "__aiter__")
    ait = aiter(cast("AsyncIterable[I]", items)) if is_async else None
    sit = None if is_async else iter(cast("Iterable[I]", items))
    pending: deque[asyncio.Task[object]] = deque()
    exhausted = False
    upstream_error: Exception | None = None
    try:
        while len(pending) < max_in_flight:
            has_item, item, err = (
                await _apull_next(ait)
                if ait is not None
                else _pull_next(cast("Iterator[I]", sit))
            )
            if not has_item:
                exhausted = True
                upstream_error = err
                break
            pending.append(asyncio.create_task(arun(stage, item)))

        while pending:
            task_obj = pending.popleft()
            yield cast("O", await task_obj)
            if not exhausted:
                has_item, nxt, err = (
                    await _apull_next(ait)
                    if ait is not None
                    else _pull_next(cast("Iterator[I]", sit))
                )
                if not has_item:
                    exhausted = True
                    upstream_error = err
                else:
                    pending.append(asyncio.create_task(arun(stage, nxt)))

        if upstream_error is not None:
            raise upstream_error
    finally:
        await _cancel_tasks(pending)
        if ait is not None:
            await _close_async_iter(ait)
        elif sit is not None:
            _close_sync_iter(sit)


async def _astream_unordered[I, O](
    stage: object,
    items: Iterable[I] | AsyncIterable[I],
    max_in_flight: int,
) -> AsyncGenerator[O]:
    is_async = hasattr(items, "__aiter__")
    ait = aiter(cast("AsyncIterable[I]", items)) if is_async else None
    sit = None if is_async else iter(cast("Iterable[I]", items))
    pending: set[asyncio.Task[object]] = set()
    done: set[asyncio.Task[object]] = set()
    exhausted = False
    upstream_error: Exception | None = None
    try:
        while len(pending) < max_in_flight:
            has_item, item, err = (
                await _apull_next(ait)
                if ait is not None
                else _pull_next(cast("Iterator[I]", sit))
            )
            if not has_item:
                exhausted = True
                upstream_error = err
                break
            pending.add(asyncio.create_task(arun(stage, item)))

        while pending:
            done, pending = await asyncio.wait(
                pending, return_when=asyncio.FIRST_COMPLETED
            )
            while done:
                task_obj = done.pop()
                yield cast("O", await task_obj)
                if not exhausted:
                    has_item, nxt, err = (
                        await _apull_next(ait)
                        if ait is not None
                        else _pull_next(cast("Iterator[I]", sit))
                    )
                    if not has_item:
                        exhausted = True
                        upstream_error = err
                    else:
                        pending.add(asyncio.create_task(arun(stage, nxt)))

        if upstream_error is not None:
            raise upstream_error
    finally:
        await _cancel_tasks(pending | done)
        if ait is not None:
            await _close_async_iter(ait)
        elif sit is not None:
            _close_sync_iter(sit)


def astream_stage[I, O](
    stage: Any,  # ruff: ignore[any-type]
    items: Iterable[I] | AsyncIterable[I],
    *,
    max_in_flight: int = 8,
    ordered: bool = True,
) -> AsyncGenerator[O]:
    """Asynchronously stream `items` through `stage` with bounded backpressure.

    Accepts either a regular synchronous `Iterable[I]` or an `AsyncIterable[I]`.

    Parameters
    ----------
    stage : Any
        Strata task, combinator, or composed pipeline.
    items : Iterable[I] | AsyncIterable[I]
        Input synchronous or asynchronous iterable.
    max_in_flight : int, optional
        Maximum concurrent in-flight tasks (`>= 1`). Defaults to `8`.
    ordered : bool, optional
        If `True` (default), yields outputs in input order; otherwise yields in
        completion order.

    Returns
    -------
    AsyncGenerator[O]
        Async generator yielding transformed pipeline outputs.

    Raises
    ------
    ValueError
        If `max_in_flight < 1`.
    """
    if max_in_flight < 1:
        msg = "max_in_flight must be >= 1"
        raise ValueError(msg)
    if max_in_flight == 1:
        return _astream_serial(stage, items)
    if ordered:
        return _astream_ordered(stage, items, max_in_flight)
    return _astream_unordered(stage, items, max_in_flight)
