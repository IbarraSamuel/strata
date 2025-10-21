from runtime.asyncrt import _run, TaskGroup
from sys.intrinsics import _type_is_eq_parse_time


trait Callable:
    alias I: AnyType
    alias O: Copyable & Movable

    fn __call__(self, arg: Self.I) -> Self.O:
        ...

    fn __rshift__[
        t: Callable where _type_is_eq_parse_time[Self.O, t.I](), //,
    ](ref self, ref other: t) -> _SequentialGroup[
        o1 = origin_of(self), o2 = origin_of(other), T1=Self, T2=t
    ]:
        return {self, other}

    fn __add__[
        t: Callable where _type_is_eq_parse_time[Self.I, t.I](), //,
    ](ref self, ref other: t) -> _ParallelGroup[
        o1 = origin_of(self), o2 = origin_of(other), T1=Self, T2=t
    ]:
        return {self, other}


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Copyable & Movable](Callable, Movable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)


struct _SequentialGroup[
    o1: ImmutableOrigin,
    o2: ImmutableOrigin, //,
    T1: Callable,
    T2: Callable where _type_is_eq_parse_time[T1.O, T2.I](),
](Callable, Movable):
    alias I = T1.I
    alias O = T2.O

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    # Init to be a SequentialPair
    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self, arg: Self.I) -> Self.O:
        ref r1 = self.t1[].__call__(arg)
        return self.t2[].__call__(rebind[T2.I](r1))


struct _ParallelGroup[
    o1: ImmutableOrigin,
    o2: ImmutableOrigin, //,
    T1: Callable,
    T2: Callable where _type_is_eq_parse_time[T1.I, T2.I](),
](Callable, Movable):
    alias I = T1.I
    alias O = Tuple[T1.O, T2.O]

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    # # Init to be a SequentialPair
    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self, arg: Self.I) -> Self.O:
        var tg = TaskGroup()

        var v1: T1.O
        var v2: T2.O

        @parameter
        async fn task_1():
            v1 = self.t1[].__call__(arg)

        @parameter
        async fn task_2():
            v2 = self.t2[].__call__(rebind[T2.I](arg))

        # This is safe because the variables will be initialized at the return.
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v1))
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v2))

        tg.create_task(task_1())
        tg.create_task(task_2())

        tg.wait()
        return (v1^, v2^)
