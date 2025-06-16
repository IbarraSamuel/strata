from strata.generic import Task, Callable, Tuple
import os
from time import sleep

alias time = 0.1
# NOTE: Inference is not working well on functions. to be reviewed
# fn string_to_int(str: String) -> Int:
#     try:
#         return Int(str)
#     except:
#         return 0


# fn float_to_string(float: Float32) -> String:
#     return String(float)


# fn int_to_float(value: Int) -> Float32:
#     return value


# fn int_mul[by: Int](value: Int) -> Int:
#     return value * by


# fn sum_tuple(value: Tuple[Int, Float32]) -> Float32:
#     return value[0] + value[1]


@fieldwise_init
struct StringToInt(Callable):
    alias I = String
    alias O = Int

    fn __call__(self, value: Self.I) -> Self.O:
        print("String to int...")
        sleep(time)
        try:
            return Int(value)
        except:
            return 0


@fieldwise_init
struct IntToString(Callable):
    alias I = Int
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
        print("Int to string...")
        sleep(time)
        return Self.O(value)


@fieldwise_init
struct IntToFloat(Callable):
    alias I = Int
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        print("Int to float...")
        sleep(time)
        return Self.O(value)


@fieldwise_init
struct IntMul[by: Int](Callable):
    alias I = Int
    alias O = Int

    fn __call__(self, value: Self.I) -> Self.O:
        print("Int multiply...")
        sleep(time)
        return value * by


# NOTE: Since we cannot flatten tuples still, we need to do things like ((a, b), c)
@fieldwise_init
struct SumTuple(Callable):
    alias I = ((Int, Float32), Int)
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        print("Sum Tuple...")
        sleep(time)
        return value[0][0] + value[0][1] + value[1]


@fieldwise_init
struct FloatToString(Callable):
    alias I = Float32
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
        print("Float to String...")
        sleep(time)
        return Self.O(value)


fn main():
    str_to_int = StringToInt()
    int_to_float = IntToFloat()
    int_mul = IntMul[2]()
    tuple_to_float = SumTuple()
    float_to_str = FloatToString()

    print("Building graph")
    final_graph = (
        Task(str_to_int)
        >> (Task(IntMul[2]()) + IntToFloat() + IntMul[3]())
        >> tuple_to_float
        >> float_to_str
    )

    print("Starting Graph execution")
    result = final_graph("32")

    # Adding this increases compilation time by a lot x27 more
    # if result != "192.0":
    #     os.abort("Not valid grapth")

    print(result)
