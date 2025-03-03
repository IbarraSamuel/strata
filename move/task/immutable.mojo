from move.callable import (
    ImmCallable,
    CallableDefaultable,
    ImmCallableWithMessage,
)
from move.task_groups.parallel.immutable import (
    ImmParallelTaskPair,
    ParallelDefaultTask,
    ImmParallelMsgTaskPair,
)
from move.task_groups.series.immutable import (
    ImmSeriesTaskPair,
    SeriesDefaultTask,
    ImmSeriesMsgTaskPair,
)
from move.message import Message


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


struct MsgFnTask(ImmCallableWithMessage):
    var func: fn (owned Message) -> Message

    fn __init__(out self, func: fn (owned Message) -> Message):
        self.func = func

    fn __call__(self, owned message: Message) -> Message:
        return self.func(message^)


struct ImmMessageTask[origin: Origin, T: ImmCallableWithMessage](
    ImmCallableWithMessage
):
    """Refers to a task that cannot be mutated."""

    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer.address_of(inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self, owned message: Message) -> Message:
        return self.inner[](message)

    fn __add__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        return ImmParallelMsgTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        return ImmSeriesMsgTaskPair(self, other)


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
