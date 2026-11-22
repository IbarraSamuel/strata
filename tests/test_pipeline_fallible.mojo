"""Tests for Strata v2 fallible (raising) pipelines (`strata.pipeline.fallible`)."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from strata.pipeline.fallible import RaisingFn, raising_group


def parse_strict(raw: String) raises -> Int:
    return Int(raw)


def ensure_positive(x: Int) raises -> Int:
    if x <= 0:
        raise Error(String("expected positive int, got ", x))
    return x


def double_ok(x: Int) raises -> Int:
    return x * 2


def fail_if_even(x: Int) raises -> Int:
    if x % 2 == 0:
        raise Error(String("even not allowed: ", x))
    return x + 1


def fail_if_gt_ten(x: Int) raises -> Int:
    if x > 10:
        raise Error(String("too large: ", x))
    return x * 3


def sum_three_raising(v: Tuple[Int, Int, Int]) raises -> Int:
    return v[0] + v[1] + v[2]


def sum_nested_raising(
    v: Tuple[Tuple[Int, Int], Tuple[Int, Int]]
) raises -> Int:
    return v[0][0] + v[0][1] + v[1][0] + v[1][1]


def test_raising_sequential_success_and_short_circuit() raises:
    var parse = RaisingFn(parse_strict)
    var pos = RaisingFn(ensure_positive)
    var dbl = RaisingFn(double_ok)

    var pipe = parse | pos | dbl
    assert_equal(pipe("21"), 42)

    with assert_raises():
        _ = pipe("not-an-int")

    with assert_raises(contains="expected positive int, got -5"):
        _ = pipe("-5")


def test_raising_parallel_success_flattening_and_group() raises:
    var pos = RaisingFn(ensure_positive)
    var odd = RaisingFn(fail_if_even)
    var small = RaisingFn(fail_if_gt_ten)
    var sum3 = RaisingFn(sum_three_raising)

    # Full associative flattening: a & (b & c) -> Tuple[Int, Int, Int]
    var right_par = odd & small
    var flat_pipe = (pos & right_par) | sum3
    # x=5 -> (5, 6, 15) -> 26
    assert_equal(flat_pipe(5), 26)

    # Explicit raising_group preserves nested tuples
    var g1 = raising_group(pos & odd)
    var g2 = raising_group(small & pos)
    var sum_nested = RaisingFn(sum_nested_raising)
    var grouped_pipe = (g1 & g2) | sum_nested
    # x=5 -> ((5, 6), (15, 5)) -> 31
    assert_equal(grouped_pipe(5), 31)


def test_raising_parallel_error_propagation() raises:
    var pos = RaisingFn(ensure_positive)
    var odd = RaisingFn(fail_if_even)
    var small = RaisingFn(fail_if_gt_ten)

    var par = pos & odd & small

    # Single branch fails (even, <= 10)
    with assert_raises(contains="even not allowed: 4"):
        _ = par(4)

    # Multiple branches fail (even AND > 10)
    with assert_raises(contains="Parallel stage failures (2)"):
        _ = par(12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
