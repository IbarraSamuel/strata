"""Tests for Strata v2 compile-time pipelines (`strata.pipeline.compt`)."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.pipeline.compt import F, Unit, group

comptime TIME = 0.001


def add_k[k: Int](x: Int) -> Int:
    return x + k


def mul_k[k: Int](x: Int) -> Int:
    return x * k


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def sum_two(v: Tuple[Int, Int]) -> Int:
    return v[0] + v[1]


def sum_three(v: Tuple[Int, Int, Int]) -> Int:
    return v[0] + v[1] + v[2]


def sum_four(v: Tuple[Int, Int, Int, Int]) -> Int:
    return v[0] + v[1] + v[2] + v[3]


def sum_nested_pairs(v: Tuple[Tuple[Int, Int], Tuple[Int, Int]]) -> Int:
    return v[0][0] + v[0][1] + v[1][0] + v[1][1]


def to_str(x: Int) -> String:
    return String("res=", x)


def unit_sleep():
    sleep(TIME)


def test_comptime_parallel_overlap() raises:
    def timed(v: NoneType) -> Tuple[Int, Int]:
        var start = monotonic()
        sleep(TIME)
        var end = monotonic()
        return start, end

    comptime graph = F[timed] & F[timed] & F[timed]
    var p1, p2, p3 = graph.run(None)

    assert_true(p1[0] < p2[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p3[1])
    assert_true(p3[0] < p2[1])


def test_comptime_full_associative_flattening() raises:
    # a & (b & c) flattens to Tuple[Int, Int, Int]
    comptime right_flat = F[add_k[1]] & (F[mul_k[2]] & F[add_k[3]])
    var r0, r1, r2 = right_flat(5)
    assert_equal(r0, 6)
    assert_equal(r1, 10)
    assert_equal(r2, 8)

    # (a & b) & (c & d) flattens to Tuple[Int, Int, Int, Int]
    comptime par_of_par = (F[add_k[1]] & F[mul_k[2]]) & (
        F[add_k[3]] & F[mul_k[4]]
    )
    comptime reduced = par_of_par | F[sum_four]
    assert_equal(reduced(5), 44)

    # Explicit group(...) preserves nested tuples symmetrically
    comptime grouped = (
        group(F[add_k[1]] & F[mul_k[2]]) & group(F[add_k[3]] & F[mul_k[4]])
    ) | F[sum_nested_pairs]
    assert_equal(grouped(5), 44)


def test_comptime_run_on_parallel_and_diamond() raises:
    # Parallel.comptime_run now works safely at compile time via sequential fallback!
    comptime par = F[mul_k[2]] & F[mul_k[3]]
    comptime ct_pair = par.comptime_run[4]
    assert_equal(ct_pair[0], 8)
    assert_equal(ct_pair[1], 12)

    # Full diamond pipeline evaluated at BOTH compile time and runtime!
    comptime diamond = (
        F[add_k[1]]
        | ((F[mul_k[2]] & F[add_k[5]]) & F[mul_k[3]])
        | F[sum_three]
        | F[to_str]
    )
    comptime ct_res = diamond.comptime_run[4]
    assert_equal(ct_res, "res=35")
    assert_equal(diamond.run(4), "res=35")
    assert_equal(diamond.F(4), "res=35")


def drop_unit3(v: Tuple[NoneType, NoneType, NoneType]) -> NoneType:
    return None


def test_unit_void_comptime_pipeline() raises:
    # Replaces legacy strata.void.type
    comptime workflow = (
        Unit[unit_sleep]
        | (Unit[unit_sleep] & Unit[unit_sleep] & Unit[unit_sleep])
        | F[drop_unit3]
        | Unit[unit_sleep]
    )
    var t0 = monotonic()
    _ = workflow.run(None)
    var t1 = monotonic()
    assert_true(t1 > t0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
