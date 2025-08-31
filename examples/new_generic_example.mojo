from strata.new_generic import Callable  # , Tuple
import os
from time import sleep

alias time = 0.1


@fieldwise_init
struct StringToIntTask(Callable):
    alias I = String
    alias O = Int

    fn __call__(self, arg: String) -> Int:
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

    fn __call__(self, arg: Int) -> Int:
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
        StringToIntTask()
        >> IntMulTask[2]() + IntToFloatTask() + IntMulTask[3]()
        >> SumTuple()
        >> FloatToStringTask()
    )

    print("Starting Graph execution")
    result = final_graph("32")

    print(result)
