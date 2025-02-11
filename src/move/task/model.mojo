from memory.pointer import Pointer
from memory.owned_pointer import OwnedPointer
from move.task.traits import Runnable, RunnableDefaultable, RunnableMovable
from move.task.runnable_pack import RunnablePack
from move.task.runners import series_runner, parallel_runner


# Task collections.


# Variadic Series
struct SeriesTask[origin: Origin, *Ts: Runnable](Runnable):
    alias _value_type = RunnablePack[origin, *Ts]._mlir_type
    var runnables: RunnablePack[origin, *Ts]

    fn __init__(
        out self: SeriesTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.runnables = rebind[RunnablePack[__origin_of(args._value), *Ts]](
            RunnablePack(args._value)
        )

    fn run(self):
        series_runner(self.runnables)


# Series Pair
struct SeriesTaskPair[o1: Origin, o2: Origin, t1: Runnable, t2: Runnable](
    RunnableMovable
):
    var v1: Pointer[t1, o1]
    var v2: Pointer[t2, o2]

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        self.v1 = Pointer.address_of(v1)
        self.v2 = Pointer.address_of(v2)

    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1
        self.v2 = existing.v2

    fn run(self):
        series_runner(self.v1[], self.v2[])


# Variadic Parallel
struct ParallelTask[origin: Origin, *Ts: Runnable](Runnable):
    var runnables: RunnablePack[origin, *Ts]

    fn __init__(
        out self: ParallelTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.runnables = rebind[RunnablePack[__origin_of(args._value), *Ts]](
            RunnablePack(args._value)
        )

    fn run(self):
        parallel_runner(self.runnables)


# Parallel Pair
struct ParallelTaskPair[o1: Origin, o2: Origin, t1: Runnable, t2: Runnable](
    RunnableMovable
):
    var v1: Pointer[t1, o1]
    var v2: Pointer[t2, o2]

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        self.v1 = Pointer.address_of(v1)
        self.v2 = Pointer.address_of(v2)

    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1
        self.v2 = existing.v2

    fn run(self):
        parallel_runner(self.v1[], self.v2[])


# # Unit Task. To add + and >> functionality to Runnables.
struct OwnedTask[T: RunnableMovable](RunnableMovable):
    """This Struct is only needed to avoid having `__add__` and `__rshift__`
    in series/parallel implementation. Will be needed in Task and OwnedTask only.
    """

    var inner: T

    @implicit
    fn __init__(out self, owned v: T):
        self.inner = v^

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner^

    fn run(self):
        self.inner.run()

    fn __add__[
        o: Origin, t: Runnable, //
    ](self, ref [o]other: t) -> OwnedTask[
        ParallelTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return OwnedTask(ParallelTaskPair(self.inner, other))

    fn __rshift__[
        o: Origin, t: Runnable, //
    ](self, ref [o]other: t) -> OwnedTask[
        SeriesTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return OwnedTask(SeriesTaskPair(self.inner, other))


struct Task[origin: Origin, T: Runnable](RunnableMovable):
    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn run(self):
        self.inner[].run()

    fn __add__[
        s: Origin, o: Origin, t: Runnable, //
    ](ref [s]self, ref [o]other: t) -> OwnedTask[
        ParallelTaskPair[origin, o, T, t]
    ]:
        return OwnedTask(ParallelTaskPair(self.inner[], other))

    fn __rshift__[
        s: Origin, o: Origin, t: Runnable, //
    ](ref [s]self, ref [o]other: t) -> OwnedTask[
        SeriesTaskPair[origin, o, T, t]
    ]:
        return OwnedTask(SeriesTaskPair(self.inner[], other))


# ============= Defaults ============
# This only works if the Struct is defaultable.
# Struct instances will be created in a `lazy` way if you use types only.


struct ParallelDefaultTask[*Ts: RunnableDefaultable](RunnableDefaultable):
    fn __init__(out self):
        pass

    fn run(self):
        parallel_runner[*Ts]()


struct SeriesDefaultTask[*Ts: RunnableDefaultable](RunnableDefaultable):
    fn __init__(out self):
        pass

    fn run(self):
        series_runner[*Ts]()


struct DefaultTask[T: RunnableDefaultable](RunnableDefaultable):
    fn __init__(out self):
        pass

    @implicit
    fn __init__(out self, val: T):
        pass

    fn run(self):
        T().run()

    fn __add__[
        t: RunnableDefaultable
    ](self, other: t) -> DefaultTask[ParallelDefaultTask[Self.T, t]]:
        return DefaultTask[ParallelDefaultTask[Self.T, t]]()

    fn __rshift__[
        t: RunnableDefaultable
    ](self, other: t) -> DefaultTask[SeriesDefaultTask[Self.T, t]]:
        return DefaultTask[SeriesDefaultTask[Self.T, t]]()
