from algorithm import parallelize
from memory.pointer import Pointer


trait Runnable:
    fn run(self):
        ...


# @value
struct SeriesTask[origin: Origin[False], *Ts: Runnable](Runnable):
    alias _mlir_type = __mlir_type[
        `!lit.ref.pack<:variadic<`,
        Runnable,
        `> `,
        Ts,
        `, `,
        origin._mlir_origin,
        `>`,
    ]
    var storage: Self._mlir_type

    fn __init__(out self, *args: *Ts):
        self.storage = rebind[Self._mlir_type](args._value)

    fn __getitem__[i: Int](self) -> ref [origin._mlir_origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)

    fn run(self):
        alias lst = VariadicList(Ts)

        @parameter
        for i in range(len(lst)):
            self[i].run()

    fn __add__[
        t: Runnable,
        o: Origin[False],
    ](self, ref [o]other: t) -> ParallelTask[origin, Self, t]:
        return ParallelTask[origin](self, other)

    fn __rshift__[
        t: Runnable,
        o: Origin[False],
    ](self, ref [o]other: t) -> SeriesTask[origin, Self, t]:
        return SeriesTask[origin](self, other)


# @value
struct ParallelTask[origin: ImmutableOrigin, *Ts: Runnable](Runnable):
    alias _mlir_type = __mlir_type[
        `!lit.ref.pack<:variadic<`,
        Runnable,
        `> `,
        Ts,
        `, `,
        origin._mlir_origin,
        `>`,
    ]
    var storage: Self._mlir_type

    fn __init__(out self, *args: *Ts):
        self.storage = rebind[Self._mlir_type](args._value)

    fn __getitem__[i: Int](self) -> ref [origin._mlir_origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)

    fn run(self):
        @parameter
        fn exec(i: Int):
            @parameter
            for ti in range(len(VariadicList(Ts))):
                if ti == i:
                    self[ti].run()

        parallelize[exec](len(VariadicList(Ts)))

    fn __add__[
        t: Runnable,
        o: Origin[False],
    ](self, ref [o]other: t) -> ParallelTask[origin, Self, t]:
        return ParallelTask[origin](self, other)

    fn __rshift__[
        t: Runnable,
        o: Origin[False],
    ](self, ref [o]other: t) -> SeriesTask[origin, Self, t]:
        return SeriesTask[origin](self, other)


trait RunnableMovable(Runnable, Movable):
    ...


trait RunnableMovableDefaultable(RunnableMovable, Defaultable):
    ...


struct Task[o: Origin[False], T: RunnableMovable](Runnable):
    var inner: Pointer[T, o]

    fn __init__[t: RunnableMovableDefaultable](out self: Task[o, t]):
        self.inner = Pointer[t, o](t()._mlir_type)

    fn __init__(out self, owned inner: T):
        self.inner = inner^

    fn run(self):
        self.inner.run()

    fn __add__[
        t: Runnable,
        origin: Origin[False],
    ](self, ref [origin]other: t) -> ParallelTask[origin, Self, t]:
        return ParallelTask[origin](self, other)

    fn __rshift__[
        t: Runnable,
        origin: Origin[False],
    ](self, ref [origin]other: t) -> SeriesTask[origin, Self, t]:
        return SeriesTask[origin](self, other)
