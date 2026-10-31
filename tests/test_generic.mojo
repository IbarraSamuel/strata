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

    var graph = p1 + p2 + p3

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
    var graph = itof + itoi >> stp + stp

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

    var final_graph = stoi >> mul2 + itof + mul3 >> sum_tp >> ftos

    var result = final_graph("32")
    assert_equal(result, "192.0")

    var struct_graph = (
        StringToIntTask()
        >> IntMulTask[2]() + IntToFloatTask() + IntMulTask[3]()
        >> SumTuple()
        >> FloatToStringTask()
    )

    var result_2 = struct_graph("32")
    assert_equal(result_2, "192.0")


def test_sequence_add() raises:
    # Test Sequence.__add__: combining a Sequence in parallel with another Callable
    var stoi = generic.Fn(string_to_int)
    var itof = generic.Fn(int_to_float_g)
    var seq = stoi >> itof

    var standalone_fn = generic.Fn(string_to_int)
    var par_graph = seq + standalone_fn

    var r1, r2 = par_graph("10")
    assert_equal(r1, 10.0)
    assert_equal(r2, 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
