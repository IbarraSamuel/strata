"""Streaming and software-pipelined batch execution with bounded backpressure."""

from __future__ import annotations

import asyncio
import os
from collections import deque
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from typing import TYPE_CHECKING, Any, cast

from strata import mojo_strata
from strata.async_support import arun

if TYPE_CHECKING:
    from collections.abc import AsyncIterable, AsyncIterator, Iterable, Iterator


def _default_in_flight() -> int:
    return min(32, (os.cpu_count() or 1) + 4)


def _invoke_sync(stage: object, item: object) -> object:
    if isinstance(stage, mojo_strata.TaskGroup):
        return stage.call(item)
    if isinstance(stage, mojo_strata.NativeStage):
        return stage.call(item)
    return cast("Any", stage)(item)


def _stream_ordered[I, O](
    stage: object,
    iterator: Iterator[I],
    max_in_flight: int,
) -> Iterator[O]:
    pool = ThreadPoolExecutor(max_workers=max_in_flight)
    pending: deque[Future[object]] = deque()
    exhausted = False
    try:
        while len(pending) < max_in_flight:
            try:
                item = next(iterator)
            except StopIteration:
                exhausted = True
                break
            pending.append(pool.submit(_invoke_sync, stage, item))

        while pending:
            fut = pending.popleft()
            result = cast("O", fut.result())
            if not exhausted:
                try:
                    nxt = next(iterator)
                except StopIteration:
                    exhausted = True
                else:
                    pending.append(pool.submit(_invoke_sync, stage, nxt))
            yield result
    finally:
        for fut in pending:
            fut.cancel()
        pool.shutdown(wait=True, cancel_futures=True)


def _stream_unordered[I, O](
    stage: object,
    iterator: Iterator[I],
    max_in_flight: int,
) -> Iterator[O]:
    pool = ThreadPoolExecutor(max_workers=max_in_flight)
    pending: set[Future[object]] = set()
    exhausted = False
    try:
        while len(pending) < max_in_flight:
            try:
                item = next(iterator)
            except StopIteration:
                exhausted = True
                break
            pending.add(pool.submit(_invoke_sync, stage, item))

        while pending:
            done, pending = wait(pending, return_when=FIRST_COMPLETED)
            for fut in done:
                result = cast("O", fut.result())
                if not exhausted:
                    try:
                        nxt = next(iterator)
                    except StopIteration:
                        exhausted = True
                    else:
                        pending.add(pool.submit(_invoke_sync, stage, nxt))
                yield result
    finally:
        for fut in pending:
            fut.cancel()
        pool.shutdown(wait=True, cancel_futures=True)


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
    if max_in_flight == 1:
        for item in items:
            yield cast("O", _invoke_sync(stage, item))
        return
    iterator = iter(items)
    if ordered:
        yield from _stream_ordered(stage, iterator, max_in_flight)
    else:
        yield from _stream_unordered(stage, iterator, max_in_flight)


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
    """
    limit = max_in_flight if max_in_flight > 0 else _default_in_flight()
    return list(stream_stage(stage, items, max_in_flight=limit, ordered=True))


async def _anext_item[I](
    source: Iterable[I] | AsyncIterable[I],
) -> AsyncIterator[I]:
    if hasattr(source, "__aiter__"):
        async for item in cast("AsyncIterable[I]", source):
            yield item
    else:
        for item in cast("Iterable[I]", source):
            yield item


async def _cancel_tasks(tasks: Iterable[asyncio.Task[object]]) -> None:
    pending = list(tasks)
    for t in pending:
        if not t.done():
            t.cancel()
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


async def _astream_ordered[I, O](
    stage: object,
    async_iter: AsyncIterator[I],
    max_in_flight: int,
) -> AsyncIterator[O]:
    pending: deque[asyncio.Task[object]] = deque()
    exhausted = False
    try:
        while len(pending) < max_in_flight:
            try:
                item = await anext(async_iter)
            except StopAsyncIteration:
                exhausted = True
                break
            pending.append(asyncio.create_task(arun(stage, item)))

        while pending:
            task_obj = pending.popleft()
            result = cast("O", await task_obj)
            if not exhausted:
                try:
                    nxt = await anext(async_iter)
                except StopAsyncIteration:
                    exhausted = True
                else:
                    pending.append(asyncio.create_task(arun(stage, nxt)))
            yield result
    finally:
        await _cancel_tasks(pending)


async def _astream_unordered[I, O](
    stage: object,
    async_iter: AsyncIterator[I],
    max_in_flight: int,
) -> AsyncIterator[O]:
    pending: set[asyncio.Task[object]] = set()
    exhausted = False
    try:
        while len(pending) < max_in_flight:
            try:
                item = await anext(async_iter)
            except StopAsyncIteration:
                exhausted = True
                break
            pending.add(asyncio.create_task(arun(stage, item)))

        while pending:
            done, pending = await asyncio.wait(
                pending, return_when=asyncio.FIRST_COMPLETED
            )
            for task_obj in done:
                result = cast("O", await task_obj)
                if not exhausted:
                    try:
                        nxt = await anext(async_iter)
                    except StopAsyncIteration:
                        exhausted = True
                    else:
                        pending.add(asyncio.create_task(arun(stage, nxt)))
                yield result
    finally:
        await _cancel_tasks(pending)


async def astream_stage[I, O](
    stage: Any,  # ruff: ignore[any-type]
    items: Iterable[I] | AsyncIterable[I],
    *,
    max_in_flight: int = 8,
    ordered: bool = True,
) -> AsyncIterator[O]:
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
    async_iter = _anext_item(items)
    if max_in_flight == 1:
        async for item in async_iter:
            yield await arun(stage, item)
        return
    if ordered:
        async for out in _astream_ordered(stage, async_iter, max_in_flight):
            yield cast("O", out)
    else:
        async for out in _astream_unordered(stage, async_iter, max_in_flight):
            yield cast("O", out)
