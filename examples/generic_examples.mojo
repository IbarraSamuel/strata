from strata.generic import Task, Callable, Tuple
import os


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
        try:
            return Int(value)
        except:
            return 0


@fieldwise_init
struct IntToString(Callable):
    alias I = Int
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
        return Self.O(value)


@fieldwise_init
struct IntToFloat(Callable):
    alias I = Int
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        return Self.O(value)


@fieldwise_init
struct IntMul[by: Int](Callable):
    alias I = Int
    alias O = Int

    fn __call__(self, value: Self.I) -> Self.O:
        return value * by


@fieldwise_init
struct SumTuple(Callable):
    alias I = Tuple[Int, Float32]
    alias O = Float32

    fn __call__(self, value: Self.I) -> Self.O:
        return value[0] + value[1]


@fieldwise_init
struct FloatToString(Callable):
    alias I = Float32
    alias O = String

    fn __call__(self, value: Self.I) -> Self.O:
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
        >> (Task(int_mul) + int_to_float)
        >> tuple_to_float
        >> float_to_str
    )

    print("Starting Graph execution")
    result = final_graph("32")

    # Adding this increases compilation time by a lot x27 more
    # if result != "96.0":
    #     os.abort("Not valid grapth")

    print(result)
