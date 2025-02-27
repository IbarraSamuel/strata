from move.callable import (
    CallableMovable,
    Callable,
    CallableDefaultable,
    CallableMutable,
    CallableMutableMovable,
)
from move.task_groups.series import (
    SeriesTaskPair,
    SeriesTask,
    SeriesMutableOwnedTaskPair,
    SeriesDefaultTask,
)
from move.task_groups.parallel import (
    ParallelTaskPair,
    ParallelTask,
    ParallelMutableOwnedTaskPair,
    ParallelDefaultTask,
)

from utils.variant import Variant


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


# TODO: Remove operations from here to ownedTask and rename it.
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


struct MutableTask[
    T: CallableMutableMovable,
](CallableMutable, Movable):
    var inner: T

    @implicit
    @always_inline("nodebug")
    fn __init__(out self, owned v: T):
        self.inner = v^

    @implicit
    @always_inline("nodebug")
    fn __init__[
        o: Origin[True], t: CallableMutable
    ](out self: MutableTask[MutableTaskRef[o, t]], ref [o]v: t):
        self.inner = MutableTaskRef(v)

    @always_inline("nodebug")
    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner^

    @always_inline("nodebug")
    fn __call__(mut self):
        self.inner()

    @always_inline("nodebug")
    fn __add__[
        o: Origin[True], t: CallableMutable, //
    ](owned self, ref [o]other: t) -> MutableTask[
        ParallelMutableOwnedTaskPair[Self, MutableTaskRef[o, t]]
    ]:
        return ParallelMutableOwnedTaskPair(self^, MutableTaskRef(other))

    @always_inline("nodebug")
    fn __add__[
        t: CallableMutableMovable, //
    ](owned self, owned other: t) -> MutableTask[
        ParallelMutableOwnedTaskPair[Self, t]
    ]:
        return ParallelMutableOwnedTaskPair(self^, other^)

    @always_inline("nodebug")
    fn __rshift__[
        o: Origin[True], t: CallableMutable, //
    ](owned self, ref [o]other: t) -> MutableTask[
        SeriesMutableOwnedTaskPair[Self, MutableTaskRef[o, t]]
    ]:
        return SeriesMutableOwnedTaskPair(self^, MutableTaskRef(other))

    @always_inline("nodebug")
    fn __rshift__[
        t: CallableMutableMovable, //
    ](owned self, owned other: t) -> MutableTask[
        SeriesMutableOwnedTaskPair[Self, t]
    ]:
        return SeriesMutableOwnedTaskPair(self^, other^)


@register_passable("trivial")
struct MutableTaskRef[origin: Origin[True], T: CallableMutable](
    CallableMutable, Movable
):
    """A reference to a Mutable Task with `Operation` capabilities.

    There is a known issue. When doing expressions, the Left hand side needs to be
    transferred to the result, because if not, we cannot mutate a expression value.
    We actually can transfer the reference, but not the Wrapping type.
    """

    var inner: Pointer[T, origin]

    @always_inline("nodebug")
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    # fn __moveinit__(out self, owned other: Self):
    #     self.inner = other.inner

    @always_inline("nodebug")
    fn __call__(mut self):
        self.inner[]()
