"""Tests for Phase 4: hybrid GIL-free Mojo stages, async tasks, and streaming."""

from __future__ import annotations

import asyncio
import time
from typing import TYPE_CHECKING, Any, cast

import pytest

from strata import (
    SequentialExecutor,
    TracingExecutor,
    arun,
    async_task,
    branch,
    fallback,
    graph_stats,
    group,
    is_gil_enabled,
    map_task,
    mojo_strata,
    native_cpu_work,
    native_float_linear,
    native_float_poly,
    native_int_linear,
    native_stage,
    retry,
    runtime_info,
    spread,
    task,
    timeout,
    to_dot,
    to_mermaid,
    zip_tasks,
)

if TYPE_CHECKING:
    from collections.abc import AsyncIterator, Iterator


# ===----------------------------------------------------------------------=== #
# Hybrid GIL-Free Native Mojo Stages & PyCapsule Protocol
# ===----------------------------------------------------------------------=== #


def test_native_stage_direct_and_fused_serial() -> None:
    s1 = native_int_linear(scale=3, bias=1, name="mul3_add1")
    s2 = native_int_linear(scale=2, bias=-4, name="mul2_sub4")
    s3 = native_float_linear(scale=0.5, bias=1.25, name="half_plus")
    s4 = native_float_poly(1.0, 2.0, 3.0, name="quad")

    expected_s1 = 16
    assert s1.name == "mul3_add1"
    assert s1.kind == "int"
    assert s1.is_gil_free is True
    assert s1(5) == expected_s1
    assert s4(2.0) == pytest.approx(17.0)

    # Consecutive native stages fuse into a single GIL-free block, including int->float
    fused = s1 | s2 | s3
    # 5 -> 16 -> 28 -> 15.25
    assert fused(5) == pytest.approx(15.25)


def test_hybrid_parallel_and_native_chains() -> None:
    n1 = native_int_linear(scale=2, bias=1, name="n1")
    n2 = native_int_linear(scale=3, bias=0, name="n2")
    n3 = native_int_linear(scale=1, bias=10, name="n3")

    @task
    def py_label(x: int) -> str:
        return f"py:{x * x}"

    @spread
    def combine(a: int, b: str, c: int) -> str:
        return f"{a}|{b}|{c}"

    # Mix native serial chain, Python callable, and single native stage in one & group
    hybrid = ((n1 | n2) & py_label & n3) | combine
    # x=4: n1|n2 => (4*2+1)*3 = 27; py_label => "py:16"; n3 => 14
    assert hybrid(4) == "27|py:16|14"

    # Introspection, SequentialExecutor, and TracingExecutor understand native stages
    stats = graph_stats(hybrid)
    expected_stages = 5
    expected_width = 3
    assert stats.stage_count == expected_stages
    assert stats.max_parallel_width == expected_width

    mermaid = to_mermaid(hybrid)
    dot = to_dot(hybrid)
    assert "native(n1)" in mermaid
    assert "native(n3)" in dot

    seq = SequentialExecutor()
    assert seq.run(hybrid, 4) == "27|py:16|14"

    tracer = TracingExecutor(sequential=False)
    assert tracer.run(hybrid, 4) == "27|py:16|14"
    traced_names = {span.stage for span in tracer.spans}
    assert "native(n1)" in traced_names
    assert "py_label" in traced_names


def test_native_capsule_protocol_and_errors() -> None:
    cap = mojo_strata.make_int_linear_capsule(5, 7)
    wrapped = native_stage(cap, name="ext_linear")
    expected_direct = 27
    assert wrapped.name == "ext_linear"
    assert wrapped.kind == "int"
    assert wrapped(4) == expected_direct

    class CustomProvider:
        def __init__(self, scale: int, bias: int) -> None:
            self.scale = scale
            self.bias = bias

        def as_native_capsule(self) -> object:
            return mojo_strata.make_int_linear_capsule(self.scale, self.bias)

    provided = native_stage(CustomProvider(10, -2), name="provided_stage")
    pipe = wrapped & provided
    assert pipe(3) == (22, 28)

    with pytest.raises(TypeError, match=r"strata\.native_stage\.v1"):
        native_stage(object())

    with pytest.raises(TypeError, match="expected an int"):
        wrapped("not_an_int")  # type: ignore[arg-type]

    # Parallel native type error propagation raises PEP 654 ExceptionGroup
    caught_count = 0
    expected_errors = 2
    try:
        pipe("bad")  # type: ignore[arg-type]
    except* TypeError as eg:
        caught_count = len(eg.exceptions)
    assert caught_count == expected_errors


