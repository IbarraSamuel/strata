"""Tests for generic pipeline runners."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata import generic

comptime TIME = 0.001


struct GenericParallel[o1: MutOrigin, o2: MutOrigin](generic.Callable):
    comptime I = Int
    comptime O = NoneType

    var start: Pointer[Int, Self.o1]
    var end: Pointer[Int, Self.o2]

    def __init__(out self, ref[Self.o1] s: Int, ref[Self.o2] e: Int):
        self.start = Pointer(to=s)
        self.end = Pointer(to=e)

    def __call__(self, v: Int):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


def test_generic_parallel() raises:
    comptime GP = GenericParallel

    var start1, end1 = (0, 0)
    var start2, end2 = (0, 0)
    var start3, end3 = (0, 0)

    var p1 = GP(start1, end1)
    var p2 = GP(start2, end2)
    var p3 = GP(start3, end3)

    var graph = p1 & p2 & p3

    var _ = graph(0)

    assert_true(p1.start[] < p1.end[])
    assert_true(p1.start[] < p2.end[])
    assert_true(p1.start[] < p3.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p2.end[])
    assert_true(p3.start[] < p2.end[])
    assert_true(p3.start[] < p3.end[])
    assert_true(p3.start[] < p3.end[])


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def int_to_int(v: Int) -> Int:
    return v


def sum_tuple(v: Tuple[Float32, Int]) -> Int:
    return Int(v[0] + Float32(v[1]))


def test_generic_two_parallels() raises:
    var itof = generic.Fn(int_to_float)
    var itoi = generic.Fn(int_to_int)
    var stp = generic.Fn(sum_tuple)
    var graph = (itof & itoi) | (stp & stp)

    var r1, r2 = graph(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


def string_to_int(str: String) -> Int:
    sleep(TIME)
    try:
        return Int(str)
    except:
        return 0


def int_to_float_g(value: Int) -> Float32:
    sleep(TIME)
    return Float32(value)


def int_mul[by: Int](value: Int) -> Int:
    sleep(TIME)
    return value * by


def sum_tuple_g(value: Tuple[Int, Float32, Int]) -> Float32:
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


def float_to_string(value: Float32) -> String:
    sleep(TIME)
    return String(value)


@fieldwise_init
struct StringToIntTask(generic.Callable):
    comptime I = String
    comptime O = Int

    def __call__(self, arg: Self.I) -> Self.O:
        sleep(TIME)
        try:
            return Int(arg)
        except:
            return 0


@fieldwise_init
struct IntToFloatTask(generic.Callable):
    comptime I = Int
    comptime O = Float32

    def __call__(self, arg: Int) -> Float32:
        sleep(TIME)
        return Float32(arg)


@fieldwise_init
struct IntMulTask[by: Int](generic.Callable):
    comptime I = Int
    comptime O = Int

    def __call__(self, arg: Self.I) -> Self.O:
        sleep(TIME)
        return arg * Self.by


@fieldwise_init
struct SumTuple(generic.Callable):
    comptime I = Tuple[Int, Float32, Int]
    comptime O = Float32

    def __call__(self, arg: Self.I) -> Self.O:
        sleep(TIME)
        return Float32(arg[0]) + arg[1] + Float32(arg[2])


@fieldwise_init
struct FloatToStringTask(generic.Callable):
    comptime I = Float32
    comptime O = String

    def __call__(self, arg: Float32) -> String:
        sleep(TIME)
        return String(arg)


def test_generic_examples() raises:
    comptime Fn = generic.Fn

    var stoi = Fn(string_to_int)
    var mul2 = Fn(int_mul[2])
    var mul3 = Fn(int_mul[3])
    var itof = Fn(int_to_float_g)
    var sum_tp = Fn(sum_tuple_g)
    var ftos = Fn(float_to_string)

    var final_graph = stoi | mul2 & itof & mul3 | sum_tp | ftos

    var result = final_graph("32")
    assert_equal(result, "192.0")

    var struct_graph = (
        StringToIntTask()
        | (IntMulTask[2]() & IntToFloatTask() & IntMulTask[3]())
        | SumTuple()
        | FloatToStringTask()
    )

    var result_2 = struct_graph("32")
    assert_equal(result_2, "192.0")


def test_sequence_add() raises:
    # Test Sequence.__and__: combining a Sequence in parallel with another Callable
    var stoi = generic.Fn(string_to_int)
    var itof = generic.Fn(int_to_float_g)
    var seq = stoi | itof

    var standalone_fn = generic.Fn(string_to_int)
    var par_graph = seq & standalone_fn

    var r1, r2 = par_graph("10")
    assert_equal(r1, 10.0)
    assert_equal(r2, 10)


@fieldwise_init
struct AddOffsetTask(generic.Callable):
    comptime I = Int
    comptime O = Int

    var offset: Int

    def __call__(self, arg: Self.I) -> Self.O:
        sleep(TIME)
        return arg + self.offset


def negate_int(v: Int) -> Int:
    sleep(TIME)
    return -v


def square_int(v: Int) -> Int:
    sleep(TIME)
    return v * v


def sum_int_pair(v: Tuple[Int, Int]) -> Int:
    sleep(TIME)
    return v[0] + v[1]


def to_float64(v: Int) -> Float64:
    sleep(TIME)
    return Float64(v)


def merge_three_branches(v: Tuple[Tuple[Int, Int], Int, Float64]) -> Float64:
    sleep(TIME)
    return Float64(v[0][0] + v[0][1] + v[1]) + v[2]


def format_f64_tag(v: Float64) -> String:
    sleep(TIME)
    return String("val=", v)


def double_f64(v: Float64) -> Float64:
    sleep(TIME)
    return v * 2.0


def combine_final_summary(v: Tuple[String, Float64]) -> String:
    sleep(TIME)
    return String(v[0], "|x2=", v[1])


def test_generic_nested_diamond_pipeline() raises:
    """Verify an asymmetric multi-stage diamond-of-diamonds generic pipeline.

      Pipeline topology:
      ```text
      String -> [parse] -> Int
                            |
          +-----------------+-----------------+
          v                 v                 v
       [add1]            [sub1]         [to_float64]
          |                 |                 |
          v                 v                 |
       [mul2]          +----+----+            |
          |            v         v            |
          v         [mul3]    [add10]         |
      +---+---+        |         |            |
      v       v        +----+----+            |
    [neg]   [sq]            v                 |
      |       |        [sum_pair]             |
      +---+---+             |                 |
          +-----------------+-----------------+
                            v
                        [merge3] -> Float64
                                       |
                                 +-----+-----+
                                 v           v
                               [fmt]       [dbl]
                                 |           |
                                 +-----+-----+
                                       v
                                   [combine] -> String
      ```
    """
    var parse = StringToIntTask()

    # Branch 1: add 1 -> mul 2 -> (negate & square) -> Tuple[Int, Int]
    var add1 = AddOffsetTask(1)
    var mul2 = IntMulTask[2]()
    var neg = generic.Fn(negate_int)
    var sq = generic.Fn(square_int)
    var b1_par = neg & sq
    var branch1 = add1 | mul2 | b1_par

    # Branch 2: add -1 -> (mul 3 & add 10) -> sum pair -> Int
    var sub1 = AddOffsetTask(-1)
    var mul3 = IntMulTask[3]()
    var add10 = AddOffsetTask(10)
    var sum_pair = generic.Fn(sum_int_pair)
    var b2_par = mul3 & add10
    var branch2 = sub1 | b2_par | sum_pair

    # Branch 3: single Int -> Float64
    var branch3 = generic.Fn(to_float64)

    # Second fan-out -> fan-in
    var merge3 = generic.Fn(merge_three_branches)
    var fmt = generic.Fn(format_f64_tag)
    var dbl = generic.Fn(double_f64)
    var second_fanout = fmt & dbl
    var combine = generic.Fn(combine_final_summary)

    var par_branches = branch1 & branch2 & branch3
    var pipeline = parse | par_branches | merge3 | second_fanout | combine

    # Input "5":
    # b1: 5 -> 6 -> 12 -> (-12, 144)
    # b2: 5 -> 4 -> (12, 14) -> 26
    # b3: 5 -> 5.0
    # merge3: -12 + 144 + 26 + 5.0 = 163.0
    # final: "val=163.0|x2=326.0"
    assert_equal(pipeline("5"), "val=163.0|x2=326.0")

    # Re-run with a different input ("2"):
    # b1: 2 -> 3 -> 6 -> (-6, 36)
    # b2: 2 -> 1 -> (3, 11) -> 14
    # b3: 2 -> 2.0
    # merge3: -6 + 36 + 14 + 2.0 = 46.0
    assert_equal(pipeline("2"), "val=46.0|x2=92.0")


struct TimedMulTask[by: Int, o1: MutOrigin, o2: MutOrigin](generic.Callable):
    comptime I = Int
    comptime O = Int

    var start: Pointer[Int, Self.o1]
    var end: Pointer[Int, Self.o2]

    def __init__(out self, ref[Self.o1] s: Int, ref[Self.o2] e: Int):
        self.start = Pointer(to=s)
        self.end = Pointer(to=e)

    def __call__(self, v: Int) -> Int:
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()
        return v * Self.by


def reduce_nested_parallels(v: Tuple[Int, Int, Tuple[Int, Int]]) -> Int:
    return v[0] + v[1] + v[2][0] + v[2][1]


def test_generic_large_fanout_and_chained_parallels() raises:
    """Verify 6-way fan-out, nested parallel-of-parallels, and Fn & Sequence.

    Pipeline topologies:
    ```text
    1) 6-way fan-out:
             +-> [tm1] -----------------+
             +-> [tm2] -----------------+
      Int ---+-> [tm3] -----------------+--> Tuple[6 x Int]
             +-> [tm4] -----------------+
             +-> [add5] -> [add10] -----+
             +-> [fn_sq] ---------------+

    2) Parallel & Parallel (nested tuple):
             +-> [mul2] ----------------+
             +-> [add3] ----------------+
      Int ---+                          +--> [reducer] -> Int
             |   +-> [mul4] --+         |
             +---+-> [add5_r]-+-> Tuple-+

    3) Fn & Sequence:
             +-> [fn_head] -------------+
      Int ---+                          +--> Tuple[Int, Int]
             +-> [add1_t] -> [mul5_t] --+
    ```
    """
    var s1, e1 = (0, 0)
    var s2, e2 = (0, 0)
    var s3, e3 = (0, 0)
    var s4, e4 = (0, 0)

    var tm1 = TimedMulTask[1](s1, e1)
    var tm2 = TimedMulTask[2](s2, e2)
    var tm3 = TimedMulTask[3](s3, e3)
    var tm4 = TimedMulTask[4](s4, e4)
    var add5 = AddOffsetTask(5)
    var add10 = AddOffsetTask(10)
    var seq5 = add5 | add10
    var fn_sq = generic.Fn(square_int)

    # 6-way fanout mixing TimedMulTask, a Sequence, and an Fn
    var fanout6 = tm1 & tm2 & tm3 & tm4 & seq5 & fn_sq
    var r1, r2, r3, r4, r5, r6 = fanout6(4)
    assert_equal(r1, 4)
    assert_equal(r2, 8)
    assert_equal(r3, 12)
    assert_equal(r4, 16)
    assert_equal(r5, 19)
    assert_equal(r6, 16)

    # Verify parallel overlap across branches
    assert_true(s1 < e2)
    assert_true(s2 < e1)
    assert_true(s3 < e4)
    assert_true(s4 < e3)

    # Unexpected combination: (Parallel & Parallel) -> Tuple[Int, Int, Tuple[Int, Int]]
    var mul2 = IntMulTask[2]()
    var add3 = AddOffsetTask(3)
    var mul4 = IntMulTask[4]()
    var add5_r = AddOffsetTask(5)
    var p_left = mul2 & add3
    var p_right = mul4 & add5_r
    var p_combined = (p_left^) & p_right
    var reducer = generic.Fn(reduce_nested_parallels)
    var nested_par_pipeline = p_combined | reducer
    # input 3: (6, 6, (12, 8)) -> 32
    assert_equal(nested_par_pipeline(3), 32)

    # Fn & Sequence
    var fn_head = generic.Fn(int_to_int)
    var add1_t = AddOffsetTask(1)
    var mul5_t = IntMulTask[5]()
    var tail_seq = add1_t | mul5_t
    var fn_and_seq = fn_head & tail_seq
    var pair_out = fn_and_seq(6)
    assert_equal(pair_out[0], 6)
    assert_equal(pair_out[1], 35)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
