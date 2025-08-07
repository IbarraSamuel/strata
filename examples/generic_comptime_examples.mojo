from strata.generic_comptime import Fn
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
    @staticmethod
    fn call(value: Float32) -> String:
        print("Float to string...")
        sleep(time)
        return String(value)


async fn async_itof(v: Int) -> Float32:
    return v


async fn async_ftoi(v: Float32) -> Int:
    return Int(v)


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

    # # For async functions
    # from runtime.asyncrt import create_task
    # from strata.generic_comptime import AsyncFn

    # alias async_graph = AsyncFn[async_itof]().parallel[f=async_itof]().parallel[
    #     f=async_itof
    # ]().F

    # coro = async_graph(32)
    # task = create_task(coro^)
    # result = task.wait()
    # print(result[0][1], result[0][0], result[1])
