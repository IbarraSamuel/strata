from algorithm import parallelize
from memory.pointer import Pointer


trait Runnable:
    fn run(self):
        ...


struct RunnablePack[origin: Origin[_], *Ts: Runnable](Copyable):
    """Stores a variadic pack of `Runnable` structs."""

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

    fn __copyinit__(out self, other: Self):
        self.storage = other.storage

    fn __init__(out self, pack: VariadicPack[origin, Runnable, *Ts]):
        self.storage = pack._value

    fn __getitem__[i: Int](self) -> ref [origin._mlir_origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)


# Execute tasks in series
fn series_runner[*Ts: RD]():
    alias lst = VariadicList(Ts)

    @parameter
    for i in range(len(lst)):
        Ts[i]().run()


fn series_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    alias lst = VariadicList(Ts)

    @parameter
    for i in range(len(lst)):
        runnables[i].run()


# Execute tasks in parallel
fn parallel_runner[*Ts: RD]():
    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(len(VariadicList(Ts))):
            if ti == i:
                Ts[ti]().run()

    parallelize[exec](len(VariadicList(Ts)))


fn parallel_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(len(VariadicList(Ts))):
            if ti == i:
                runnables[ti].run()

    parallelize[exec](len(VariadicList(Ts)))


# Task collections.
struct SeriesTask[origin: Origin[_], *Ts: Runnable](Runnable):
    var runnables: RunnablePack[origin, *Ts]

    fn __init__(out self, *args: *Ts):
        self.runnables = rebind[RunnablePack[origin, *Ts]](RunnablePack(args))

    fn run(self):
        series_runner(self.runnables)

    fn __add__[
        t: Runnable,
        o: Origin[_],
    ](self, ref [o]other: t) -> ParallelTask[origin, Self, t]:
        return ParallelTask[origin](self, other)

    fn __rshift__[
        t: Runnable,
        o: Origin[_],
    ](self, ref [o]other: t) -> SeriesTask[origin, Self, t]:
        return SeriesTask[origin](self, other)


# Task Collections.
struct ParallelTask[origin: Origin[_], *Ts: Runnable](Runnable):
    var runnables: RunnablePack[origin, *Ts]

    fn __init__(out self, *args: *Ts):
        self.runnables = rebind[RunnablePack[origin, *Ts]](RunnablePack(args))

    fn run(self):
        parallel_runner(self.runnables)

    fn __add__[
        t: Runnable,
        o: Origin[_],
    ](self, ref [o]other: t) -> ParallelTask[origin, Self, t]:
        return ParallelTask[origin](self, other)

    fn __rshift__[
        t: Runnable,
        o: Origin[_],
    ](self, ref [o]other: t) -> SeriesTask[origin, Self, t]:
        return SeriesTask[origin](self, other)


# Unit Task. To add + and >> functionality to Runnables.
struct Task[o: Origin[False], T: Runnable](Runnable):
    var inner: Pointer[T, o]

    @implicit
    fn __init__[
        t: Runnable, orig: Origin[False]
    ](out self: Task[__origin_of(inner), __type_of(inner)], ref [orig]inner: t):
        self.inner = Pointer.address_of(inner)

    fn run(self):
        self.inner[].run()

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


# ============= Defaults ============


trait RunnableDefaultable(Runnable, Defaultable):
    ...


alias RD = RunnableDefaultable


struct ParallelDefaultTask[*Ts: RD](RD):
    fn __init__(out self):
        pass

    fn run(self):
        parallel_runner[*Ts]()


struct SeriesDefaultTask[*Ts: RD](RD):
    fn __init__(out self):
        pass

    fn run(self):
        series_runner[*Ts]()


struct DefaultTask[T: RD](RD):
    fn __init__(out self):
        pass

    @implicit
    fn __init__[t: RD, //](out self: DefaultTask[t], val: t):
        pass

    fn run(self):
        T().run()

    fn __add__[
        o: RunnableDefaultable
    ](self, other: o) -> DefaultTask[ParallelDefaultTask[Self, o]]:
        return DefaultTask[ParallelDefaultTask[Self, o]]()

    fn __rshift__[
        o: RunnableDefaultable
    ](self, other: o) -> DefaultTask[SeriesDefaultTask[Self, o]]:
        return DefaultTask[SeriesDefaultTask[Self, o]]()
