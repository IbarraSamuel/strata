from move.callable import (
    Callable,
    CallablePack,
    CallableMsgPack,
    CallableDefaultable,
    ImmCallable,
    ImmCallableWithMessage,
    CallableMovable,
)
from move.runners import series_runner, series_msg_runner
from move.task_groups.parallel.immutable import (
    ImmParallelTaskPair,
    ImmParallelMsgTaskPair,
)
from move.message import Message


# Variadic Series
struct ImmSeriesTask[origin: Origin, *Ts: ImmCallable](ImmCallable):
    var callables: CallablePack[origin, *Ts]

    fn __init__(
        out self: ImmSeriesTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        series_runner(self.callables)


# Series Pair
struct ImmSeriesTaskPair[
    o1: Origin, o2: Origin, t1: ImmCallable, t2: ImmCallable
](ImmCallable, Movable):
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

    fn __add__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelTaskPair[s, o, Self, t]:
        return ImmParallelTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesTaskPair[s, o, Self, t]:
        return ImmSeriesTaskPair(self, other)


# Variadic Parallel
struct ImmSeriesMsgTask[origin: Origin, *Ts: ImmCallableWithMessage](
    ImmCallableWithMessage
):
    var callables: CallableMsgPack[origin, *Ts]

    fn __init__(
        out self: ImmSeriesMsgTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallableMsgPack[__origin_of(args._value), *Ts]](
            CallableMsgPack(args._value)
        )

    fn __call__(self, owned msg: Message) -> Message:
        return series_msg_runner(msg, self.callables)


# Series Pair
struct ImmSeriesMsgTaskPair[
    o1: Origin,
    o2: Origin,
    t1: ImmCallableWithMessage,
    t2: ImmCallableWithMessage,
](ImmCallableWithMessage):
    var v1: Pointer[t1, o1]
    var v2: Pointer[t2, o2]

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        self.v1 = Pointer.address_of(v1)
        self.v2 = Pointer.address_of(v2)

    fn __call__(self, owned message: Message) -> Message:
        return series_msg_runner(message, self.v1[], self.v2[])

    fn __add__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        return ImmParallelMsgTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        return ImmSeriesMsgTaskPair(self, other)


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        series_runner[*Ts]()
