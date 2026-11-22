"""Comprehensive edge-case tests across all Strata v2 Mojo modules."""

from std.atomic import Atomic
from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from std.time import monotonic, sleep
from std.utils.numerics import inf, nan

from strata import pipeline, stateful
from strata.executors import (
    AsyncRTExecutor,
    BoundedExecutor,
    Executor,
    SequentialExecutor,
    TracingExecutor,
)
from strata.pipeline import Fn, group, owned, owned_group, run_with
from strata.pipeline.async_fn import AF
from strata.pipeline.combinators import (
    OutputSink,
    map_stage,
    spread,
    stream_map,
    zip_stages,
)
from strata.pipeline.compt import F, GraphBuilder, Id, Spread2, Spread3, Spread4
from strata.pipeline.compt import group as ct_group
from strata.pipeline.fallible import ComposableFallibleStage, RaisingFn
from strata.pipeline.resilience import fallback, recover, retry, timeout
from strata.stateful import async_stage


# ===----------------------------------------------------------------------=== #
# Helper Functions & Stages
# ===----------------------------------------------------------------------=== #


def _add_k[k: Int](x: Int) -> Int:
    return x + k


def _mul_k[k: Int](x: Int) -> Int:
    return x * k


def _add2(a: Int, b: Int) -> Int:
    return a + b


def _sum3(a: Int, b: Int, c: Int) -> Int:
    return a + b + c


def _sum4(a: Int, b: Int, c: Int, d: Int) -> Int:
    return a + b + c + d


def _sum_pair(v: Tuple[Int, Int]) -> Int:
    return v[0] + v[1]


def _diff_pair(v: Tuple[Int, Int]) -> Int:
    return v[0] - v[1]


def _sum_quad(v: Tuple[Int, Int, Int, Int]) -> Int:
    return v[0] + v[1] + v[2] + v[3]


def _sum_left_group(v: Tuple[Tuple[Int, Int], Int]) -> Int:
    return v[0][0] * 100 + v[0][1] * 10 + v[1]


def _sum_right_group(v: Tuple[Int, Tuple[Int, Int]]) -> Int:
    return v[0] * 100 + v[1][0] * 10 + v[1][1]


def _sum_double_group(v: Tuple[Tuple[Int, Int], Int]) -> Int:
    return v[0][0] + v[0][1] + v[1]


def _slow_mul2(x: Int) -> Int:
    sleep(0.002)
    return x * 2


@fieldwise_init
struct OffsetStage(pipeline.ComposableStage, Movable):
    comptime I = Int
    comptime O = Int
    var delta: Int

    def __call__(self, arg: Int) -> Int:
        return arg + self.delta


@fieldwise_init
struct MulStage(pipeline.ComposableStage, Movable):
    comptime I = Int
    comptime O = Int
    var factor: Int

    def __call__(self, arg: Int) -> Int:
        return arg * self.factor


struct CountingFallibleStage[o: MutOrigin](ComposableFallibleStage):
    """Fallible stage that increments a call counter and optionally raises."""

    comptime I = Int
    comptime O = Int

    var calls: Pointer[Int, Self.o]
    var fail_on_calls_le: Int
    var err_tag: String
    var offset: Int

    def __init__(
        out self,
        ref[Self.o] calls: Int,
        fail_on_calls_le: Int = 0,
        var err_tag: String = "boom",
        offset: Int = 1,
    ):
        self.calls = Pointer(to=calls)
        self.fail_on_calls_le = fail_on_calls_le
        self.err_tag = err_tag^
        self.offset = offset

    def __call__(self, arg: Int) raises -> Int:
        self.calls[] += 1
        if self.fail_on_calls_le > 0 and self.calls[] <= self.fail_on_calls_le:
            raise Error(String(self.err_tag, ":", self.calls[]))
        return arg + self.offset


def _always_raise_tag[tag: StaticString](x: Int) raises -> Int:
    raise Error(String(tag, ":", x))


def _ok_add[k: Int](x: Int) raises -> Int:
    return x + k


def _slow_ok_raise(x: Int) raises -> Int:
    sleep(0.005)
    return x + 1


def _recover_from_err(x: Int, err_msg: String) -> Int:
    # Encodes both input and whether error message is non-empty
    var bonus = 1000 if err_msg.byte_length() > 0 else 0
    return -(x + bonus)


struct ListSink(OutputSink):
    comptime Item = Int
    var items: List[Int]

    def __init__(out self):
        self.items = List[Int]()

    def on_item(mut self, var item: Int):
        self.items.append(item)


struct OrderedMutStage(stateful.MutStage, Movable):
    var count: Int
    var step: Int
    var start: Int
    var end: Int

    def __init__(out self, step: Int = 1):
        self.count = 0
        self.step = step
        self.start = 0
        self.end = 0

    def __call__(mut self):
        self.start = monotonic()
        sleep(0.002)
        self.count += self.step
        self.end = monotonic()


struct OrderedAsyncMutStage(async_stage.AsyncMutStage, Movable):
    var count: Int
    var step: Int
    var start: Int
    var end: Int

    def __init__(out self, step: Int = 1):
        self.count = 0
        self.step = step
        self.start = 0
        self.end = 0

    __async def __call__(mut self):
        self.start = monotonic()
        sleep(0.002)
        self.count += self.step
        self.end = monotonic()


# ===----------------------------------------------------------------------=== #
# 1. Deeply Nested Runtime Combinations, Associativity, Grouping & Reuse
# ===----------------------------------------------------------------------=== #


