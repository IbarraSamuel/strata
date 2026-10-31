"""Tests for generic async function runners."""

from std.testing import TestSuite, assert_equal

from strata.generic import async_fn


__async def async_itof(v: Int) -> Float32:
    return Float32(v)


__async def async_ftoi(v: Float32) -> Int:
    return Int(v)


__async def async_double(v: Int) -> Int:
    return v * 2


def test_async_fn() raises:
    comptime AFn = async_fn.Fn
    var f1 = AFn[async_itof]()
    var f2 = AFn[async_itof]()
    var f3 = AFn[async_itof]()

    # Test parallel of 2
    var p2 = f1 + f2
    var res2 = p2.run(5)
    assert_equal(res2[0], 5.0)
    assert_equal(res2[1], 5.0)

    # Test parallel of 3 (expanded into a flat 3-element tuple, not nested)
    var p3 = f1 + f2 + f3
    var res3 = p3.run(5)
    assert_equal(res3[0], 5.0)
    assert_equal(res3[1], 5.0)
    assert_equal(res3[2], 5.0)

    # Test sequence
    var fti = AFn[async_ftoi]()
    var s = f1 >> fti
    var res_seq = s.run(5)
    assert_equal(res_seq, 5)


def test_par_fn_standalone() raises:
    var out_tuple = async_fn.par_fn[async_itof, async_double](10)
    assert_equal(out_tuple[0], 10.0)
    assert_equal(out_tuple[1], 20)


def test_fn_add_parallel() raises:
    comptime AFn = async_fn.Fn
    var f1 = AFn[async_itof]()
    var f2 = AFn[async_itof]()
    var f3 = AFn[async_itof]()

    # Test Fn + Parallel: f1 + (f2 + f3)
    var p_sub = f2 + f3
    var p_full = f1 + p_sub
    var res = p_full.run(7)
    assert_equal(res[0], 7.0)
    assert_equal(res[1], 7.0)
    assert_equal(res[2], 7.0)


def test_parallel_add_parallel() raises:
    comptime AFn = async_fn.Fn
    var f1 = AFn[async_itof]()
    var f2 = AFn[async_itof]()
    var f3 = AFn[async_itof]()
    var f4 = AFn[async_itof]()

    # Test Parallel + Parallel: (f1 + f2) + (f3 + f4)
    var p12 = f1 + f2
    var p34 = f3 + f4
    var p_all = p12 + p34
    var res = p_all.run(9)
    assert_equal(res[0], 9.0)
    assert_equal(res[1], 9.0)
    assert_equal(res[2], 9.0)
    assert_equal(res[3], 9.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
