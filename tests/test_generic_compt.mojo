"""Tests for generic comptime pipeline runners."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.generic import compt

comptime TIME = 0.001


def test_generic_comptime_parallel() raises:
    def comptime_parallel(v: NoneType) -> Tuple[Int, Int]:
        var start = monotonic()
        sleep(TIME)
        var end = monotonic()
        return start, end

    comptime _graph = (
        compt.F[comptime_parallel].par[comptime_parallel].par[comptime_parallel]
    )

    var p1, p2, p3 = _graph.run(None)

    assert_true(p1[0] < p1[1])
    assert_true(p1[0] < p2[1])
    assert_true(p1[0] < p3[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p2[1])
    assert_true(p3[0] < p2[1])
    assert_true(p3[0] < p3[1])
    assert_true(p3[0] < p3[1])


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def int_to_int(v: Int) -> Int:
    return v


def sum_tuple(v: Tuple[Float32, Int]) -> Int:
    return Int(v[0] + Float32(v[1]))


def test_generic_comptime_two_parallels() raises:
    comptime graph = compt.F[int_to_float].par[int_to_int].seq[
        compt.F[sum_tuple].par[sum_tuple].F
    ]

    var r1, r2 = graph.run(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


def string_to_int(str: String) -> Int:
    sleep(TIME)
    try:
        return Int(str)
    except:
        return 0


def int_mul[by: Int](value: Int) -> Int:
    sleep(TIME)
    return value * by


def sum_tuple_g(value: Tuple[Int, Float32, Int]) -> Float32:
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


struct FloatToString:
    @staticmethod
    def call(value: Float32) -> String:
        sleep(TIME)
        return String(value)


def sum_tuple3(value: Tuple[Int, Float32, Int]) -> Float32:
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


def test_generic_comptime_examples() raises:
    comptime Fn = compt.F

    comptime final_g = (
        Fn[string_to_int]
        .seq[Fn[int_mul[2]].par[int_to_float].par[int_mul[3]].F]
        .seq[sum_tuple3]
        .seq[FloatToString.call]
    )

    var final_result_f = final_g.F("32")
    assert_equal(final_result_f, "192.0")


def test_generic_comptime_explicit() raises:
    def stoi(v: String) -> Int:
        try:
            return Int(v)
        except:
            return 0

    def int_m[q: Int](v: Int) -> Int:
        return q * v

    def itof(v: Int) -> Float32:
        return Float32(v)

    def sumtp(v: Tuple[Int, Float32, Int]) -> Float32:
        return Float32(v[0]) + v[1] + Float32(v[2])

    def ftos(v: Float32) -> String:
        return String(v)

    comptime F = compt.F
    comptime explicit_graph = (
        F[stoi].seq[F[int_m[2]].par[itof].par[int_m[3]].F].seq[sumtp].seq[ftos]
    )

    var s_runt_result = explicit_graph.run("32")
    assert_equal(s_runt_result, "192.0")


def double_it(x: Int) -> Int:
    return x * 2


def triple_it(x: Int) -> Int:
    return x * 3


def test_comptime_run() raises:
    # Test F runtime and comptime_run
    comptime single_f = compt.F[double_it]
    # Check at runtime
    assert_equal(single_f.run(5), 10)
    # Check comptime_run:
    comptime compt_res = single_f.comptime_run[5]
    assert_equal(compt_res, 10)

    # Test FG runtime and comptime_run
    comptime par_fg = compt.F[double_it].par[triple_it]
    var res_pair = par_fg.run(4)
    assert_equal(res_pair[0], 8)
    assert_equal(res_pair[1], 12)
    # Check comptime_run (causes miscompilation at comptime due to TaskGroup asyncrt external call):
    # comptime par_compt_res = par_fg.comptime_run[4]
    # assert_equal(par_compt_res[0], 8)
    # assert_equal(par_compt_res[1], 12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
