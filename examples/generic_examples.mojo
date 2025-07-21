from strata.generic import Task, Callable, Fn  # , Tuple
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


# Struct example
@fieldwise_init
struct FloatToString(Callable):
    """Just an example of a struct that conforms to callable."""

    alias I = Float32
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
        print("Float to string...")
        sleep(time)
        return Self.O(value)


@fieldwise_init
struct StringToFloat(Callable):
    """Just an example of a struct that conforms to callable."""

    alias I = String
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        print("Float to string...")
        sleep(time)
        try:
            return Self.O(value)
        except:
            return Self.O()


@fieldwise_init
struct FtoS(Callable):
    alias I = Float32
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
        return Self.O(value)


@fieldwise_init
struct StoF(Callable):
    alias I = String
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        try:
            return Self.O(value)
        except:
            return 0.0


fn main():
    # NOTE: Compile times could be faster if you use struct instead of functions.
    print("Building graph")

    final_graph = (
        Task(Fn(string_to_int))
        >> Task(Fn(int_mul[2])) + Fn(int_to_float) + Fn(int_mul[3])
        >> Fn(sum_tuple)
        >> FloatToString()
    )

    print("Starting Graph execution")
    result = final_graph("32")

    print(result)
