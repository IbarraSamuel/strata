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
    var p2 = f1 & f2
    var res2 = p2.run(5)
    assert_equal(res2[0], 5.0)
    assert_equal(res2[1], 5.0)

    # Test parallel of 3 (expanded into a flat 3-element tuple, not nested)
    var p3 = f1 & f2 & f3
    var res3 = p3.run(5)
    assert_equal(res3[0], 5.0)
    assert_equal(res3[1], 5.0)
    assert_equal(res3[2], 5.0)

    # Test sequence
    var fti = AFn[async_ftoi]()
    var s = f1 | fti
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

    # Test Fn & Parallel: f1 & (f2 & f3)
    var p_sub = f2 & f3
    var p_full = f1 & p_sub
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

    # Test Parallel & Parallel: (f1 & f2) & (f3 & f4)
    var p12 = f1 & f2
    var p34 = f3 & f4
    var p_all = p12 & p34
    var res = p_all.run(9)
    assert_equal(res[0], 9.0)
    assert_equal(res[1], 9.0)
    assert_equal(res[2], 9.0)
    assert_equal(res[3], 9.0)


__async def async_add[k: Int](v: Int) -> Int:
    return v + k


__async def async_mul[k: Int](v: Int) -> Int:
    return v * k


__async def async_fadd[k: Int](v: Float32) -> Float32:
    return v + Float32(k)


__async def async_nested_fanout_sum(v: Int) -> Float32:
    from std.runtime._asyncrt import TaskGroup

    var r1: Float32 = 0.0
    var r2: Int = 0

    __async def step_a(x: Int, mut out_a: Float32):
        var tmp = __await async_mul[3](x)
        out_a = __await async_itof(tmp)

    __async def step_b(x: Int, mut out_b: Int):
        var tmp = __await async_add[4](x)
        out_b = __await async_double(tmp)

    var tg = TaskGroup()
    tg.create_task(step_a(v, r1))
    tg.create_task(step_b(v, r2))
    __await tg
    return r1 + Float32(r2)


def test_async_heavy_seq_and_par_pipelines() raises:
    """Verify deep async sequences and asymmetric parallel async fan-outs.

    Pipeline topologies:
    ```text
    1) Deep 6-stage async sequence (deep_seq):
       Int -> [add1] -> [mul2] -> [add5] -> [itof] -> [fadd10] -> [ftoi] -> Int

    2) Asymmetric 6-branch parallel fan-out (heavy_par):
             +-> [add1] -> [mul3] -> [itof] --------------------------+
             +-> [mul2] -> [add5] ------------------------------------+
             |               +-> [mul3] -> [itof] --+                 |
      Int ---+-> [nested] ---+-> [add4] -> [double] +-> sum -> Float32+-> Tuple6
             +-> [add1] -> [add5] -> [mul2] -> [mul3] ----------------+
             +-> [itof] -> [fadd10] ----------------------------------+
             +-> [add5] ----------------------------------------------+

    3) Direct par_fns[b1, b2, nested, b4, b5, deep_seq]
    ```
    """
    comptime AFn = async_fn.Fn

    var add1 = AFn[async_add[1]]()
    var add5 = AFn[async_add[5]]()
    var mul2 = AFn[async_mul[2]]()
    var mul3 = AFn[async_mul[3]]()
    var itof = AFn[async_itof]()
    var fadd10 = AFn[async_fadd[10]]()
    var ftoi = AFn[async_ftoi]()
    var nested = AFn[async_nested_fanout_sum]()

    # 1. Deep 6-stage sequential pipeline:
    # x -> +1 -> *2 -> +5 -> to Float32 -> +10.0 -> to Int
    var deep_seq = add1 | mul2 | add5 | itof | fadd10 | ftoi
    # x=3: 3 -> 4 -> 8 -> 13 -> 13.0 -> 23.0 -> 23
    assert_equal(deep_seq.run(3), 23)

    # 2. Asymmetric parallel branches of varying sequential depths + nested async TaskGroup:
    # Branch 1 (depth 3): add1 | mul3 | itof           => 4 -> 5 -> 15 -> 15.0
    # Branch 2 (depth 2): mul2 | add5                  => 4 -> 8 -> 13
    # Branch 3 (depth 1): nested (internal TaskGroup)  => 4 -> (12.0 + 16) = 28.0
    # Branch 4 (depth 4): add1 | add5 | mul2 | mul3    => 4 -> 5 -> 10 -> 20 -> 60
    # Branch 5 (depth 2): itof | fadd10                => 4 -> 4.0 -> 14.0
    # Branch 6 (depth 1): add5                         => 4 -> 9
    var b1 = add1 | mul3 | itof
    var b2 = mul2 | add5
    var b4 = (add1 | add5) | (mul2 | mul3)
    var b5 = itof | fadd10

    var heavy_par = (b1 & b2) & (nested & (b4 & (b5 & add5)))
    var r0, r1, r2, r3, r4, r5 = heavy_par.run(4)
    assert_equal(r0, 15.0)
    assert_equal(r1, 13)
    assert_equal(r2, 28.0)
    assert_equal(r3, 60)
    assert_equal(r4, 14.0)
    assert_equal(r5, 9)

    # 3. Direct par_fns with 6 mixed Fn stages (including composed sequences)
    var p_res = async_fn.par_fns[
        type_of(b1),
        type_of(b2),
        type_of(nested),
        type_of(b4),
        type_of(b5),
        type_of(deep_seq),
    ](3)
    # x=3:
    # b1: (3+1)*3 = 12.0
    # b2: 3*2+5 = 11
    # nested: 9.0 + 14 = 23.0
    # b4: (3+1+5)*2*3 = 54
    # b5: 3.0 + 10.0 = 13.0
    # deep_seq: 23
    assert_equal(p_res[0], 12.0)
    assert_equal(p_res[1], 11)
    assert_equal(p_res[2], 23.0)
    assert_equal(p_res[3], 54)
    assert_equal(p_res[4], 13.0)
    assert_equal(p_res[5], 23)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
