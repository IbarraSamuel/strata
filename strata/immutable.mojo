from algorithm import sync_parallelize

alias CallablePack = VariadicPack[False, _, Callable, *_]


trait Callable:
    """The struct should contain a fn __call__ method."""

    fn __call__(self):
        """Run a task with the possibility to mutate internal state."""
        ...


fn series_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: Callable](*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A collection of `ImmCallable` types.
    """
    series_runner(callables)


# Execute tasks in parallel


fn parallel_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.
    """
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: Callable](*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A collection of `ImmCallable` types.
    """
    parallel_runner(callables)


@fieldwise_init("implicit")
struct FnTask(Callable):
    """This function takes any function with a signature: `fn() -> None` and hold it to later call it using `__call__()`.
    """

    var func: fn ()
    """Pointer to the function to call."""

    fn __call__(self):
        """Call the inner function."""
        self.func()


struct SerTaskPairRef[
    m1: Bool,
    m2: Bool,
    o1: Origin[m1],
    o2: Origin[m2], //,
    T1: Callable,
    T2: Callable,
](Callable):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        series_runner(self.t1[], self.t2[])

    fn __add__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPairRef[
        m1 = s.mut, m2 = o.mut, o1=s, o2=o, Self, t
    ]:
        return {self, other}

    fn __rshift__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPairRef[
        m1 = s.mut, m2 = o.mut, o1=s, o2=o, Self, t
    ]:
        return {self, other}


struct ParTaskPairRef[
    m1: Bool,
    m2: Bool,
    o1: Origin[m1],
    o2: Origin[m2], //,
    T1: Callable,
    T2: Callable,
](Callable):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        parallel_runner(self.t1[], self.t2[])

    fn __add__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPairRef[
        m1 = s.mut, m2 = o.mut, o1=s, o2=o, Self, t
    ]:
        return {self, other}

    fn __rshift__[
        t: Callable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPairRef[
        m1 = s.mut, m2 = o.mut, o1=s, o2=o, Self, t
    ]:
        return {self, other}


struct ImmTaskRef[origin: Origin, //, T: Callable](Callable):
    var inner: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]value: T):
        self.inner = Pointer(to=value)

    fn __call__(self):
        self.inner[]()

    fn __add__[
        t: Callable, o: Origin, //
    ](self, ref [o]other: t) -> ParTaskPairRef[
        m1 = origin.mut, m2 = o.mut, o1=origin, o2=o, T, t
    ]:
        return {self.inner[], other}

    fn __rshift__[
        t: Callable, o: Origin, //
    ](self, ref [o]other: t) -> SerTaskPairRef[
        m1 = origin.mut, m2 = o.mut, o1=origin, o2=o, T, t
    ]:
        return {self.inner[], other}


# Variadic Parallel
struct ParallelTask[mut: Bool, origin: Origin[mut], //, *Ts: Callable](
    Callable
):
    """Collection of immutable tasks to run in Parallel.

    Parameters:
        mut: If we can mutate the elements.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.
    """

    var callables: CallablePack[origin, *Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(
        out self: ParallelTask[
            mut = args.origin.mut, origin = args.origin, *Ts
        ],
        *args: *Ts,
    ):
        """Create a Parallel group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in parallel.
        """
        self.callables = CallablePack(args._value)

    fn __call__(self):
        """This function executes all tasks at the same time."""
        parallel_runner(self.callables)


# # Variadic Series
struct SeriesTask[mut: Bool, origin: Origin[mut], //, *Ts: Callable](Callable):
    """Collection of immutable tasks to run in Series.

    Parameters:
        mut: If the elements could be mutated.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `Callable`.
    """

    var callables: CallablePack[origin, *Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(
        out self: SeriesTask[mut = args.origin.mut, origin = args.origin, *Ts],
        *args: *Ts,
    ):
        """Create a Series group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in series.
        """
        self.callables = CallablePack(args._value)

    fn __call__(self):
        """This function executes all tasks in ordered sequence."""
        series_runner(self.callables)
