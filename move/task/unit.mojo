from move.callable import (
    CallableMovable,
    ImmCallable,
    CallableDefaultable,
    Callable,
    CallableMovable,
)
from move.task_groups.series import (
    ImmSeriesTaskPair,
    ImmSeriesTask,
    SeriesTaskPair,
    SeriesTask,
    SeriesDefaultTask,
)
from move.task_groups.parallel import (
    ImmParallelTaskPair,
    ImmParallelTask,
    ParallelTaskPair,
    ParallelTask,
    ParallelDefaultTask,
)

from utils.variant import Variant


struct FnTask(ImmCallable):
    var func: fn ()

    fn __init__(out self, func: fn ()):
        self.func = func

    fn __call__(self):
        self.func()


struct ImmTask[origin: Origin, T: ImmCallable](ImmCallable):
    """Refers to a task that cannot be mutated."""

    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        self.inner[]()

    fn __add__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelTaskPair[s, o, Self, t]:
        return ImmParallelTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesTaskPair[s, o, Self, t]:
        return ImmSeriesTaskPair(self, other)


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


struct Task[T: CallableMovable](CallableMovable):
    var inner: T

    @implicit
    @always_inline("nodebug")
    fn __init__(out self, owned v: T):
        self.inner = v^

    @implicit
    @always_inline("nodebug")
    fn __init__[
        o: Origin[True], t: Callable
    ](out self: Task[TaskRef[o, t]], ref [o]v: t):
        self.inner = TaskRef(v)

    @always_inline("nodebug")
    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner^

    @always_inline("nodebug")
    fn __call__(mut self):
        self.inner()

    @always_inline("nodebug")
    fn __add__[
        o: Origin[True], t: Callable, //
    ](owned self, ref [o]other: t) -> Task[
        ParallelTaskPair[Self, TaskRef[o, t]]
    ]:
        return ParallelTaskPair(self^, TaskRef(other))

    @always_inline("nodebug")
    fn __add__[
        t: CallableMovable, //
    ](owned self, owned other: t) -> Task[ParallelTaskPair[Self, t]]:
        return ParallelTaskPair(self^, other^)

    @always_inline("nodebug")
    fn __rshift__[
        o: Origin[True], t: Callable, //
    ](owned self, ref [o]other: t) -> Task[SeriesTaskPair[Self, TaskRef[o, t]]]:
        return SeriesTaskPair(self^, TaskRef(other))

    @always_inline("nodebug")
    fn __rshift__[
        t: CallableMovable, //
    ](owned self, owned other: t) -> Task[SeriesTaskPair[Self, t]]:
        return SeriesTaskPair(self^, other^)


@register_passable("trivial")
struct TaskRef[origin: Origin[True], T: Callable](CallableMovable):
    """A reference to a Mutable Task with `Operation` capabilities.

    There is a known issue. When doing expressions, the Left hand side needs to be
    transferred to the result, because if not, we cannot mutate a expression value.
    We actually can transfer the reference, but not the Wrapping type.
    """

    var inner: Pointer[T, origin]

    @always_inline("nodebug")
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    @always_inline("nodebug")
    fn __call__(mut self):
        self.inner[]()
