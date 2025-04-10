from move.callable import CallableMovable, MutableCallable, Callable
from move.immutable import ImmTaskRef, SerTaskPairRef, ParTaskPairRef
from move.runners import series_runner, parallel_runner
from memory.unsafe_pointer import UnsafePointer


# TODO: Allow creating tasks automatically without this thing
struct UnsafeTask[T: MutableCallable, origin: ImmutableOrigin](CallableMovable):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        # Fake it as mutable.
        # SAFETY: This only allows to modify the inner value.
        # No access to other tasks.
        # WARNING: There is no guarrantee on what is made inside the task.
        # Higher level tasks, are all immutable, so there is no problem.
        alias MutPtr = Pointer[T, MutableOrigin.cast_from[origin].result]
        rebind[MutPtr](self.inner)[]()

    fn __add__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPairRef[Self, t, s, o]:
        return ParTaskPairRef(self, other)

    fn __rshift__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPairRef[Self, t, s, o]:
        return SerTaskPairRef(self, other)


trait MutableMovableCallable(MutableCallable, Movable):
    ...


struct SerTaskPair[T1: CallableMovable, T2: CallableMovable](CallableMovable):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(self):
        series_runner(self.t1, self.t2)

    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, s: Origin, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))


struct ParTaskPair[T1: CallableMovable, T2: CallableMovable](CallableMovable):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(self):
        parallel_runner(self.t1, self.t2)

    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))


struct TaskRef[T: MutableCallable, origin: MutableOrigin](
    Movable, Copyable, Callable
):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __copyinit__(out self, other: Self):
        self.inner = other.inner

    fn __call__(self):
        self.inner[]()


struct Task[T: CallableMovable](CallableMovable):
    var inner: T

    fn __init__[
        origin: MutableOrigin, t: MutableCallable
    ](out self: Task[TaskRef[t, origin]], ref [origin]inner: t):
        self.inner = TaskRef(inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner^

    fn __call__(self):
        self.inner()

    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))
