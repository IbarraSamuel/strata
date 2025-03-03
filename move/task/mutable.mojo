from move.callable import CallableMovable, Callable
from move.task_groups.series.mutable import SeriesTaskPair
from move.task_groups.parallel.mutable import ParallelTaskPair


struct Task[T: CallableMovable](CallableMovable):
    """A Wrapper to an owned Callable."""

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
