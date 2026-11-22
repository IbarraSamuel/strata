"""Tests for pluggable executors (`AsyncRTExecutor`, `SequentialExecutor`,
`BoundedExecutor`, `TracingExecutor`) across runtime and comptime pipelines.
"""

from std.testing import TestSuite, assert_equal, assert_true
from std.time import sleep

from strata.executors import (
    AsyncRTExecutor,
    BoundedExecutor,
    SequentialExecutor,
    TracingExecutor,
)
from strata.pipeline import Fn, owned, run_with
from strata.pipeline.compt import F


def _add_one(x: Int) -> Int:
    return x + 1


def _double(x: Int) -> Int:
    return x * 2


def _triple(x: Int) -> Int:
    return x * 3


def _quad(x: Int) -> Int:
    return x * 4


def _sum4(t: Tuple[Int, Int, Int, Int]) -> Int:
    return t[0] + t[1] + t[2] + t[3]


def _slow_inc(x: Int) -> Int:
    sleep(0.01)
    return x + 1


def _slow_double(x: Int) -> Int:
    sleep(0.01)
    return x * 2


def test_runtime_pipeline_all_executors() raises:
    var f1 = Fn(_add_one)
    var f2 = Fn(_double)
    var f3 = Fn(_triple)
    var f4 = Fn(_quad)
    var merge = Fn(_sum4)

    var pipe = (f1 & f2 & f3 & f4) | merge

    var async_exec = AsyncRTExecutor()
    var seq_exec = SequentialExecutor()
    var bounded_exec = BoundedExecutor(max_workers=2)

    # input=3: (4, 6, 9, 12) -> 31
    assert_equal(pipe.run_with(async_exec, 3), 31)
    assert_equal(run_with(seq_exec, pipe, 3), 31)
    assert_equal(pipe.run_with(bounded_exec, 3), 31)


def test_owned_pipeline_executors() raises:
    var pipe = (
        owned(Fn(_add_one))
        & Fn(_double)
        & Fn(_triple)
        & Fn(_quad)
    ) | Fn(_sum4)

    var seq_exec = SequentialExecutor()
    var bounded_exec = BoundedExecutor(max_workers=2)
    var tracer = TracingExecutor()

    assert_equal(pipe.run_with(seq_exec, 2), 21)
    assert_equal(pipe.run_with(bounded_exec, 2), 21)
    assert_equal(pipe.run_with(tracer, 2), 21)
    # 4 parallel branches + 1 merge stage = 5 spans
    assert_equal(len(tracer.spans), 5)


def test_tracing_executor_parallel_and_sequential() raises:
    var s1 = Fn(_slow_inc)
    var s2 = Fn(_slow_double)
    var par = s1 & s2

    var par_tracer = TracingExecutor()
    var res_par = par.run_with(par_tracer, 5)
    assert_equal(res_par[0], 6)
    assert_equal(res_par[1], 10)
    assert_equal(len(par_tracer.spans), 2)
    assert_true(par_tracer.spans[0].duration_ns() > 0)
    assert_true(par_tracer.spans[1].duration_ns() > 0)
    assert_true(par_tracer.total_duration_ns() > 0)
    assert_true(par_tracer.format_report().byte_length() > 0)

    # Parallel branches should overlap in wall-clock time
    assert_true(par_tracer.spans[0].end_ns > par_tracer.spans[1].start_ns)
    assert_true(par_tracer.spans[1].end_ns > par_tracer.spans[0].start_ns)

    # Sequential tracing runs strictly sequentially (span 0 finishes before span 1 starts)
    var seq_tracer = TracingExecutor[SequentialExecutor](SequentialExecutor())
    var res_seq = par.run_with(seq_tracer, 5)
    assert_equal(res_seq[0], 6)
    assert_equal(res_seq[1], 10)
    assert_equal(len(seq_tracer.spans), 2)
    assert_true(seq_tracer.spans[0].end_ns <= seq_tracer.spans[1].start_ns)

    seq_tracer.clear()
    assert_equal(len(seq_tracer.spans), 0)


def test_compt_pipeline_executors() raises:
    comptime pipe = (
        F[_add_one] & F[_double] & F[_triple] & F[_quad]
    ) | F[_sum4]

    var seq_exec = SequentialExecutor()
    var bounded_exec = BoundedExecutor(max_workers=2)
    var tracer = TracingExecutor()

    assert_equal(pipe.run_with(seq_exec, 3), 31)
    assert_equal(pipe.run_with(bounded_exec, 3), 31)
    assert_equal(pipe.run_with(tracer, 3), 31)
    assert_equal(len(tracer.spans), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