def test_runtime_deep_nested_and_associative_flattening() raises:
    var a = OffsetStage(1)
    var b = MulStage(2)
    var c = Fn(_sum_pair)
    var d = OffsetStage(3)
    var e = MulStage(4)
    var f = Fn(_diff_pair)

    # ((a & b) | c) & ((d & e) | f)
    var ab = a & b
    var left = ab | c
    var de = d & e
    var right = de | f
    var nested = left & right

    # x = 5: left = (6 + 10) = 16; right = (8 - 20) = -12
    var l_res, r_res = nested(5)
    assert_equal(l_res, 16)
    assert_equal(r_res, -12)

    # Quad right-nested associative flattening: a & (b & (d & e))
    var de2 = d & e
    var bde = b & de2
    var quad_right = a & bde
    var q0, q1, q2, q3 = quad_right(5)
    assert_equal(q0, 6)
    assert_equal(q1, 10)
    assert_equal(q2, 8)
    assert_equal(q3, 20)

    var sum4 = Fn(_sum_quad)
    var quad_pipe = quad_right | sum4
    assert_equal(quad_pipe(5), 44)

    # group(a & b) & d vs a & group(b & d) preserve asymmetric tuple shapes
    var g_ab = group(ab)
    var left_grouped = (g_ab & d) | Fn(_sum_left_group)
    # x = 5: ((6, 10), 8) -> 6*100 + 10*10 + 8 = 708
    assert_equal(left_grouped(5), 708)

    var bd = b & d
    var g_bd = group(bd)
    var right_grouped = (a & g_bd) | Fn(_sum_right_group)
    # x = 5: (6, (10, 8)) -> 6*100 + 10*10 + 8 = 708
    assert_equal(right_grouped(5), 708)

    # Double-wrapped group(group(a & b)) still preserves Tuple[Int, Int] as single branch
    var g_ab_inner = group(ab)
    var g_ab_outer = group(g_ab_inner)
    var double_grouped = (g_ab_outer & d) | Fn(_sum_double_group)
    # x = 5: ((6, 10), 8) -> 24
    assert_equal(double_grouped(5), 24)


def test_runtime_pipeline_reusability_and_shared_subpipelines() raises:
    var a = OffsetStage(2)
    var b = MulStage(3)
    var c = OffsetStage(10)
    var d = MulStage(5)

    # Shared sub-pipeline reused inside two distinct parent pipelines
    var shared = a | b
    var parent1 = (shared & c) | Fn(_sum_pair)
    var parent2 = (shared & d) | Fn(_diff_pair)

    # Call repeatedly with varying inputs (negative, zero, positive)
    for x in [-4, 0, 1, 7]:
        var s = (x + 2) * 3
        assert_equal(shared(x), s)
        assert_equal(parent1(x), s + (x + 10))
        assert_equal(parent2(x), s - (x * 5))


# ===----------------------------------------------------------------------=== #
# 2. Factory-Returned Owned* Pipelines, owned_group & run_with
# ===----------------------------------------------------------------------=== #


def _build_owned_flattened_pipeline(
    delta: Int, factor: Int
) -> pipeline.OwnedSequence[
    pipeline.OwnedParallel[OffsetStage, MulStage, OffsetStage, MulStage],
    Fn[Tuple[Int, Int, Int, Int], Int],
]:
    var left = owned(OffsetStage(delta)) & MulStage(factor)
    var right = owned(OffsetStage(delta + 1)) & MulStage(factor + 1)
    return (left^ & right^) | Fn(_sum_quad)


def _build_owned_grouped_pipeline(
    delta: Int,
) -> pipeline.OwnedSequence[
    pipeline.OwnedParallel[
        pipeline.OwnedGroup[pipeline.OwnedParallel[OffsetStage, MulStage]],
        OffsetStage,
    ],
    Fn[Tuple[Tuple[Int, Int], Int], Int],
]:
    var g = owned_group(owned(OffsetStage(delta)) & MulStage(2))
    return (g^ & OffsetStage(delta + 5)) | Fn(_sum_left_group)


def test_owned_pipelines_from_factories_and_executors() raises:
    var flat = _build_owned_flattened_pipeline(1, 2)
    # x = 5: (6, 10, 7, 15) -> 38
    assert_equal(flat(5), 38)
    assert_equal(flat(0), 1 + 0 + 2 + 0)

    # run_with across all executors on factory-returned OwnedSequence/OwnedParallel
    var seq = SequentialExecutor()
    var b1 = BoundedExecutor(max_workers=1)
    var b2 = BoundedExecutor(max_workers=2)
    var b8 = BoundedExecutor(max_workers=8)
    var tracer = TracingExecutor()
    var seq_tracer = TracingExecutor[SequentialExecutor](SequentialExecutor())
    var bounded_tracer = TracingExecutor[BoundedExecutor](
        BoundedExecutor(max_workers=2)
    )

    assert_equal(run_with(seq, flat, 5), 38)
    assert_equal(flat.run_with(b1, 5), 38)
    assert_equal(flat.run_with(b2, 5), 38)
    assert_equal(flat.run_with(b8, 5), 38)
    assert_equal(flat.run_with(tracer, 5), 38)
    assert_equal(len(tracer.spans), 5)  # 4 parallel branches + 1 merge

    assert_equal(flat.run_with(seq_tracer, 5), 38)
    assert_equal(len(seq_tracer.spans), 5)

    assert_equal(flat.run_with(bounded_tracer, 5), 38)
    assert_equal(len(bounded_tracer.spans), 5)

    # OwnedGroup from factory + run_with
    var grouped = _build_owned_grouped_pipeline(1)
    # x = 3: ((4, 6), 9) -> 4*100 + 6*10 + 9 = 469
    assert_equal(grouped(3), 469)
    assert_equal(grouped.run_with(seq, 3), 469)
    var g_tracer = TracingExecutor()
    assert_equal(grouped.run_with(g_tracer, 3), 469)
    assert_true(len(g_tracer.spans) >= 3)


