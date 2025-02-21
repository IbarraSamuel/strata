from move.callable import CallableMovable, Callable, CallableDefaultable
from move.task_groups.series import (
    SeriesTaskPair,
    SeriesTask,
    SeriesDefaultTask,
)
from move.task_groups.parallel import (
    ParallelTaskPair,
    ParallelTask,
    ParallelDefaultTask,
)


# Workaround for functions to be converted to a struct
struct Fn(CallableMovable):
    var func: fn ()

    @implicit
    fn __init__(out self, ref func: fn ()):
        self.func = func

    fn __moveinit__(out self, owned other: Self):
        self.func = other.func

    fn __call__(self):
        self.func()


# # Unit Task. To add + and >> functionality to Callables.
struct _OwnedTask[T: CallableMovable](CallableMovable):
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
    ](self, ref [o]other: t) -> _OwnedTask[
        ParallelTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return _OwnedTask(ParallelTaskPair(self.inner, other))

    fn __rshift__[
        o: Origin, t: Callable, //
    ](self, ref [o]other: t) -> _OwnedTask[
        SeriesTaskPair[__origin_of(self.inner), o, T, t]
    ]:
        return _OwnedTask(SeriesTaskPair(self.inner, other))


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
    ](ref [s]self, ref [o]other: t) -> _OwnedTask[
        ParallelTaskPair[origin, o, T, t]
    ]:
        return _OwnedTask(ParallelTaskPair(self.inner[], other))

    fn __rshift__[
        s: Origin, o: Origin, t: Callable, //
    ](ref [s]self, ref [o]other: t) -> _OwnedTask[
        SeriesTaskPair[origin, o, T, t]
    ]:
        return _OwnedTask(SeriesTaskPair(self.inner[], other))


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
