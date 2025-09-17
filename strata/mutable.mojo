from algorithm import sync_parallelize
from builtin import variadic_size


trait _SimpleMutCallable:
    fn __call__(mut self):
        ...


trait MutCallable(_SimpleMutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, o: MutableOrigin, t: _SimpleMutCallable, //
    ](ref [s]self, ref [o]other: t) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, t]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    fn __rshift__[
        s: MutableOrigin, o: MutableOrigin, t: _SimpleMutCallable, //
    ](ref [s]self, ref [o]other: t) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, t]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, t: Movable & _SimpleMutCallable, //
    ](ref [s]self, var other: t) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], t
    ]:
        return {_TaskRef(self), other^}

    fn __rshift__[
        s: MutableOrigin, t: Movable & _SimpleMutCallable, //
    ](ref [s]self, var other: t) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], t
    ]:
        return {_TaskRef(self), other^}


# NOTE: This could be eliminated by requires clause, to conditionally add default methods based on self signature
# NOTE: Currently Movable & MutCallable is only used internally
trait _MovableMutCallable(Movable, MutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        o: MutableOrigin, t: _SimpleMutCallable, //
    ](var self, ref [o]other: t) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, t]
    ]:
        return {self^, _TaskRef(other)}

    fn __rshift__[
        o: MutableOrigin, t: _SimpleMutCallable, //
    ](var self, ref [o]other: t) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, t]
    ]:
        return {self^, _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: Movable & _SimpleMutCallable, //
    ](var self, var other: t) -> ParallelTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: Movable & _SimpleMutCallable, //
    ](var self, var other: t) -> SequentialTaskPair[Self, t]:
        return {self^, other^}


alias MutCallablePack = VariadicPack[False, _, _SimpleMutCallable, *_]


# ====================== SAFE VERSION =======================


@always_inline
fn series_runner[
    o: MutableOrigin, //, *ts: _SimpleMutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = variadic_size(ts)

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: _SimpleMutCallable](mut*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.
    """
    series_runner(callables)


@always_inline
fn parallel_runner[
    o: MutableOrigin, //, *ts: _SimpleMutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = variadic_size(ts)

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: _SimpleMutCallable](mut*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.
    """
    parallel_runner(callables)


struct SeriesTask[o: MutableOrigin, //, *ts: _SimpleMutCallable](
    _SimpleMutCallable
):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: SeriesTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        series_runner(self.storage)


struct ParallelTask[o: MutableOrigin, //, *ts: _SimpleMutCallable](
    _SimpleMutCallable
):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: ParallelTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        parallel_runner(self.storage)


@fieldwise_init
struct SequentialTaskPair[
    T1: Movable & _SimpleMutCallable, T2: Movable & _SimpleMutCallable
](_MovableMutCallable):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        series_runner(self.t1, self.t2)


@fieldwise_init
struct ParallelTaskPair[
    T1: Movable & _SimpleMutCallable, T2: Movable & _SimpleMutCallable
](_MovableMutCallable):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        parallel_runner(self.t1, self.t2)


@register_passable("trivial")
struct _TaskRef[origin: MutableOrigin, //, T: _SimpleMutCallable](
    _MovableMutCallable
):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __call__(self):
        self.inner[]()