# ===----------------------------------------------------------------------=== #
# 3. Compile-Time Pipelines: comptime_run, Id, Spread2/3/4, Group & Introspect
# ===----------------------------------------------------------------------=== #


def test_compt_comptime_run_nested_diamonds_groups_and_spreads() raises:
    # Nested diamonds: ((a & b) | sum2) & ((c & d) | diff2) | Spread2[_add2]
    comptime diamond_of_diamonds = (
        ((F[_add_k[1]] & F[_mul_k[2]]) | F[_sum_pair])
        & ((F[_add_k[3]] & F[_mul_k[4]]) | F[_diff_pair])
    ) | Spread2[_add2]

    # x = 5: left = (6+10)=16, right = (8-20)=-12 -> 16 + (-12) = 4
    comptime ct_dd = diamond_of_diamonds.comptime_run[5]
    assert_equal(ct_dd, 4)
    assert_equal(diamond_of_diamonds(5), 4)

    # Id + Spread2/3/4 at compile time and runtime
    comptime p2 = (Id[Int] & F[_mul_k[3]]) | Spread2[_add2]
    comptime ct_p2 = p2.comptime_run[7]
    assert_equal(ct_p2, 28)
    assert_equal(p2(7), 28)

    comptime p3 = (F[_add_k[1]] & Id[Int] & F[_mul_k[2]]) | Spread3[_sum3]
    comptime ct_p3 = p3.comptime_run[5]
    assert_equal(ct_p3, 6 + 5 + 10)
    assert_equal(p3(5), 21)

    comptime p4 = (
        F[_add_k[1]] & (F[_mul_k[2]] & (F[_add_k[3]] & Id[Int]))
    ) | Spread4[_sum4]
    comptime ct_p4 = p4.comptime_run[5]
    assert_equal(ct_p4, 6 + 10 + 8 + 5)
    assert_equal(p4(5), 29)

    # Grouped and double-grouped comptime_run
    comptime g_left = (
        ct_group(F[_add_k[1]] & F[_mul_k[2]]) & F[_add_k[3]]
    ) | F[_sum_left_group]
    comptime ct_gl = g_left.comptime_run[5]
    assert_equal(ct_gl, 708)
    assert_equal(g_left(5), 708)

    comptime g_right = (
        F[_add_k[1]] & ct_group(F[_mul_k[2]] & F[_add_k[3]])
    ) | F[_sum_right_group]
    comptime ct_gr = g_right.comptime_run[5]
    assert_equal(ct_gr, 708)
    assert_equal(g_right(5), 708)

    comptime g_double = (
        ct_group(ct_group(F[_add_k[1]] & F[_mul_k[2]])) & F[_add_k[3]]
    ) | F[_sum_double_group]
    comptime ct_gd = g_double.comptime_run[5]
    assert_equal(ct_gd, 24)
    assert_equal(g_double(5), 24)


def test_compt_complex_metadata_and_diagrams() raises:
    # Multi-diamond + grouped graph:
    # Entry (1) -> [ ((a & b) | sum) & group(c & (d | e)) ] -> merge
    # Left branch: stages=3, width=2, depth=2
    # Right grouped branch: stages=3 (c, d, e), width=2, depth=2
    # Combined parallel: stages=6, width=4, depth=2
    # With entry (1) and exit (1): stages=8, width=4, depth=4
    comptime complex_graph = (
        F[_add_k[1]]
        | (
            ((F[_add_k[2]] & F[_mul_k[2]]) | F[_sum_pair])
            & ct_group(F[_add_k[3]] & (F[_mul_k[3]] | F[_add_k[4]]))
        )
        | F[_sum_right_group]
    )

    comptime sc = complex_graph.STAGE_COUNT
    comptime mw = complex_graph.MAX_PARALLEL_WIDTH
    comptime cd = complex_graph.CRITICAL_DEPTH
    assert_equal(sc, 8)
    assert_equal(mw, 4)
    assert_equal(cd, 4)

    var mmd = complex_graph.to_mermaid()
    assert_true(mmd.startswith("flowchart LR"))
    assert_true("subgraph g0" in mmd)
    assert_true("end" in mmd)
    assert_true("-->" in mmd)
    assert_true("_sum_right_group" in mmd)

    var dot = complex_graph.to_dot()
    assert_true(dot.startswith("digraph Strata {"))
    assert_true("subgraph cluster_0" in dot)
    assert_true("->" in dot)
    assert_true(dot.endswith("}"))

    # Double-nested group creates two subgraph clusters
    comptime nested_groups = (
        ct_group(ct_group(F[_add_k[1]] & F[_mul_k[2]])) & F[_add_k[3]]
    ) | F[_sum_double_group]
    var nmmd = nested_groups.to_mermaid()
    assert_true("subgraph g0" in nmmd)
    assert_true("subgraph g1" in nmmd)
    var ndot = nested_groups.to_dot()
    assert_true("subgraph cluster_0" in ndot)
    assert_true("subgraph cluster_1" in ndot)


# ===----------------------------------------------------------------------=== #
# 4. Fallible Pipelines: Short-Circuit, Branch Positions & Recover
# ===----------------------------------------------------------------------=== #


def test_fallible_short_circuit_skips_downstream() raises:
    var c1 = 0
    var c2 = 0
    var c3 = 0

    var s1 = CountingFallibleStage(
        c1,
        fail_on_calls_le=0,
        err_tag="s1",
        offset=1,
    )
    var s2 = CountingFallibleStage(
        c2,
        fail_on_calls_le=1,
        err_tag="s2_fail",
        offset=2,
    )
    var s3 = CountingFallibleStage(
        c3,
        fail_on_calls_le=0,
        err_tag="s3",
        offset=3,
    )

    var pipe = s1 | s2 | s3
    with assert_raises(contains="s2_fail:1"):
        _ = pipe(10)

    # s1 and s2 ran once; s3 MUST NOT have been called!
    assert_equal(c1, 1)
    assert_equal(c2, 1)
    assert_equal(c3, 0)

    # Next call succeeds through all 3 stages
    assert_equal(pipe(10), 16)
    assert_equal(c1, 2)
    assert_equal(c2, 2)
    assert_equal(c3, 1)