def test_native_cpu_work_parallel_consistency() -> None:
    work = native_cpu_work(200_000, name="mix")
    expected = work(12345)
    par4 = work & work & work & work
    out = par4(12345)
    assert out == (expected, expected, expected, expected)

    info = runtime_info()
    assert info.native_gil_free is True
    assert info.cpu_count >= 1
    assert info.gil_enabled == is_gil_enabled()


# ===----------------------------------------------------------------------=== #
# Python `async def` Tasks & Native `arun`
# ===----------------------------------------------------------------------=== #


def test_async_task_sync_and_arun() -> None:
    @async_task
    async def fetch_a(x: int) -> int:
        await asyncio.sleep(0.015)
        return x + 1

    @async_task
    async def fetch_b(x: int) -> int:
        await asyncio.sleep(0.015)
        return x * 10

    @task
    def sync_add(pair: tuple[int, int]) -> int:
        return pair[0] + pair[1]

    native_mul = native_int_linear(scale=2, bias=0, name="double")
    pipeline = (fetch_a & fetch_b) | sync_add | native_mul

    expected_total = 112
    expected_single = 11
    max_elapsed_s = 0.2

    # 1. Synchronous execution via Mojo TaskGroup (each branch runs concurrently)
    assert pipeline(5) == expected_total

    # 2. Native asyncio execution on caller's active event loop
    async def _run() -> int:
        t0 = time.perf_counter()
        res = await pipeline.arun(5)
        elapsed = time.perf_counter() - t0
        assert elapsed < max_elapsed_s
        assert await arun(fetch_a, 10) == expected_single
        return res

    assert asyncio.run(_run()) == expected_total


def test_arun_resilience_combinators() -> None:
    attempts = 0
    fail_until = 2

    @async_task
    async def flaky(x: int) -> int:
        nonlocal attempts
        await asyncio.sleep(0)
        attempts += 1
        if attempts < fail_until:
            msg = "transient"
            raise ValueError(msg)
        return x + 5

    @async_task
    async def fail_a(x: int) -> int:
        await asyncio.sleep(0.005)
        msg = f"fail_a:{x}"
        raise RuntimeError(msg)

    @async_task
    async def slow(x: int) -> int:
        await asyncio.sleep(0.2)
        return x

    @async_task
    async def inc(x: int) -> int:
        await asyncio.sleep(0)
        return x + 1

    async def _run() -> None:
        expected_retry = 15
        expected_fb = 5

        r_pipe = retry(flaky, max_attempts=3)
        assert await arun(r_pipe, 10) == expected_retry

        fb_pipe = fallback(fail_a, inc)
        assert await arun(fb_pipe, 4) == expected_fb

        to_pipe = timeout(slow, 0.02)
        with pytest.raises(TimeoutError):
            await arun(to_pipe, 1)

    asyncio.run(_run())


def test_arun_dataflow_and_error_groups() -> None:
    @async_task
    async def fail_a(x: int) -> int:
        await asyncio.sleep(0.005)
        msg = f"fail_a:{x}"
        raise RuntimeError(msg)

    @async_task
    async def fail_b(x: int) -> int:
        await asyncio.sleep(0.005)
        msg = f"fail_b:{x}"
        raise KeyError(msg)

    @async_task
    async def inc(x: int) -> int:
        await asyncio.sleep(0)
        return x + 1

    @async_task
    async def dbl(x: int) -> int:
        await asyncio.sleep(0)
        return x * 2

    async def _run() -> None:
        expected_even = 8
        expected_odd = 6
        expected_err_count = 2

        br_pipe = branch(lambda x: x % 2 == 0, dbl, inc)
        assert await arun(br_pipe, 4) == expected_even
        assert await arun(br_pipe, 5) == expected_odd

        z_pipe = zip_tasks(inc, dbl)
        assert await arun(z_pipe, (3, 4)) == (4, 8)

        g_pipe = group(inc & dbl) & inc
        assert await arun(g_pipe, 3) == ((4, 6), 4)

        m_pipe = map_task(inc, max_concurrency=2)
        assert await arun(m_pipe, [1, 2, 3, 4]) == [2, 3, 4, 5]

        caught_errors = 0
        try:
            await arun(fail_a & fail_b, 9)
        except* (RuntimeError, KeyError) as eg:
            caught_errors = len(eg.exceptions)
        assert caught_errors == expected_err_count

    asyncio.run(_run())


