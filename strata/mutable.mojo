from algorithm import sync_parallelize


trait MutCallable:
    fn __call__(mut self):
        ...


alias MutCallablePack = VariadicPack[False, _, MutCallable, *_]


# ====================== SAFE VERSION =======================


fn series_runner[
    o: MutableOrigin, *ts: MutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: MutCallable](mut*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.
    """
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        callables[i]()


fn parallel_runner[
    o: MutableOrigin, *ts: MutCallable
](callables: MutCallablePack[o, *ts]):
    alias size = len(VariadicList(ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: MutCallable](mut*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.
    """
    alias size = len(VariadicList(ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


struct SeriesTask[o: MutableOrigin, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: SeriesTask[args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        series_runner(self.storage)


struct ParallelTask[o: MutableOrigin, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: ParallelTask[args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        parallel_runner(self.storage)


# AIRFLOW SYNTAX
# WHY WE NEED OVERLOAD FOR __rshift__ and __add__?
# Because a value that should be mutated, needs to have a origin,
# and seems like the origin cannot be anonymous. In that case,
# to chain correctly these two concepts, we need to own the object.
# And have a case for owned values, another for existing values.


@fieldwise_init
struct SerTaskPair[T1: MutCallable & Movable, T2: MutCallable & Movable](
    Movable, MutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        series_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__(
        owned self, owned other: TaskRef
    ) -> ParTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    fn __rshift__(
        owned self, owned other: TaskRef
    ) -> SerTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}


@fieldwise_init
struct ParTaskPair[T1: MutCallable & Movable, T2: MutCallable & Movable](
    Movable, MutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        parallel_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__(
        owned self, owned other: TaskRef
    ) -> ParTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    fn __rshift__(
        owned self, owned other: TaskRef
    ) -> SerTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}


struct TaskRef[origin: MutableOrigin, //, T: MutCallable](Movable, MutCallable):
    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __call__(self):
        self.inner[]()

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__(
        owned self, owned other: TaskRef
    ) -> ParTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    fn __rshift__(
        owned self, owned other: TaskRef
    ) -> SerTaskPair[Self, TaskRef[origin = other.origin, other.T]]:
        return {self^, other^}

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: MutCallable & Movable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}