def test_fallible_parallel_branch_positions_and_recover() raises:
    var ok1 = RaisingFn(_ok_add[1])
    var ok2 = RaisingFn(_ok_add[2])
    var fail0 = RaisingFn(_always_raise_tag["first_fail"])
    var fail_last = RaisingFn(_always_raise_tag["last_fail"])
    var fail_mid = RaisingFn(_always_raise_tag["mid_fail"])

    # Branch 0 fails only
    var p_first = fail0 & ok1 & ok2
    with assert_raises(contains="first_fail:7"):
        _ = p_first(7)

    # Last branch fails only
    var p_last = ok1 & ok2 & fail_last
    with assert_raises(contains="last_fail:7"):
        _ = p_last(7)

    # Multiple branches fail (2 of 3)
    var p_two = fail0 & ok1 & fail_last
    with assert_raises(contains="Parallel stage failures (2)"):
        _ = p_two(7)

    # All 3 branches fail
    var p_all = fail0 & fail_mid & fail_last
    with assert_raises(contains="Parallel stage failures (3)"):
        _ = p_all(7)

    # Recover with both success and error paths feeding into infallible `|`
    var post = Fn(_mul_k[2])
    var rec_err = recover(fail0, _recover_from_err) | post
    # error path: -(5 + 1000) * 2 = -2010
    assert_equal(rec_err(5), -2010)

    var rec_ok = recover(ok2, _recover_from_err) | post
    # success path: (5 + 2) * 2 = 14
    assert_equal(rec_ok(5), 14)


# ===----------------------------------------------------------------------=== #
# 5. Combinators: Map & stream_map Boundary Cases
# ===----------------------------------------------------------------------=== #


def test_map_and_stream_map_edge_cases() raises:
    var dbl = Fn(_mul_k[2])

    # n = 0
    var empty = List[Int]()
    assert_equal(len(map_stage(dbl)(empty)), 0)
    assert_equal(len(map_stage(dbl, max_concurrency=1)(empty)), 0)
    assert_equal(len(map_stage(dbl, max_concurrency=4)(empty)), 0)

    var sink0 = ListSink()
    stream_map(dbl, empty, max_in_flight=4, sink=sink0)
    assert_equal(len(sink0.items), 0)

    # n = 1
    var one: List[Int] = [42]
    var m1 = map_stage(dbl, max_concurrency=4)(one)
    assert_equal(len(m1), 1)
    assert_equal(m1[0], 84)

    var m1_seq = map_stage(dbl, max_concurrency=1)(one)
    assert_equal(len(m1_seq), 1)
    assert_equal(m1_seq[0], 84)

    var sink1 = ListSink()
    stream_map(dbl, one, max_in_flight=4, sink=sink1)
    assert_equal(len(sink1.items), 1)
    assert_equal(sink1.items[0], 84)

    # max_concurrency > len(items)
    var small: List[Int] = [1, 2, 3]
    var m_over = map_stage(dbl, max_concurrency=10)(small)
    assert_equal(len(m_over), 3)
    assert_equal(m_over[0], 2)
    assert_equal(m_over[2], 6)

    var sink_over = ListSink()
    stream_map(dbl, small, max_in_flight=10, sink=sink_over)
    assert_equal(len(sink_over.items), 3)
    assert_equal(sink_over.items[1], 4)

    # max_concurrency does NOT divide len(items) evenly (partial final wave: 7 = 3 + 3 + 1)
    var seven: List[Int] = [1, 2, 3, 4, 5, 6, 7]
    var m_partial = map_stage(dbl, max_concurrency=3)(seven)
    assert_equal(len(m_partial), 7)
    for i in range(7):
        assert_equal(m_partial[i], (i + 1) * 2)

    var sink_partial = ListSink()
    stream_map(dbl, seven, max_in_flight=3, sink=sink_partial)
    assert_equal(len(sink_partial.items), 7)
    for i in range(7):
        assert_equal(sink_partial.items[i], (i + 1) * 2)

    # max_concurrency = 1 & stream_map max_in_flight <= 1 (0 and 1)
    var m_seq = map_stage(dbl, max_concurrency=1)(seven)
    assert_equal(len(m_seq), 7)
    assert_equal(m_seq[6], 14)

    var sink_zero_inflight = ListSink()
    stream_map(dbl, seven, max_in_flight=0, sink=sink_zero_inflight)
    assert_equal(len(sink_zero_inflight.items), 7)
    assert_equal(sink_zero_inflight.items[6], 14)


# ===----------------------------------------------------------------------=== #
# 6. Resilience: Retry, Timeout, Fallback Edge Cases
# ===----------------------------------------------------------------------=== #


