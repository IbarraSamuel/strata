"""Benchmark: Strata v2 Microbenchmarks & Hybrid GIL-Free Mojo Parallelism.

Run from the repository root after building `mojo_strata.so`:

    cd python && uv run python ../examples/benchmark_hybrid.py
"""

from __future__ import annotations

import asyncio
import time
from typing import TYPE_CHECKING

from strata import (
    TracingExecutor,
    arun,
    map_stage,
    map_task,
    native_cpu_work,
    native_int_linear,
    runtime_info,
    stream_stage,
    task,
    timeout,
)

if TYPE_CHECKING:
    from collections.abc import Callable


def _py_mix(x: int, iterations: int) -> int:
    state = (x ^ 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    for _ in range(iterations):
        state = (state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        state ^= state >> 29
    return state & 0x7FFFFFFFFFFFFFFF


def _time_fn(fn: Callable[[], object], repeats: int = 3, warmup: int = 1) -> float:
    for _ in range(warmup):
        _ = fn()
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        _ = fn()
        best = min(best, time.perf_counter() - t0)
    return best


def _bench_us(fn: Callable[[], object], iters: int = 2_000, warmup: int = 100) -> float:
    for _ in range(warmup):
        _ = fn()
    t0 = time.perf_counter()
    for _ in range(iters):
        _ = fn()
    return (time.perf_counter() - t0) * 1_000_000.0 / iters


def _run_microbenchmarks() -> None:
    print("\n--- Low-Latency Dispatch Microbenchmarks (us/call) ---")

    n1 = native_int_linear(scale=2, bias=1, name="n1")
    n_ser4 = n1 | n1 | n1 | n1
    n_par4 = n1 & n1 & n1 & n1

    @task
    def py1(x: int) -> int:
        return x * 2 + 1

    py_ser4 = py1 | py1 | py1 | py1
    py_par4 = py1 & py1 & py1 & py1

    t_n1 = _bench_us(lambda: n1(10), 10_000)
    t_n_ser4 = _bench_us(lambda: n_ser4(10), 5_000)
    t_n_par4 = _bench_us(lambda: n_par4(10), 2_000)
    print(
        f"  NativeStage direct:     {t_n1:8.2f} us/call\n"
        f"  NativeStage serial 4x:  {t_n_ser4:8.2f} us/call\n"
        f"  NativeStage parallel 4: {t_n_par4:8.2f} us/call"
    )
    t_py1 = _bench_us(lambda: py1(10), 10_000)
    t_py_ser4 = _bench_us(lambda: py_ser4(10), 5_000)
    t_py_par4 = _bench_us(lambda: py_par4(10), 1_000)
    print(
        f"  PyTask direct:          {t_py1:8.2f} us/call\n"
        f"  PyTask serial 4x:       {t_py_ser4:8.2f} us/call\n"
        f"  PyTask parallel 4:      {t_py_par4:8.2f} us/call"
    )

    items64 = list(range(64))
    py_map64 = map_task(py1, max_concurrency=4)
    native_map64 = map_task(n_ser4, max_concurrency=4)
    t_py_map = _bench_us(lambda: py_map64(items64), 200, 10)
    t_nat_map = _bench_us(lambda: native_map64(items64), 500, 20)
    t_map_stage = _bench_us(
        lambda: map_stage(n_ser4, items64, max_in_flight=4), 500, 20
    )
    t_stream64 = _bench_us(
        lambda: list(stream_stage(py1, items64, max_in_flight=4)), 100, 5
    )
    print(
        f"  MapTask(py, 64, c=4):   {t_py_map:8.2f} us/call\n"
        f"  MapTask(nat4, 64, c=4): {t_nat_map:8.2f} us/call\n"
        f"  map_stage(nat4, 64):    {t_map_stage:8.2f} us/call\n"
        f"  stream_stage(py, 64):   {t_stream64:8.2f} us/call"
    )

    to_py = timeout(py1, seconds=5.0)
    t_timeout = _bench_us(lambda: to_py(10), 2_000, 50)
    print(f"  TimeoutTask(py1, 5s):   {t_timeout:8.2f} us/call")

    tracer_py = TracingExecutor(sequential=False)
    tracer_nat = TracingExecutor(sequential=False)

    def _run_traced_py() -> object:
        tracer_py.clear()
        return tracer_py.run(py_ser4, 10)

    def _run_traced_nat() -> object:
        tracer_nat.clear()
        return tracer_nat.run(n_ser4, 10)

    t_tr_py = _bench_us(_run_traced_py, 2_000, 50)
    t_tr_nat = _bench_us(_run_traced_nat, 2_000, 50)
    print(
        f"  TracingExecutor(py4):   {t_tr_py:8.2f} us/call\n"
        f"  TracingExecutor(nat4):  {t_tr_nat:8.2f} us/call"
    )

    async def _bench_arun() -> tuple[float, float]:
        for _ in range(50):
            await arun(n_ser4, 10)
            await arun(py_ser4, 10)
        n_iters = 1_000
        t0 = time.perf_counter()
        for _ in range(n_iters):
            await arun(n_ser4, 10)
        us_nat = (time.perf_counter() - t0) * 1_000_000.0 / n_iters

        t0 = time.perf_counter()
        for _ in range(n_iters):
            await arun(py_ser4, 10)
        us_py = (time.perf_counter() - t0) * 1_000_000.0 / n_iters
        return (us_nat, us_py)

    us_arun_nat, us_arun_py = asyncio.run(_bench_arun())
    print(
        f"  arun(native ser4):      {us_arun_nat:8.2f} us/call\n"
        f"  arun(py ser4):          {us_arun_py:8.2f} us/call"
    )


def main() -> None:
    info = runtime_info()
    print("=== Strata v2 Performance & Hybrid Parallelism Benchmark ===")
    print(
        f"Python {info.python_version} | GIL enabled: {info.gil_enabled} | "
        f"CPUs: {info.cpu_count} | Native GIL-free: {info.native_gil_free}"
    )

    _run_microbenchmarks()

    # 1. Pure Python CPU-bound work (4 branches)
    py_iters = 200_000

    @task
    def py_branch(x: int) -> int:
        return _py_mix(x, py_iters)

    py_par4 = py_branch & py_branch & py_branch & py_branch
    t_py_seq = _time_fn(lambda: tuple(py_branch(42) for _ in range(4)))
    t_py_par = _time_fn(lambda: py_par4(42))
    print(
        f"\n[Pure Python 4x {py_iters:,} iters]\n"
        f"  Sequential:    {t_py_seq * 1000:7.2f} ms\n"
        f"  TaskGroup (&): {t_py_par * 1000:7.2f} ms "
        f"({t_py_seq / t_py_par:.2f}x speedup)"
    )

    # 2. GIL-free Mojo NativeStage CPU-bound work (4 branches)
    native_iters = 5_000_000
    mojo_branch = native_cpu_work(native_iters, name="mix_5m")
    mojo_par4 = mojo_branch & mojo_branch & mojo_branch & mojo_branch
    t_mojo_seq = _time_fn(lambda: tuple(mojo_branch(42) for _ in range(4)))
    t_mojo_par = _time_fn(lambda: mojo_par4(42))
    print(
        f"\n[GIL-Free Mojo NativeStage 4x {native_iters:,} iters]\n"
        f"  Sequential:    {t_mojo_seq * 1000:7.2f} ms\n"
        f"  TaskGroup (&): {t_mojo_par * 1000:7.2f} ms "
        f"({t_mojo_seq / t_mojo_par:.2f}x speedup)"
    )

    # 3. Streaming & batch execution with bounded backpressure
    batch = list(range(32))
    batch_stage = native_cpu_work(1_000_000, name="mix_1m")
    t_stream_seq = _time_fn(
        lambda: list(batch_stage.stream(batch, max_in_flight=1)), repeats=2
    )
    t_stream_par = _time_fn(
        lambda: list(batch_stage.stream(batch, max_in_flight=4, ordered=False)),
        repeats=2,
    )
    t_map_par = _time_fn(
        lambda: batch_stage.map(batch, max_in_flight=4),
        repeats=2,
    )
    print(
        f"\n[Batch / Streaming 32 items x 1,000,000 iters]\n"
        f"  stream(max_in_flight=1): {t_stream_seq * 1000:7.2f} ms\n"
        f"  stream(max_in_flight=4): {t_stream_par * 1000:7.2f} ms "
        f"({t_stream_seq / t_stream_par:.2f}x speedup)\n"
        f"  map(max_in_flight=4):    {t_map_par * 1000:7.2f} ms "
        f"({t_stream_seq / t_map_par:.2f}x speedup)"
    )


if __name__ == "__main__":
    main()
