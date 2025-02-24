from move.callable import (
    Callable,
    CallablePack,
    CallableMovable,
    CallableDefaultable,
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
    CallableMovable
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


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        series_runner[*Ts]()