def test_retry_clamping_and_exact_last_attempt() raises:
    # max_attempts = 1 (no retries)
    var calls1 = 0
    var s1 = CountingFallibleStage(
        calls1,
        fail_on_calls_le=5,
        err_tag="no_retry",
    )
    var r1 = retry(s1, max_attempts=1)
    with assert_raises(contains="no_retry:1"):
        _ = r1(10)
    assert_equal(calls1, 1)

    # max_attempts = 0 (clamped to 1)
    var calls0 = 0
    var s0 = CountingFallibleStage(
        calls0,
        fail_on_calls_le=5,
        err_tag="clamped_zero",
    )
    var r0 = retry(s0, max_attempts=0)
    assert_equal(r0.max_attempts, 1)
    with assert_raises(contains="clamped_zero:1"):
        _ = r0(10)
    assert_equal(calls0, 1)

    # Negative max_attempts also clamped to 1
    var r_neg = retry(s0, max_attempts=-3)
    assert_equal(r_neg.max_attempts, 1)

    # Succeeds on the EXACT last attempt (fails 3 times, succeeds on attempt 4)
    var calls_last = 0
    var s_last = CountingFallibleStage(
        calls_last,
        fail_on_calls_le=3,
        err_tag="transient",
        offset=10,
    )
    var r_last = retry(s_last, max_attempts=4)
    assert_equal(r_last(5), 15)
    assert_equal(calls_last, 4)


def test_timeout_and_fallback_edge_cases() raises:
    # Timeout with timeout_secs=0.0 (timeout_ns=0) and negative (clamped to 0)
    var slow = RaisingFn(_slow_ok_raise)
    var t_zero = timeout(slow, timeout_secs=0.0)
    assert_equal(t_zero.timeout_ns, 0)
    with assert_raises(contains="limit: 0ns"):
        _ = t_zero(1)

    var t_neg = timeout(slow, timeout_secs=-5.0)
    assert_equal(t_neg.timeout_ns, 0)

    # Very large timeout succeeds cleanly
    var t_large = timeout(slow, timeout_secs=3600.0)
    assert_equal(t_large(41), 42)

    # Fallback: primary succeeds -> confirm secondary is NOT called!
    var pri_calls = 0
    var sec_calls = 0
    var pri_ok = CountingFallibleStage(
        pri_calls,
        fail_on_calls_le=0,
        offset=10,
    )
    var sec_ok = CountingFallibleStage(
        sec_calls,
        fail_on_calls_le=0,
        offset=99,
    )
    var fb_ok = fallback(pri_ok, sec_ok)
    assert_equal(fb_ok(5), 15)
    assert_equal(pri_calls, 1)
    assert_equal(sec_calls, 0)

    # Fallback: primary fails, secondary succeeds
    var pri_fail_calls = 0
    var pri_fail = CountingFallibleStage(
        pri_fail_calls,
        fail_on_calls_le=10,
        err_tag="pri_err",
    )
    var fb_recover = fallback(pri_fail, sec_ok)
    assert_equal(fb_recover(5), 104)
    assert_equal(pri_fail_calls, 1)
    assert_equal(sec_calls, 1)

    # Fallback: BOTH primary and secondary fail -> raises secondary's error
    var sec_fail_calls = 0
    var sec_fail = CountingFallibleStage(
        sec_fail_calls,
        fail_on_calls_le=10,
        err_tag="sec_err",
    )
    var fb_both_fail = fallback(pri_fail, sec_fail)
    with assert_raises(contains="sec_err:1"):
        _ = fb_both_fail(5)
    assert_equal(pri_fail_calls, 2)
    assert_equal(sec_fail_calls, 1)


# ===----------------------------------------------------------------------=== #
# 7. Executors: BoundedExecutor & TracingExecutor Reuse & Nesting
# ===----------------------------------------------------------------------=== #


def test_bounded_and_tracing_executors_edge_cases() raises:
    var f1 = Fn(_slow_mul2)
    var f2 = Fn(_add_k[1])
    var f3 = Fn(_mul_k[3])
    var par = f1 & f2 & f3

    # BoundedExecutor clamping and boundary worker counts
    var b0 = BoundedExecutor(max_workers=0)
    assert_equal(b0.concurrency_limit(), 1)
    var r0 = par.run_with(b0, 4)
    assert_equal(r0[0], 8)
    assert_equal(r0[1], 5)
    assert_equal(r0[2], 12)

    var b1 = BoundedExecutor(max_workers=1)
    assert_equal(b1.concurrency_limit(), 1)
    var r1 = par.run_with(b1, 4)
    assert_equal(r1[0], 8)
    assert_equal(r1[1], 5)
    assert_equal(r1[2], 12)

    var b_over = BoundedExecutor(max_workers=16)
    assert_equal(b_over.concurrency_limit(), 16)
    var r_over = par.run_with(b_over, 4)
    assert_equal(r_over[0], 8)
    assert_equal(r_over[1], 5)
    assert_equal(r_over[2], 12)

    # TracingExecutor: reuse across multiple runs, clear(), and nested executors
    var t_default = TracingExecutor()
    _ = par.run_with(t_default, 2)
    assert_equal(len(t_default.spans), 3)
    # Second run accumulates without clear()
    _ = par.run_with(t_default, 3)
    assert_equal(len(t_default.spans), 6)
    t_default.clear()
    assert_equal(len(t_default.spans), 0)
    assert_equal(t_default.total_duration_ns(), 0)
    # Reusable after clear()
    _ = par.run_with(t_default, 4)
    assert_equal(len(t_default.spans), 3)

    # TracingExecutor[SequentialExecutor] guarantees monotonic non-overlapping spans
    var t_seq = TracingExecutor[SequentialExecutor](SequentialExecutor())
    var rs = par.run_with(t_seq, 4)
    assert_equal(rs[0], 8)
    assert_equal(len(t_seq.spans), 3)
    assert_true(t_seq.spans[0].end_ns <= t_seq.spans[1].start_ns)
    assert_true(t_seq.spans[1].end_ns <= t_seq.spans[2].start_ns)

    # TracingExecutor[BoundedExecutor(max_workers=2)]
    var t_bounded = TracingExecutor[BoundedExecutor](
        BoundedExecutor(max_workers=2)
    )
    var rb = par.run_with(t_bounded, 4)
    assert_equal(rb[0], 8)
    assert_equal(rb[1], 5)
    assert_equal(rb[2], 12)
    assert_equal(len(t_bounded.spans), 3)
    assert_equal(t_bounded.concurrency_limit(), 2)
    # Wave 1 (branches 0, 1) finishes before Wave 2 (branch 2) starts
    assert_true(t_bounded.spans[0].end_ns <= t_bounded.spans[2].start_ns)
    assert_true(t_bounded.spans[1].end_ns <= t_bounded.spans[2].start_ns)

    # TracingExecutor[BoundedExecutor(max_workers=1)] runs sequentially
    var t_b1 = TracingExecutor[BoundedExecutor](BoundedExecutor(max_workers=1))
    _ = par.run_with(t_b1, 4)
    assert_equal(len(t_b1.spans), 3)
    assert_true(t_b1.spans[0].end_ns <= t_b1.spans[1].start_ns)
    assert_true(t_b1.spans[1].end_ns <= t_b1.spans[2].start_ns)

    # Also verify comptime pipeline with TracingExecutor[BoundedExecutor] & TracingExecutor[SequentialExecutor]
    comptime ct_par = F[_slow_mul2] & F[_add_k[1]] & F[_mul_k[3]]
    var ct_t_bounded = TracingExecutor[BoundedExecutor](
        BoundedExecutor(max_workers=2)
    )
    var ct_rb = ct_par.run_with(ct_t_bounded, 4)
    assert_equal(ct_rb[0], 8)
    assert_equal(ct_rb[2], 12)
    assert_equal(len(ct_t_bounded.spans), 3)
    assert_true(ct_t_bounded.spans[0].end_ns <= ct_t_bounded.spans[2].start_ns)

    var ct_t_seq = TracingExecutor[SequentialExecutor](SequentialExecutor())
    _ = ct_par.run_with(ct_t_seq, 4)
    assert_equal(len(ct_t_seq.spans), 3)
    assert_true(ct_t_seq.spans[0].end_ns <= ct_t_seq.spans[1].start_ns)


