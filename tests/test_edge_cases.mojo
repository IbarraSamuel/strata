"""Comprehensive edge-case tests across all Strata v2 Mojo modules."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from std.time import monotonic, sleep

from strata import pipeline, stateful
from strata.executors import (
    AsyncRTExecutor,
    BoundedExecutor,
    SequentialExecutor,
    TracingExecutor,
)
from strata.pipeline import Fn, group, owned, owned_group, run_with
from strata.pipeline.combinators import (
    OutputSink,
    map_stage,
    spread,
    stream_map,
)
from strata.pipeline.compt import F, Id, Spread2, Spread3, Spread4
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
