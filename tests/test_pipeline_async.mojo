"""Tests for Strata v2 asynchronous compile-time pipelines (`strata.pipeline.async_fn`)."""

from std.testing import TestSuite, assert_equal

from strata.pipeline.async_fn import AF, AsyncFn, Sync, group, par_fn, par_fns


def parse_int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


__async def async_add[k: Int](v: Int) -> Int:
    return v + k


__async def async_mul[k: Int](v: Int) -> Int:
    return v * k


__async def async_itof(v: Int) -> Float32:
    return Float32(v)


def sum_three(v: Tuple[Int, Float32, Int]) -> Float32:
    return Float32(v[0]) + v[1] + Float32(v[2])


__async def async_format_f32(v: Float32) -> String:
    return String("val=", v)


def sum_nested(v: Tuple[Tuple[Int, Int], Tuple[Int, Int]]) -> Int:
    return v[0][0] + v[0][1] + v[1][0] + v[1][1]


def test_async_non_trivial_input_and_parallel_pipe() raises:
    # String input (non-TrivialRegisterPassable) AND piping AsyncParallel
    # directly into downstream Sync + AsyncFn stages via `|`!
    comptime diamond = (
        Sync[parse_int]
        | (AF[async_mul[2]] & AF[async_itof] & AF[async_mul[3]])
        | Sync[sum_three]
        | AF[async_format_f32]
    )
    assert_equal(diamond.run("10"), "val=60.0")
    assert_equal(diamond("5"), "val=30.0")


def test_async_full_associative_flattening_and_group() raises:
    var f1 = AF[async_add[1]]
    var f2 = AF[async_mul[2]]
    var f3 = AF[async_add[3]]
    var f4 = AF[async_mul[4]]

    # a & (b & c) flattens to 3-tuple
    var right_flat = f1 & (f2 & f3)
    var r0, r1, r2 = right_flat(5)
    assert_equal(r0, 6)
    assert_equal(r1, 10)
    assert_equal(r2, 8)

    # (a & b) & (c & d) flattens to 4-tuple
    var par_flat = (f1 & f2) & (f3 & f4)
    var p0, p1, p2, p3 = par_flat(5)
    assert_equal(p0, 6)
    assert_equal(p1, 10)
    assert_equal(p2, 8)
    assert_equal(p3, 20)

    # Explicit group(...) preserves nested tuples
    var grouped = (group(f1 & f2) & group(f3 & f4)) | Sync[sum_nested]
    assert_equal(grouped(5), 44)


def test_async_standalone_helpers() raises:
    var pair = par_fn[async_itof, async_mul[2]](10)
    assert_equal(pair[0], 10.0)
    assert_equal(pair[1], 20)

    var triple = par_fns[
        AsyncFn[async_add[1]],
        AsyncFn[async_mul[2]],
        AsyncFn[async_add[3]],
    ](4)
    assert_equal(triple[0], 5)
    assert_equal(triple[1], 8)
    assert_equal(triple[2], 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
