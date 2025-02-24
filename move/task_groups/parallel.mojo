from move.callable import (
    CallablePack,
    Callable,
    CallableMovable,
    CallableDefaultable,
)
from move.runners import parallel_runner


# Variadic Parallel
struct ParallelTask[origin: Origin, *Ts: Callable](Callable):
    var callables: CallablePack[origin, *Ts]

    fn __init__(
        out self: ParallelTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        parallel_runner(self.callables)


# Parallel Pair
struct ParallelTaskPair[o1: Origin, o2: Origin, t1: Callable, t2: Callable](
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
        parallel_runner(self.v1[], self.v2[])


struct ParallelDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        parallel_runner[*Ts]()