# ===----------------------------------------------------------------------=== #
# 8. Stateful & Async Stateful Ordering and Mutation Counts
# ===----------------------------------------------------------------------=== #


def test_stateful_stage_order_and_mutation_counts() raises:
    var a = OrderedMutStage(1)
    var b = OrderedMutStage(10)
    var c = OrderedMutStage(100)
    var d = OrderedMutStage(1000)

    var par = b & c
    var pipe = a | (par^) | d

    for run_idx in range(1, 4):
        pipe()
        assert_equal(a.count, 1 * run_idx)
        assert_equal(b.count, 10 * run_idx)
        assert_equal(c.count, 100 * run_idx)
        assert_equal(d.count, 1000 * run_idx)
        # Strict barrier ordering: a finishes before b & c start; b & c finish before d starts
        assert_true(a.end <= b.start)
        assert_true(a.end <= c.start)
        assert_true(b.end <= d.start)
        assert_true(c.end <= d.start)
        # Parallel overlap between b and c
        assert_true(b.start < c.end)
        assert_true(c.start < b.end)


def test_stateful_async_stage_order_and_mutation_counts() raises:
    var a = OrderedAsyncMutStage(1)
    var b = OrderedAsyncMutStage(10)
    var c = OrderedAsyncMutStage(100)
    var d = OrderedAsyncMutStage(1000)

    var par = b & c
    var pipe = a | (par^) | d

    for run_idx in range(1, 4):
        pipe.run()
        assert_equal(a.count, 1 * run_idx)
        assert_equal(b.count, 10 * run_idx)
        assert_equal(c.count, 100 * run_idx)
        assert_equal(d.count, 1000 * run_idx)
        assert_true(a.end <= b.start)
        assert_true(a.end <= c.start)
        assert_true(b.end <= d.start)
        assert_true(c.end <= d.start)
        assert_true(b.start < c.end)
        assert_true(c.start < b.end)


# ===----------------------------------------------------------------------=== #
# 9. Safety Regression Tests (C1, C2, C5, M1, L2)
# ===----------------------------------------------------------------------=== #

comptime _BOX_MAGIC: Int = 0x5AFEC0DE


struct _TrackedCounters:
    var constructed: Atomic[Int64]
    var destroyed: Atomic[Int64]
    var corrupt: Atomic[Int64]

    def __init__(out self):
        self.constructed = Atomic[Int64](0)
        self.destroyed = Atomic[Int64](0)
        self.corrupt = Atomic[Int64](0)


struct _TrackedBox(Movable):
    var magic: Int
    var payload: Int
    var counters: Pointer[_TrackedCounters, MutUntrackedOrigin]

    def __init__(
        out self,
        payload: Int,
        counters: Pointer[_TrackedCounters, MutUntrackedOrigin],
    ):
        self.magic = _BOX_MAGIC
        self.payload = payload
        self.counters = counters
        _ = self.counters[].constructed.fetch_add(1)

    def __init__(out self, *, deinit move: Self):
        self.magic = move.magic
        self.payload = move.payload
        self.counters = move.counters

    def __deinit__(deinit self):
        if self.magic == _BOX_MAGIC:
            _ = self.counters[].destroyed.fetch_add(1)
        else:
            # Invoked on uninitialized / corrupted memory!
            _ = self.counters[].corrupt.fetch_add(1)


struct _MakeBoxStage(pipeline.ComposableStage, Movable):
    comptime I = Int
    comptime O = _TrackedBox

    var offset: Int
    var counters: Pointer[_TrackedCounters, MutUntrackedOrigin]

    def __init__(
        out self,
        offset: Int,
        counters: Pointer[_TrackedCounters, MutUntrackedOrigin],
    ):
        self.offset = offset
        self.counters = counters

    def __call__(self, arg: Int) -> _TrackedBox:
        return _TrackedBox(arg + self.offset, self.counters)


