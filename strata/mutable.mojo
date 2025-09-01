from algorithm import sync_parallelize
from builtin import variadic_size


trait _SimpleMutCallable:
    fn __call__(mut self):
        ...


trait MutCallable(_SimpleMutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[_SimpleMutCallable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, __type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    fn __rshift__[
        s: MutableOrigin, o: MutableOrigin, //
    ](
        ref [s]self, ref [o]other: Some[_SimpleMutCallable]
    ) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, __type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, //
    ](
        ref [s]self, var other: Some[Movable & _SimpleMutCallable]
    ) -> ParallelTaskPair[_TaskRef[origin=s, Self], __type_of(other)]:
        return {_TaskRef(self), other^}

    fn __rshift__[
        s: MutableOrigin, //
    ](
        ref [s]self, var other: Some[Movable & _SimpleMutCallable]
    ) -> SequentialTaskPair[_TaskRef[origin=s, Self], __type_of(other)]:
        return {_TaskRef(self), other^}


trait _MovableMutCallable(Movable, MutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[_SimpleMutCallable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, __type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __rshift__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[_SimpleMutCallable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, __type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__(
        var self, var other: Some[Movable & _SimpleMutCallable]
    ) -> ParallelTaskPair[Self, __type_of(other)]:
        return {self^, other^}

    fn __rshift__(
        var self, var other: Some[Movable & _SimpleMutCallable]
    ) -> SequentialTaskPair[Self, __type_of(other)]:
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
