"""Tests for Strata v2 dataflow combinators (`Id`, `Select`, `Spread`, `Zip`,
`Map`, `Branch`) in runtime and comptime pipelines.
"""

from std.testing import TestSuite, assert_equal, assert_true
from std.time import sleep

from strata.executors import BoundedExecutor, SequentialExecutor, TracingExecutor
from strata.pipeline import Fn
from strata.pipeline.combinators import (
    branch,
    identity,
    map_stage,
    select,
    spread,
    zip_stages,
)
from strata.pipeline.compt import F, Id, Spread2, Spread3


def _inc(x: Int) -> Int:
    return x + 1


def _dbl(x: Int) -> Int:
    return x * 2


def _neg(x: Int) -> Int:
    return -x


def _to_str(x: Int) -> String:
    return String(x)


def _str_len(s: String) -> Int:
    return s.byte_length()


def _is_even(x: Int) -> Bool:
    return x % 2 == 0


def _add2(a: Int, b: Int) -> Int:
    return a + b


def _sum3(a: Int, b: Int, c: Int) -> Int:
    return a + b + c


def _sum4(a: Int, b: Int, c: Int, d: Int) -> Int:
    return a + b + c + d


def _slow_square(x: Int) -> Int:
    sleep(0.01)
    return x * x


def test_identity_and_select() raises:
    var id_int = identity[Int]()
    var dbl = Fn(_dbl)
    var pick_first = select[0, Int, Int]()
    var pick_second = select[1, Int, Int]()

    var keep_and_double = id_int & dbl
    var pair = keep_and_double(7)
    assert_equal(pair[0], 7)
    assert_equal(pair[1], 14)

    var p0 = keep_and_double | pick_first
    var p1 = keep_and_double | pick_second
    assert_equal(p0(7), 7)
    assert_equal(p1(7), 14)


def test_spread_2_3_4() raises:
    var f1 = Fn(_inc)
    var f2 = Fn(_dbl)
    var f3 = Fn(_neg)
    var id_int = identity[Int]()

    var s2 = spread(_add2)
    var s3 = spread(_sum3)
    var s4 = spread(_sum4)

    var p2 = (f1 & f2) | s2
    assert_equal(p2(5), 6 + 10)

    var p3 = (f1 & f2 & f3) | s3
    assert_equal(p3(5), 6 + 10 - 5)

    var p4 = (f1 & f2 & f3 & id_int) | s4
    assert_equal(p4(5), 6 + 10 - 5 + 5)


def test_zip_stages_parallel_product() raises:
    var dbl = Fn(_dbl)
    var slen = Fn(_str_len)
    var inc = Fn(_inc)

    var z2 = zip_stages(dbl, slen)
    var r2 = z2((6, String("hello")))
    assert_equal(r2[0], 12)
    assert_equal(r2[1], 5)

    var z3 = zip_stages(dbl, slen, inc)
    var r3 = z3((3, String("ab"), 10))
    assert_equal(r3[0], 6)
    assert_equal(r3[1], 2)
    assert_equal(r3[2], 11)

    # Compose zip directly after a fan-out!
    var to_s = Fn(_to_str)
    var composed = (inc & to_s) | z2 | spread(_add2)
    # 99 -> (100, "99") -> (200, 2) -> 202
    assert_equal(composed(99), 202)

    # Works with TracingExecutor and SequentialExecutor
    var tracer = TracingExecutor()
    assert_equal(composed.run_with(tracer, 99), 202)
    assert_true(len(tracer.spans) >= 4)

    var seq = SequentialExecutor()
    assert_equal(composed.run_with(seq, 99), 202)


def test_map_stage_parallel_and_bounded() raises:
    var sq = Fn(_slow_square)
    var mapper = map_stage(sq)
    var bounded_mapper = map_stage(sq, max_concurrency=2)

    var items: List[Int] = [1, 2, 3, 4, 5]
    var out = mapper(items)
    assert_equal(len(out), 5)
    assert_equal(out[0], 1)
    assert_equal(out[1], 4)
    assert_equal(out[2], 9)
    assert_equal(out[3], 16)
    assert_equal(out[4], 25)

    var out_bounded = bounded_mapper(items)
    assert_equal(out_bounded[3], 16)
    assert_equal(out_bounded[4], 25)

    # Empty input
    var empty = List[Int]()
    assert_equal(len(mapper(empty)), 0)

    # Works with SequentialExecutor and BoundedExecutor
    var seq = SequentialExecutor()
    var b_exec = BoundedExecutor(max_workers=2)
    var out_seq = mapper.run_with(seq, items)
    var out_b = mapper.run_with(b_exec, items)
    assert_equal(out_seq[2], 9)
    assert_equal(out_b[2], 9)


def test_branch_routing() raises:
    var on_even = Fn(_dbl)
    var on_odd = Fn(_inc)
    var router = branch(_is_even, on_even, on_odd)

    assert_equal(router(4), 8)
    assert_equal(router(5), 6)

    # Compose inside a larger pipeline and trace
    var post = Fn(_inc)
    var pipe = router | post
    var tracer = TracingExecutor()
    assert_equal(pipe.run_with(tracer, 4), 9)
    assert_equal(len(tracer.spans), 2)


def test_compt_id_and_spread() raises:
    comptime p2 = (Id[Int] & F[_dbl]) | Spread2[_add2]
    assert_equal(p2(6), 18)
    comptime c2 = p2.comptime_run[6]
    assert_equal(c2, 18)

    comptime p3 = (F[_inc] & F[_dbl] & F[_neg]) | Spread3[_sum3]
    assert_equal(p3(5), 11)
    comptime c3 = p3.comptime_run[5]
    assert_equal(c3, 11)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
