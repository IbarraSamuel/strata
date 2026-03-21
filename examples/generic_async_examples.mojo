from strata.generic.async_def import Fn
import os
from time import sleep

comptime time = 0.1


async def string_to_int(str: String) -> Int:
    print("string to int...")
    sleep(time)
    try:
        return Int(str)
    except:
        return 0


async def int_to_float(value: Int) -> Float32:
    print("int to float...")
    sleep(time)
    return value


async def int_mul[by: Int](value: Int) -> Int:
    print("Mutliply by", by, "...")
    sleep(time)
    return value * by


async def sum_tuple(value: Tuple[Int, Float32]) -> Float32:
    print("Sum tuple...")
    sleep(time)
    return value[0] + value[1]


# Struct example
struct FloatToString:
    """Just an example of a struct that conforms to callable."""

    comptime I = Float32
    comptime O = String

    @staticmethod
    async def call(value: Self.I) -> Self.O:
        print("Float to string...")
        sleep(time)
        return Self.O(value)


def main():
    print("Building graph")

    # NOTE 2: We need to instanciate because there is no way to implement
    # __rshift__ and __add__ without a struct instance.

    # Functions need to be wrapped in a Fn struct.
    # Structs could give any @staticmehtod to be wrapped in a Fn struct.
    comptime final_graph = (
        Fn[string_to_int]()
        >> Fn[int_mul[2]]() + Fn[int_to_float]()
        >> Fn[sum_tuple]()
        >> Fn[FloatToString.call]()
    )

    print("Starting Graph execution")
    final_result = final_graph.run("32")
    print(final_result)

    # Or use the runtime you want
    from runtime.asyncrt import _run

    result_2 = _run(final_graph.F("32"))
    print(result_2)
