from memory.pointer import Pointer
from sys.intrinsics import _type_is_eq
from algorithm import sync_parallelize
import os


trait Callable:
    alias I: Movable & Copyable
    alias O: Movable & Copyable

    fn __call__(self, arg: I) -> O:
        ...


struct Task[T: Callable](Callable, Movable, Copyable):
    alias I = T.I
    alias O = T.O

    var inner: Pointer[T, ImmutableAnyOrigin]

    @implicit
    fn __init__(out self, inner: T):
        self.inner = Pointer[T, ImmutableAnyOrigin](to=inner)

    @implicit
    fn __init__(
        out self: Task[Fn[Self.I, Self.O]], inner: fn (Self.I) -> Self.O
    ):
        self.inner = Pointer[Fn[Self.I, Self.O], ImmutableAnyOrigin](to=inner)

    fn __call__(self, arg: T.I) -> T.O:
        return self.inner[](arg)

    fn __rshift__[t: Callable](self, other: Task[t]) -> SerTask[T, t]:
        return {self.inner[], other}

    fn __add__[t: Callable](self, other: Task[t]) -> ParTask[T, t]:
        return {self.inner[], other}


struct SerTask[T1: Callable, T2: Callable](Callable):
    alias I = T1.I
    alias O = T2.O

    var value_1: Pointer[T1, ImmutableAnyOrigin]
    var value_2: Pointer[T2, ImmutableAnyOrigin]

    fn __init__(out self, owned t1: Task[T1], owned t2: Task[T2]):
        self.value_1 = t1.inner
        self.value_2 = t2.inner

    fn __call__(self, arg: Self.I) -> Self.O:
        # Requires should assert that
        result_1 = self.value_1[](arg)

        @parameter
        if not _type_is_eq[T1.O, T2.I]():
            os.abort("[Type error in chain] Not Valid Types")

        result_2 = self.value_2[](rebind[T2.I](result_1))
        return result_2^

    fn __rshift__[t: Callable](self, other: Task[t]) -> SerTask[Self, t]:
        return {self, other}

    fn __add__[t: Callable](self, other: Task[t]) -> ParTask[Self, t]:
        return {self, other}


struct ParTask[T1: Callable, T2: Callable](Callable):
    alias I = T1.I
    alias O = Tuple[T1.O, T2.O]

    var value_1: Pointer[T1, ImmutableAnyOrigin]
    var value_2: Pointer[T2, ImmutableAnyOrigin]

    fn __init__(out self, owned t1: Task[T1], owned t2: Task[T2]):
        self.value_1 = t1.inner
        self.value_2 = t2.inner

    fn __call__(self, arg: Self.I) -> Self.O:
        @parameter
        if not _type_is_eq[T1.O, T2.I]():
            os.abort("[Type error in chain] Not Valid Types")

        var res_1: T1.O
        var res_2: T2.O

        # This is to tell compiler, hey we will initialize this,
        # Don't worry if it's still not initialized.
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(res_1)
        )
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(res_2)
        )

        @__copy_capture(arg)
        @parameter
        fn run_task(idx: Int):
            if idx == 0:
                res_1 = self.value_1[](arg)
            else:
                res_2 = self.value_2[](rebind[T2.I](arg))

        sync_parallelize[run_task](2)

        return (res_1^, res_2^)

    fn __rshift__[t: Callable](self, other: Task[t]) -> SerTask[Self, t]:
        return {self, other}

    fn __add__[t: Callable](self, other: Task[t]) -> ParTask[Self, t]:
        return {self, other}


struct Fn[In: Copyable & Movable, Out: Copyable & Movable](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    @implicit
    fn __init__(out self, func: fn (In) -> Out):
        self.func = func

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)

    fn __rshift__[t: Callable](self, other: Task[t]) -> SerTask[Self, t]:
        return {self, other}

    fn __add__[t: Callable](self, other: Task[t]) -> ParTask[Self, t]:
        return {self, other}


fn string_to_int(str: String) -> Int:
    try:
        return Int(str)
    except:
        return 0


fn float_to_string(float: Float32) -> String:
    return String(float)


fn int_to_float(value: Int) -> Float32:
    return value


fn int_mul[by: Int](value: Int) -> Int:
    return value * by


fn sum_tuple(value: Tuple[Int, Float32]) -> Float32:
    return value[0] + value[1]


fn main():
    str_to_int = Fn[String, Int](string_to_int)
    int_to_float = Fn[Int, Float32](int_to_float)
    int_mul = Fn[Int, Int](int_mul[2])
    tuple_to_float = Fn[Tuple[Int, Float32], Float32](sum_tuple)
    float_to_str = Fn(float_to_string)

    final_graph = (
        str_to_int >> (int_mul + int_to_float) >> tuple_to_float >> float_to_str
    )

    result = final_graph("32")

    print(result)
