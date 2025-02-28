from move.callable import (
    Callable,
    CallablePack,
    CallableDefaultable,
    ImmCallable,
    CallableMovable,
)
from move.runners import series_runner
from move.task_groups.parallel import ImmParallelTaskPair


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


# Series Mutable Pair
struct SeriesTaskPair[
    t1: CallableMovable,
    t2: CallableMovable,
](CallableMovable):
    var v1: t1
    var v2: t2

    @always_inline("nodebug")
    fn __init__(out self, owned v1: t1, owned v2: t2):
        self.v1 = v1^
        self.v2 = v2^

    @always_inline("nodebug")
    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1^
        self.v2 = existing.v2^

    @always_inline("nodebug")
    fn __call__(mut self):
        series_runner(self.v1, self.v2)


# Parallel Mutable Collections: (NOT WORKING)
# struct SeriesTask[origin: Origin[True], *types: Callable](Callable):
#     var tasks: VariadicPack[origin, Callable, *types]

#     fn __init__(
#         out self: SeriesTask[
#             MutableOrigin.cast_from[__origin_of(args._value)].result, *types
#         ],
#         mut*args: *types,
#     ):
#         value = rebind[__type_of(self.tasks)._mlir_type](args._value)
#         self.tasks = VariadicPack(value, is_owned=False)

#     fn __call__(mut self):
#         series_runner(self.tasks)


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        series_runner[*Ts]()
