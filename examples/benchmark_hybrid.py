"""Benchmark: Pure Python vs Mojo TaskGroup vs GIL-Free Native Mojo Stages.

Run from the repository root after building `mojo_strata.so`:

    cd python && uv run python ../examples/benchmark_hybrid.py
"""

from __future__ import annotations

import time
from typing import TYPE_CHECKING

from strata import native_cpu_work, runtime_info, task

if TYPE_CHECKING:
    from collections.abc import Callable


def _py_mix(x: int, iterations: int) -> int:
    state = (x ^ 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    for _ in range(iterations):
        state = (
            state * 6364136223846793005 + 1442695040888963407
        ) & 0xFFFFFFFFFFFFFFFF
        state ^= state >> 29
    return state & 0x7FFFFFFFFFFFFFFF


def _time_fn(fn: Callable[[], object], repeats: int = 3) -> float:
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        _ = fn()
        best = min(best, time.perf_counter() - t0)
    return best


def main() -> None:
    info = runtime_info()
    print("=== Strata v2 Hybrid Parallelism Benchmark ===")
    print(
        f"Python {info.python_version} | GIL enabled: {info.gil_enabled} | "
        f"CPUs: {info.cpu_count} | Native GIL-free: {info.native_gil_free}"
    )

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
    # Warmup
    _ = mojo_par4(42)
    t_mojo_seq = _time_fn(lambda: tuple(mojo_branch(42) for _ in range(4)))
    t_mojo_par = _time_fn(lambda: mojo_par4(42))
    print(
        f"\n[GIL-Free Mojo NativeStage 4x {native_iters:,} iters]\n"
        f"  Sequential:    {t_mojo_seq * 1000:7.2f} ms\n"
        f"  TaskGroup (&): {t_mojo_par * 1000:7.2f} ms "
        f"({t_mojo_seq / t_mojo_par:.2f}x speedup)"
    )

    # 3. Streaming batch execution with bounded backpressure
    batch = list(range(32))
    batch_stage = native_cpu_work(1_000_000, name="mix_1m")
    t_stream_seq = _time_fn(
        lambda: list(batch_stage.stream(batch, max_in_flight=1)), repeats=2
    )
    t_stream_par = _time_fn(
        lambda: list(batch_stage.stream(batch, max_in_flight=4, ordered=False)),
        repeats=2,
    )
    print(
        f"\n[Streaming 32 items x 1,000,000 iters]\n"
        f"  stream(max_in_flight=1): {t_stream_seq * 1000:7.2f} ms\n"
        f"  stream(max_in_flight=4): {t_stream_par * 1000:7.2f} ms "
        f"({t_stream_seq / t_stream_par:.2f}x speedup)"
    )


if __name__ == "__main__":
    main()