struct _FallibleBoxStage(ComposableFallibleStage, Movable):
    comptime I = Int
    comptime O = _TrackedBox

    var offset: Int
    var should_fail: Bool
    var counters: Pointer[_TrackedCounters, MutUntrackedOrigin]

    def __init__(
        out self,
        offset: Int,
        should_fail: Bool,
        counters: Pointer[_TrackedCounters, MutUntrackedOrigin],
    ):
        self.offset = offset
        self.should_fail = should_fail
        self.counters = counters

    def __call__(self, arg: Int) raises -> _TrackedBox:
        if self.should_fail:
            raise Error("box_branch_failed")
        return _TrackedBox(arg + self.offset, self.counters)


def _make_list_stage[offset: Int](x: Int) -> List[Int]:
    var out = List[Int](capacity=16)
    for i in range(16):
        out.append(x + offset + i)
    return out^


__async def _async_make_list[offset: Int](x: Int) -> List[Int]:
    var out = List[Int](capacity=16)
    for i in range(16):
        out.append(x + offset + i)
    return out^


def _raising_make_list[offset: Int](x: Int) raises -> List[Int]:
    var out = List[Int](capacity=16)
    for i in range(16):
        out.append(x + offset + i)
    return out^


def test_c1_uninitialized_storage_nontrivial_outputs() raises:
    var counters = _TrackedCounters()
    var cptr = Pointer(to=counters).unsafe_origin_cast[MutUntrackedOrigin]()

    # 1. Borrowed Parallel (__call__ + SequentialExecutor + BoundedExecutor + TracingExecutor)
    var b1 = _MakeBoxStage(1, cptr)
    var b2 = _MakeBoxStage(2, cptr)
    var b3 = _MakeBoxStage(3, cptr)
    var par = b1 & b2 & b3
    var r1 = par(10)
    assert_equal(r1[0].payload, 11)
    assert_equal(r1[1].payload, 12)
    assert_equal(r1[2].payload, 13)
    _ = r1^

    var seq = SequentialExecutor()
    var r2 = par.run_with(seq, 20)
    assert_equal(r2[0].payload, 21)
    assert_equal(r2[2].payload, 23)
    _ = r2^

    var b_exec = BoundedExecutor(max_workers=2)
    var r3 = par.run_with(b_exec, 30)
    assert_equal(r3[1].payload, 32)
    _ = r3^

    var tracer = TracingExecutor()
    var r4 = par.run_with(tracer, 40)
    assert_equal(r4[0].payload, 41)
    _ = r4^

    # 2. OwnedParallel (__call__ + run_with)
    var own_par = owned(_MakeBoxStage(5, cptr)) & _MakeBoxStage(6, cptr)
    var r5 = own_par(10)
    assert_equal(r5[0].payload, 15)
    assert_equal(r5[1].payload, 16)
    _ = r5^

    var r6 = own_par.run_with(seq, 10)
    assert_equal(r6[0].payload, 15)
    assert_equal(r6[1].payload, 16)
    _ = r6^

    var r7 = own_par.run_with(tracer, 10)
    assert_equal(r7[0].payload, 15)
    _ = r7^

    # 3. Zip2 & Zip3 with TrackedBox
    var z2 = zip_stages(b1, b2)
    var r8 = z2((10, 20))
    assert_equal(r8[0].payload, 11)
    assert_equal(r8[1].payload, 22)
    _ = r8^

    var z3 = zip_stages(b1, b2, b3)
    var r9 = z3((10, 20, 30))
    assert_equal(r9[0].payload, 11)
    assert_equal(r9[1].payload, 22)
    assert_equal(r9[2].payload, 33)
    _ = r9^

    # 4. RaisingParallel success path with TrackedBox
    var fb1 = _FallibleBoxStage(10, False, cptr)
    var fb2 = _FallibleBoxStage(20, False, cptr)
    var rpar = fb1 & fb2
    var r10 = rpar(5)
    assert_equal(r10[0].payload, 15)
    assert_equal(r10[1].payload, 25)
    _ = r10^

    # All constructed boxes must be cleanly destroyed with ZERO uninitialized deinits!
    assert_equal(counters.corrupt.load(), 0)
    assert_equal(counters.constructed.load(), counters.destroyed.load())
    assert_true(counters.constructed.load() > 0)

    # 5. Heap-allocated List[Int] across Parallel, compt.Parallel, AsyncParallel, RaisingParallel
    var l1 = Fn(_make_list_stage[1])
    var l2 = Fn(_make_list_stage[2])
    var lp = l1 & l2
    var lr = lp(10)
    assert_equal(len(lr[0]), 16)
    assert_equal(lr[0][0], 11)
    assert_equal(lr[1][15], 27)

    comptime ct_lp = F[_make_list_stage[10]] & F[_make_list_stage[20]]
    var ct_lr = ct_lp.run(5)
    assert_equal(ct_lr[0][0], 15)
    assert_equal(ct_lr[1][0], 25)
    var ct_ls = ct_lp.run_sequential(5)
    assert_equal(ct_ls[0][0], 15)
    assert_equal(ct_ls[1][0], 25)
    var ct_lw = ct_lp.run_with(seq, 5)
    assert_equal(ct_lw[0][0], 15)

    comptime async_lp = AF[_async_make_list[100]] & AF[_async_make_list[200]]
    var async_lr = async_lp.run(7)
    assert_equal(async_lr[0][0], 107)
    assert_equal(async_lr[1][0], 207)

    var rl1 = RaisingFn(_raising_make_list[3])
    var rl2 = RaisingFn(_raising_make_list[4])
    var rlp = rl1 & rl2
    var rlr = rlp(1)
    assert_equal(rlr[0][0], 4)
    assert_equal(rlr[1][0], 5)


