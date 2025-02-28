from move.callable import (
    CallablePack,
    ImmCallable,
    CallableDefaultable,
    Callable,
    CallableMovable,
)
from move.runners import parallel_runner
from move.task_groups.series import ImmSeriesTaskPair


# Variadic Parallel
struct ImmParallelTask[origin: Origin, *Ts: ImmCallable](ImmCallable):
    var callables: CallablePack[origin, *Ts]

    fn __init__(
        out self: ImmParallelTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        parallel_runner(self.callables)


# Parallel Pair
struct ImmParallelTaskPair[
    o1: Origin, o2: Origin, t1: ImmCallable, t2: ImmCallable
](ImmCallable):
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

    fn __add__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelTaskPair[s, o, Self, t]:
        return ImmParallelTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallable, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesTaskPair[s, o, Self, t]:
        return ImmSeriesTaskPair(self, other)


# Parallel Mutable Pair
struct ParallelTaskPair[t1: CallableMovable, t2: CallableMovable](
    CallableMovable
):
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
        parallel_runner(self.v1, self.v2)


# Parallel Mutable Collections (NOT WORKING)
# struct ParallelTask[origin: Origin[True], *types: Callable](Callable):
#     var tasks: VariadicPack[origin, Callable, *types]

#     fn __init__(
#         out self: ParallelTask[
#             MutableOrigin.cast_from[__origin_of(args._value)].result, *types
#         ],
#         mut*args: *types,
#     ):
#         value = rebind[__type_of(self.tasks)._mlir_type](args._value)
#         self.tasks = VariadicPack(value, is_owned=False)

#     fn __call__(mut self):
#         parallel_runner(self.tasks)


struct ParallelDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        parallel_runner[*Ts]()