# ===----------------------------------------------------------------------=== #
# Streaming & Software-Pipelined Batch Execution (`map`, `stream`, `astream`)
# ===----------------------------------------------------------------------=== #


def test_pipeline_map_and_ordered_stream_backpressure() -> None:
    n1 = native_int_linear(scale=2, bias=1, name="scale")
    n2 = native_int_linear(scale=1, bias=10, name="shift")
    pipe = n1 | n2

    assert pipe.map([1, 2, 3, 4, 5], max_in_flight=3) == [13, 15, 17, 19, 21]
    assert pipe.map([], max_in_flight=2) == []

    # Verify true sliding-window backpressure on an infinite generator
    pulled = 0

    def infinite_source() -> Iterator[int]:
        nonlocal pulled
        i = 0
        while True:
            pulled += 1
            yield i
            i += 1

    max_in_flight = 3
    target_items = 6
    max_allowed_pulls = 10
    seen: list[int] = []
    stream_iter = pipe.stream(infinite_source(), max_in_flight=max_in_flight)
    for idx, val in enumerate(stream_iter):
        seen.append(val)
        assert pulled <= idx + 1 + max_in_flight + 1
        if len(seen) == target_items:
            break
    close_fn = getattr(stream_iter, "close", None)
    if callable(close_fn):
        cast("Any", close_fn)()

    assert seen == [11, 13, 15, 17, 19, 21]
    assert pulled <= max_allowed_pulls


def test_pipeline_stream_unordered_and_errors() -> None:
    @task
    def variable_delay(x: int) -> int:
        time.sleep(0.06 if x == 0 else 0.002)
        return x * 10

    pipe = variable_delay | native_int_linear(scale=1, bias=1, name="add1")
    results = list(pipe.stream([0, 1, 2, 3], max_in_flight=4, ordered=False))
    assert sorted(results) == [1, 11, 21, 31]
    assert results[0] != 1

    boom_idx = 2

    @task
    def boom_on_two(x: int) -> int:
        if x == boom_idx:
            msg = "stream_boom"
            raise ValueError(msg)
        return x

    err_pipe = boom_on_two | native_int_linear(scale=1, bias=0, name="id")
    with pytest.raises(ValueError, match="stream_boom"):
        list(err_pipe.stream([0, 1, 2, 3], max_in_flight=2))

    with pytest.raises(ValueError, match="max_in_flight"):
        list(pipe.stream([1, 2], max_in_flight=0))


def test_pipeline_astream_sync_and_async_sources() -> None:
    @async_task
    async def async_double(x: int) -> int:
        await asyncio.sleep(0.02 if x == 0 else 0.002)
        return x * 2

    pipe = async_double | native_int_linear(scale=1, bias=5, name="plus5")

    async def async_source() -> AsyncIterator[int]:
        for i in range(6):
            await asyncio.sleep(0.001)
            yield i

    async def _run() -> None:
        slow_first_result = 5
        partial_limit = 4

        ordered_out = [
            v async for v in pipe.astream(async_source(), max_in_flight=3, ordered=True)
        ]
        assert ordered_out == [5, 7, 9, 11, 13, 15]

        unordered_out = [
            v async for v in pipe.astream([0, 1, 2, 3], max_in_flight=4, ordered=False)
        ]
        assert sorted(unordered_out) == [5, 7, 9, 11]
        assert unordered_out[0] != slow_first_result

        # Early break cleans up pending async tasks cleanly
        partial: list[int] = []
        async for v in pipe.astream(range(100), max_in_flight=3, ordered=True):
            partial.append(v)
            if len(partial) == partial_limit:
                break
        assert partial == [5, 7, 9, 11]

    asyncio.run(_run())