def test_c2_raising_parallel_destroys_succeeded_branches_on_error() raises:
    var counters = _TrackedCounters()
    var cptr = Pointer(to=counters).unsafe_origin_cast[MutUntrackedOrigin]()

    var ok1 = _FallibleBoxStage(1, False, cptr)
    var fail_mid = _FallibleBoxStage(2, True, cptr)
    var ok3 = _FallibleBoxStage(3, False, cptr)

    # 2-branch: branch 0 succeeds, branch 1 fails -> branch 0's TrackedBox must be destroyed
    var p2 = ok1 & fail_mid
    with assert_raises(contains="box_branch_failed"):
        _ = p2(20)
    assert_equal(counters.corrupt.load(), 0)
    assert_equal(counters.constructed.load(), 1)
    assert_equal(counters.destroyed.load(), 1)

    # 3-branch: branches 0 and 2 succeed, branch 1 fails -> both must be destroyed
    var p3 = ok1 & fail_mid & ok3
    with assert_raises(contains="box_branch_failed"):
        _ = p3(20)
    assert_equal(counters.corrupt.load(), 0)
    assert_equal(counters.constructed.load(), 3)
    assert_equal(counters.destroyed.load(), 3)


def test_c5_timeout_fptosi_and_retry_nonfinite_guards() raises:
    var slow = RaisingFn(_slow_ok_raise)

    # Huge finite, +inf, -inf, NaN must never trigger fptosi poison UB
    var t_huge = timeout(slow, timeout_secs=1e20)
    assert_equal(t_huge.timeout_ns, Int.MAX)
    assert_equal(t_huge(41), 42)

    var t_pos_inf = timeout(slow, timeout_secs=inf[.float64]())
    assert_equal(t_pos_inf.timeout_ns, Int.MAX)
    assert_equal(t_pos_inf(9), 10)

    var t_neg_inf = timeout(slow, timeout_secs=-inf[.float64]())
    assert_equal(t_neg_inf.timeout_ns, 0)

    var t_nan = timeout(slow, timeout_secs=nan[.float64]())
    assert_equal(t_nan.timeout_ns, 0)

    # Retry with NaN / +inf backoff parameters must sanitize cleanly
    var calls = 0
    var s = CountingFallibleStage(calls, fail_on_calls_le=2, offset=5)
    var r = retry(
        s,
        max_attempts=3,
        backoff_secs=nan[.float64](),
        backoff_multiplier=inf[.float64](),
    )
    assert_equal(r.backoff_secs, 0.0)
    assert_equal(r.backoff_multiplier, 1.0)
    assert_equal(r(10), 15)
    assert_equal(calls, 3)


struct _TokenCheckingExecutor(Executor, Movable):
    comptime IS_PARALLEL: Bool = False
    var next_token: Int
    var matched_count: Int
    var mismatched_count: Int
    var stack: List[Int]

    def __init__(out self):
        self.next_token = 100
        self.matched_count = 0
        self.mismatched_count = 0
        self.stack = List[Int]()

    def concurrency_limit(self) -> Int:
        return 1

    def is_tracing(self) -> Bool:
        return False

    def on_stage_start(mut self, name: StaticString) -> Int:
        var tok = self.next_token
        self.next_token += 1
        self.stack.append(tok)
        return tok

    def on_stage_end(mut self, name: StaticString, token: Int):
        var expected = self.stack.pop() if len(self.stack) > 0 else -1
        if token == expected:
            self.matched_count += 1
        else:
            self.mismatched_count += 1

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        pass


def test_m1_tracing_inner_token_and_zip3_bounded_traced() raises:
    # TracingExecutor must forward the inner executor's token, NOT its own timestamp
    var f1 = Fn(_add_k[1])
    var f2 = Fn(_mul_k[2])
    var seq_pipe = f1 | f2
    var wrapped = TracingExecutor[_TokenCheckingExecutor](
        _TokenCheckingExecutor()
    )
    assert_equal(seq_pipe.run_with(wrapped, 5), 12)
    assert_equal(wrapped.inner.matched_count, 2)
    assert_equal(wrapped.inner.mismatched_count, 0)
    assert_equal(len(wrapped.spans), 2)

    # Zip3.run_with must honor BoundedExecutor(max_workers=2) and emit 3 per-branch spans
    var z1 = Fn(_slow_mul2)
    var z2 = Fn(_add_k[1])
    var z3_stage = Fn(_mul_k[3])
    var z3 = zip_stages(z1, z2, z3_stage)

    var t_bounded = TracingExecutor[BoundedExecutor](
        BoundedExecutor(max_workers=2)
    )
    var res = z3.run_with(t_bounded, (4, 10, 7))
    assert_equal(res[0], 8)
    assert_equal(res[1], 11)
    assert_equal(res[2], 21)
    assert_equal(len(t_bounded.spans), 3)
    # Wave 1 (branches 0, 1) finishes before Wave 2 (branch 2) starts
    assert_true(t_bounded.spans[0].end_ns <= t_bounded.spans[2].start_ns)
    assert_true(t_bounded.spans[1].end_ns <= t_bounded.spans[2].start_ns)


def test_l2_graph_builder_label_escaping() raises:
    var b_dot = GraphBuilder(is_dot=True)
    _ = b_dot.add_node('a\\b "c"\nd]', List[Int]())
    var dot = b_dot.finish()
    assert_true('a\\\\b \'c\'\\nd]' in dot)

    var b_mmd = GraphBuilder(is_dot=False)
    _ = b_mmd.add_node('a\\b "c"\nd]', List[Int]())
    var mmd = b_mmd.finish()
    assert_true("a\\\\b 'c' d&#93;" in mmd)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
