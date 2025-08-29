from algorithm import sync_parallelize
from builtin import variadic_size


trait SimpleMutCallable:
    fn __call__(mut self):
        ...


trait MutCallable(SimpleMutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[MutCallable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, __type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    fn __rshift__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[MutCallable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, __type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, //
    ](ref [s]self, var other: Some[MovableMutCallable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], __type_of(other)
    ]:
        return {_TaskRef(self), other^}

    fn __rshift__[
        s: MutableOrigin, //
    ](ref [s]self, var other: Some[MovableMutCallable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], __type_of(other)
    ]:
        return {_TaskRef(self), other^}


trait MovableMutCallable(Movable, MutCallable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[MutCallable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, __type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __rshift__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[MutCallable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, __type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__(
        var self, var other: Some[MovableMutCallable]
    ) -> ParallelTaskPair[Self, __type_of(other)]:
        return {self^, other^}

    fn __rshift__(
        var self, var other: Some[MovableMutCallable]
    ) -> SequentialTaskPair[Self, __type_of(other)]:
        return {self^, other^}


alias MutCallablePack = VariadicPack[False, _, SimpleMutCallable, *_]


# ====================== SAFE VERSION =======================


fn series_runner[
    o: MutableOrigin, //, *ts: SimpleMutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = variadic_size(ts)

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: SimpleMutCallable](mut*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.
    """
    alias size = variadic_size(ts)

    @parameter
    for i in range(size):
        callables[i]()


fn parallel_runner[
    o: MutableOrigin, //, *ts: SimpleMutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = variadic_size(ts)

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: SimpleMutCallable](mut*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.
    """
    alias size = variadic_size(ts)

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


struct SeriesTask[o: MutableOrigin, //, *ts: SimpleMutCallable](
    SimpleMutCallable
):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: SeriesTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        series_runner(self.storage)


struct ParallelTask[o: MutableOrigin, //, *ts: SimpleMutCallable](
    SimpleMutCallable
):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: ParallelTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        parallel_runner(self.storage)


# AIRFLOW SYNTAX
# WHY WE NEED OVERLOAD FOR __rshift__ and __add__?
# Because a value that should be mutated, needs to have a origin,
# and seems like the origin cannot be anonymous. In that case,
# to chain correctly these two concepts, we need to own the object.
# And have a case for var values, another for existing values.


@fieldwise_init
struct SequentialTaskPair[T1: MovableMutCallable, T2: MovableMutCallable](
    MovableMutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        series_runner(self.t1, self.t2)

    # # ---- FOR MUTABLE VERSIONS -----
    # fn __add__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> ParallelTaskPair[
    #     Self, _TaskRef[origin=o, t]
    # ]:
    #     return {self^, _TaskRef(other)}

    # fn __rshift__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> SequentialTaskPair[
    #     Self, _TaskRef[origin=o, t]
    # ]:
    #     return {self^, _TaskRef(other)}

    # # ---- FOR MUTABLE MOVABLE VERSIONS -----
    # fn __add__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> ParallelTaskPair[Self, t]:
    #     return {self^, other^}

    # fn __rshift__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> SequentialTaskPair[Self, t]:
    #     return {self^, other^}


@fieldwise_init
struct ParallelTaskPair[T1: MovableMutCallable, T2: MovableMutCallable](
    MovableMutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        parallel_runner(self.t1, self.t2)

    # # ---- FOR MUTABLE VERSIONS -----
    # fn __add__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> ParallelTaskPair[
    #     Self, TaskRef[origin=o, t]
    # ]:
    #     return {self^, TaskRef(other)}

    # fn __rshift__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> SequentialTaskPair[
    #     Self, TaskRef[origin=o, t]
    # ]:
    #     return {self^, TaskRef(other)}

    # # ---- FOR MUTABLE MOVABLE VERSIONS -----
    # fn __add__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> ParallelTaskPair[Self, t]:
    #     return {self^, other^}

    # fn __rshift__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> SequentialTaskPair[Self, t]:
    #     return {self^, other^}


@register_passable("trivial")
struct _TaskRef[origin: MutableOrigin, //, T: MutCallable](MovableMutCallable):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __call__(self):
        self.inner[]()

    # # ---- FOR MUTABLE VERSIONS -----
    # fn __add__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> ParallelTaskPair[
    #     Self, TaskRef[origin=o, t]
    # ]:
    #     return {self, TaskRef(other)}

    # fn __rshift__[
    #     o: MutableOrigin, t: MutCallable, //
    # ](var self, ref [o]other: t) -> SequentialTaskPair[
    #     Self, TaskRef[origin=o, t]
    # ]:
    #     return {self, TaskRef(other)}

    # # ---- FOR MUTABLE MOVABLE VERSIONS -----
    # fn __add__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> ParallelTaskPair[Self, t]:
    #     return {self, other^}

    # fn __rshift__[
    #     t: MutCallable & Movable
    # ](var self, var other: t) -> SequentialTaskPair[Self, t]:
    #     return {self, other^}
