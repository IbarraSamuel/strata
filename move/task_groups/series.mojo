from move.callable import (
    Callable,
    CallablePack,
    CallableDefaultable,
    CallableMutable,
    CallableMutableMovable,
)
from move.runners import series_runner


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
    Callable, Movable
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


# Series Mutable Pair
struct SeriesMutableOwnedTaskPair[
    t1: CallableMutableMovable,
    t2: CallableMutableMovable,
](CallableMutableMovable):
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


# Parallel Mutable Collections
struct SeriesMutableTask[origin: Origin[True], *types: CallableMutable](
    CallableMutable
):
    var tasks: VariadicPack[origin, CallableMutable, *types]

    fn __init__(
        out self: SeriesMutableTask[
            MutableOrigin.cast_from[__origin_of(args._value)].result, *types
        ],
        mut*args: *types,
    ):
        value = rebind[__type_of(self.tasks)._mlir_type](args._value)
        self.tasks = VariadicPack(value, is_owned=False)

    fn __call__(mut self):
        series_runner(self.tasks)


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        series_runner[*Ts]()
