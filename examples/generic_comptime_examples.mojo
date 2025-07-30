from strata.generic_comptime import Fn
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
struct FloatToString:
    """Just an example of a struct that conforms to callable."""

    alias I = Float32
    alias O = String

    @staticmethod
    fn call(value: Self.I) -> Self.O:
        print("Float to string...")
        sleep(time)
        return Self.O(value)


fn main():
    print("Building graph")

    # NOTE 2: We need to instanciate because there is no way to implement
    # __rshift__ and __add__ without a struct instance.

    # Functions need to be wrapped in a Fn struct.
    # Structs could give any @staticmehtod to be wrapped in a Fn struct.
    alias final_graph = (
        Fn[string_to_int]()
        >> Fn[int_mul[2]]() + Fn[int_to_float]() + Fn[int_mul[3]]()
        >> Fn[sum_tuple]()
        >> Fn[FloatToString.call]()
    )

    # Reduce the need of Fn by using a
    alias chain_graph = (
        Fn[string_to_int]()
        .sequential[
            f = Fn[int_mul[2]]()
            .parallel[f=int_to_float]()
            .parallel[f = int_mul[3]]()
            .F
        ]()
        .sequential[f=sum_tuple]()
        .sequential[f = FloatToString.call]()
    )

    print("Starting Graph execution")
    final_result = final_graph.F("32")
    print(final_result)

    # You can use .F on the Fn object
    chain_result = chain_graph.F("32")
    print(chain_result)

    # Or alias F to see the whole graph.
    alias chain_fn = chain_graph.F
    chain_result = chain_fn("32")
    print(chain_result)
