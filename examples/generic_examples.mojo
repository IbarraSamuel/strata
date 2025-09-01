from strata.generic import Callable, Fn  # , Tuple
import os
from time import sleep

alias time = 0.1


fn string_to_int(str: String) -> Int:
    print("string to int...")
    sleep(time)
    try:
        return Int(str)
    except:
        return 0


fn int_to_float(value: Int) -> Float32:
    print("int to float...")
    sleep(time)
    return value


fn int_mul[by: Int](value: Int) -> Int:
    print("Mutliply by", by, "...")
    sleep(time)
    return value * by


fn sum_tuple(value: ((Int, Float32), Int)) -> Float32:
    print("Sum tuple...")
    sleep(time)
    return value[0][0] + value[0][1] + value[1]


fn float_to_string(value: Float32) -> String:
    print("float to string...")
    sleep(time)
    return String(value)


# Struct Versions
@fieldwise_init
struct StringToIntTask(Callable):
    alias I = String
    alias O = Int

    fn __call__(self, arg: Self.I) -> Self.O:
        print("string to int...")
        sleep(time)
        try:
            return Int(arg)
        except:
            return 0


@fieldwise_init
struct IntToFloatTask(Callable):
    alias I = Int
    alias O = Float32

    fn __call__(self, arg: Int) -> Float32:
        print("int to float...")
        sleep(time)
        return arg


@fieldwise_init
struct IntMulTask[by: Int](Callable):
    alias I = Int
    alias O = Int

    fn __call__(self, arg: Self.I) -> Self.O:
        print("Mutliply by", by, "...")
        sleep(time)
        return arg * by


@fieldwise_init
struct SumTuple(Callable):
    alias I = ((Int, Float32), Int)
    alias O = Float32

    fn __call__(self, arg: ((Int, Float32), Int)) -> Float32:
        print("Sum tuple...")
        sleep(time)
        return arg[0][0] + arg[0][1] + arg[1]


@fieldwise_init
struct FloatToStringTask(Callable):
    alias I = Float32
    alias O = String

    fn __call__(self, arg: Float32) -> String:
        print("float to string...")
        sleep(time)
        return String(arg)


fn main():
    # NOTE: Compile times could be faster if you use struct instead of functions.
    print("Building graph")

    final_graph = (
        Fn(string_to_int)
        >> Fn(int_mul[2]) + Fn(int_to_float) + Fn(int_mul[3])
        >> Fn(sum_tuple)
        >> Fn(float_to_string)
    )

    print("Starting Graph execution")
    result = final_graph("32")

    print(result)

    print("Building Struct graph")

    struct_graph = (
        StringToIntTask()
        >> IntMulTask[2]() + IntToFloatTask() + IntMulTask[3]()
        >> SumTuple()
        >> FloatToStringTask()
    )

    print("Starting Graph execution")
    result_2 = struct_graph("32")

    print(result_2)
