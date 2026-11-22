"""Tests for Strata v2 runtime value-passing and owned pipelines."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata import pipeline

comptime TIME = 0.001


struct TimedStage[o1: MutOrigin, o2: MutOrigin](pipeline.ComposableStage):
    comptime I = Int
    comptime O = NoneType

    var start: Pointer[Int, Self.o1]
    var end: Pointer[Int, Self.o2]

    def __init__(out self, ref[Self.o1] s: Int, ref[Self.o2] e: Int):
        self.start = Pointer(to=s)
        self.end = Pointer(to=e)

    def __call__(self, v: Int) -> NoneType:
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()
        return None


@fieldwise_init
struct AddOffset(pipeline.ComposableStage, Movable):
    comptime I = Int
    comptime O = Int

    var offset: Int

    def __call__(self, arg: Int) -> Int:
        return arg + self.offset


@fieldwise_init
struct ScaleBy[factor: Int](pipeline.ComposableStage, Movable):
    comptime I = Int
    comptime O = Int

    def __call__(self, arg: Int) -> Int:
        return arg * Self.factor


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def square_int(v: Int) -> Int:
    return v * v


def sum_two(v: Tuple[Int, Int]) -> Int:
    return v[0] + v[1]


def sum_three(v: Tuple[Int, Int, Int]) -> Int:
    return v[0] + v[1] + v[2]


def sum_four(v: Tuple[Int, Int, Int, Int]) -> Int:
    return v[0] + v[1] + v[2] + v[3]


def sum_nested_pairs(v: Tuple[Tuple[Int, Int], Tuple[Int, Int]]) -> Int:
    return v[0][0] + v[0][1] + v[1][0] + v[1][1]


def sum_left_and_pair(v: Tuple[Int, Tuple[Int, Int]]) -> Int:
    return v[0] + v[1][0] + v[1][1]


def noop_unit():
    sleep(TIME)


def test_parallel_overlap_and_unit_fn() raises:
    var s1, e1 = (0, 0)
    var s2, e2 = (0, 0)
    var s3, e3 = (0, 0)

    var p1 = TimedStage(s1, e1)
    var p2 = TimedStage(s2, e2)
    var p3 = TimedStage(s3, e3)

    var graph = p1 & p2 & p3
    _ = graph(0)

    assert_true(s1 < e2)
    assert_true(s2 < e1)
    assert_true(s2 < e3)
    assert_true(s3 < e2)

    var u1 = pipeline.UnitFn(noop_unit)
    var u2 = pipeline.UnitFn(noop_unit)
    var unit_pipe = u1 | (u1 & u2)
    _ = unit_pipe(None)


def test_full_associative_flattening_and_reusability() raises:
    var a = AddOffset(1)
    var b = ScaleBy[2]()
    var c = AddOffset(3)
    var d = ScaleBy[4]()

    # Left-chained: a & b & c -> Tuple[Int, Int, Int]
    var left_flat = a & b & c
    var l0, l1, l2 = left_flat(5)
    assert_equal(l0, 6)
    assert_equal(l1, 10)
    assert_equal(l2, 8)

    # Right-parenthesized: a & (b & c) -> Tuple[Int, Int, Int] (flat!)
    var bc = b & c
    var right_flat = a & bc
    var r0, r1, r2 = right_flat(5)
    assert_equal(r0, 6)
    assert_equal(r1, 10)
    assert_equal(r2, 8)

    # Parallel & Parallel: (a & b) & (c & d) -> Tuple[Int, Int, Int, Int] (flat!)
    # Notice `ab` and `cd` are NOT consumed and remain reusable.
    var ab = a & b
    var cd = c & d
    var all_flat = ab & cd
    var f0, f1, f2, f3 = all_flat(5)
    assert_equal(f0, 6)
    assert_equal(f1, 10)
    assert_equal(f2, 8)
    assert_equal(f3, 20)

    # Verify `ab` and `cd` still work independently after merging.
    var ab0, ab1 = ab(2)
    assert_equal(ab0, 3)
    assert_equal(ab1, 4)

    var s4 = pipeline.Fn(sum_four)
    var merged = all_flat | s4
    assert_equal(merged(5), 44)


def test_explicit_group_nesting() raises:
    var a = AddOffset(1)
    var b = ScaleBy[2]()
    var c = AddOffset(3)
    var d = ScaleBy[4]()

    var ab = a & b
    var cd = c & d
    var g_ab = pipeline.group(ab)
    var g_cd = pipeline.group(cd)

    # Symmetric explicit nesting: Tuple[Tuple[Int, Int], Tuple[Int, Int]]
    var nested_both = g_ab & g_cd
    var reducer = pipeline.Fn(sum_nested_pairs)
    var pipe_both = nested_both | reducer
    assert_equal(pipe_both(5), 44)

    # Right-only explicit nesting: Tuple[Int, Tuple[Int, Int]]
    var bc = b & c
    var g_bc = pipeline.group(bc)
    var nested_right = a & g_bc
    var r_reducer = pipeline.Fn(sum_left_and_pair)
    var pipe_right = nested_right | r_reducer
    assert_equal(pipe_right(5), 24)


def _make_owned_factory_pipeline(
    offset: Int,
) -> pipeline.OwnedSequence[
    pipeline.OwnedSequence[
        AddOffset,
        pipeline.OwnedParallel[ScaleBy[2], pipeline.Fn[Int, Int], AddOffset],
    ],
    pipeline.Fn[Tuple[Int, Int, Int], Int],
]:
    """Factory function returning a fully owned pipeline by value."""
    var par = (
        pipeline.owned(ScaleBy[2]())
        & (pipeline.owned(pipeline.Fn(square_int)) & AddOffset(offset))
    )
    return (
        pipeline.owned(AddOffset(1))
        | par^
        | pipeline.Fn(sum_three)
    )


def test_owned_factory_pipeline() raises:
    var p = _make_owned_factory_pipeline(10)
    # x=3 -> +1=4 -> (8, 16, 14) -> 38
    assert_equal(p(3), 38)
    # Re-run with another input: x=2 -> +1=3 -> (6, 9, 13) -> 28
    assert_equal(p(2), 28)

    # Also test owned_group for explicit nested tuples.
    var g1 = pipeline.owned_group(pipeline.owned(AddOffset(1)) & ScaleBy[2]())
    var g2 = pipeline.owned_group(pipeline.owned(AddOffset(3)) & ScaleBy[4]())
    var grouped = (g1^ & g2^) | pipeline.Fn(sum_nested_pairs)
    assert_equal(grouped(5), 44)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
