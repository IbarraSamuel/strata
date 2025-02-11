from memory.pointer import Pointer
from memory.owned_pointer import OwnedPointer
from move.task.traits import Callable, CallableDefaultable, CallableMovable
from move.task.callable_pack import CallablePack
from move.task.runners import series_runner, parallel_runner


# Task collections.


# Variadic Series
struct SeriesTask[origin: Origin, *Ts: Callable](Callable):
    alias _value_type = CallablePack[origin, *Ts]._mlir_type
    var callables: CallablePack[origin, *Ts]

    fn __init__(
        out self: SeriesTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        series_runner(self.callables)


# Series Pair
struct SeriesTaskPair[o1: Origin, o2: Origin, t1: Callable, t2: Callable](
    CallableMovable
):
    var v1: Pointer[t1, o1]
    var v2: Pointer[t2, o2]

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        self.v1 = Pointer.address_of(v1)
        self.v2 = Pointer.address_of(v2)

    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1
        self.v2 = existing.v2

    fn __call__(self):
        series_runner(self.v1[], self.v2[])


# Variadic Parallel
struct ParallelTask[origin: Origin, *Ts: Callable](Callable):
    var callables: CallablePack[origin, *Ts]

    fn __init__(
        out self: ParallelTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        parallel_runner(self.callables)


# Parallel Pair
struct ParallelTaskPair[o1: Origin, o2: Origin, t1: Callable, t2: Callable](
    CallableMovable
):
    var v1: Pointer[t1, o1]
    var v2: Pointer[t2, o2]

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        self.v1 = Pointer.address_of(v1)
        self.v2 = Pointer.address_of(v2)

    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1
        self.v2 = existing.v2

    fn __call__(self):
        parallel_runner(self.v1[], self.v2[])


# # Unit Task. To add + and >> functionality to Callables.
struct OwnedTask[T: CallableMovable](CallableMovable):
    """This Struct is only needed to avoid having `__add__` and `__rshift__`
    in series/parallel implementation. Will be needed in Task and OwnedTask only.
    """

    var inner: T

    @implicit
    fn __init__(out self, owned v: T):
        self.inner = v^

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner^

    fn __call__(self):
        self.inner()

    fn __add__[
        o: Origin, t: Callable, //
    ](self, ref [o]other: t) -> OwnedTask[
        ParallelTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return OwnedTask(ParallelTaskPair(self.inner, other))

    fn __rshift__[
        o: Origin, t: Callable, //
    ](self, ref [o]other: t) -> OwnedTask[
        SeriesTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return OwnedTask(SeriesTaskPair(self.inner, other))


struct Task[origin: Origin, T: Callable](CallableMovable):
    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        self.inner[]()

    fn __add__[
        s: Origin, o: Origin, t: Callable, //
    ](ref [s]self, ref [o]other: t) -> OwnedTask[
        ParallelTaskPair[origin, o, T, t]
    ]:
        return OwnedTask(ParallelTaskPair(self.inner[], other))

    fn __rshift__[
        s: Origin, o: Origin, t: Callable, //
    ](ref [s]self, ref [o]other: t) -> OwnedTask[
        SeriesTaskPair[origin, o, T, t]
    ]:
        return OwnedTask(SeriesTaskPair(self.inner[], other))


# ============= Defaults ============
# This only works if the Struct is defaultable.
# Struct instances will be created in a `lazy` way if you use types only.


struct ParallelDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        parallel_runner[*Ts]()


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        series_runner[*Ts]()


struct DefaultTask[T: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    @implicit
    fn __init__(out self, val: T):
        pass

    fn __call__(self):
        T()()

    fn __add__[
        t: CallableDefaultable
    ](self, other: t) -> DefaultTask[ParallelDefaultTask[Self.T, t]]:
        return DefaultTask[ParallelDefaultTask[Self.T, t]]()

    fn __rshift__[
        t: CallableDefaultable
    ](self, other: t) -> DefaultTask[SeriesDefaultTask[Self.T, t]]:
        return DefaultTask[SeriesDefaultTask[Self.T, t]]()
