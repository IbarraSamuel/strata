from move.generic_pack import GenericPack
from algorithm import sync_parallelize

alias CallablePack = GenericPack[is_owned=False, tr=Callable]


trait Callable:
    """The struct should contain a fn __call__ method.

    ```mojo
    trait Callable:
        fn __call__(mut self):
            ...

    struct MyStruct(Callable):
        fn __init__(out self):
            pass

        fn __call__(mut self):
            print("calling...")

    inst = MyStruct()

    # Calling the instance.
    inst()
    ```
    """

    fn __call__(self):
        """Run a task with the possibility to mutate internal state."""
        ...


fn series_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.immutable import series_runner, Callable, CallablePack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](Callable):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    fn series_variadic_inp[*ts: Callable](*args: *ts):
        series_runner(args)
    # Will run t1 first, then t2
    series_variadic_inp(t1, t2)

    assert_true(t1_finish < t2_starts)
    ```
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

    ```mojo
    from move.immutable import series_runner, Callable
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](Callable):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 first, then t2
    series_runner(t1, t2)

    assert_true(t1_finish < t2_starts)
    ```
    """
    series_runner(callables)


# Execute tasks in parallel


fn parallel_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.immutable import parallel_runner, Callable, CallablePack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](Callable):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    fn parallel_variadic_inp[*ts: Callable](*args: *ts):
        parallel_runner(args)
    # Will run t1 and t2 at the same time
    parallel_variadic_inp(t1, t2)

    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```
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

    ```mojo
    from move.immutable import parallel_runner, Callable
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](Callable):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    parallel_runner(t1, t2)

    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```
    """
    parallel_runner(callables)


@fieldwise_init
struct FnTask(Callable):
    """This function takes any function with a signature: `fn() -> None`
     and hold it to later call it using `__call__()`.

     ```mojo
    from move.immutable import FnTask

    fn my_task():
         print("Running a task!")

    task = FnTask(my_task)
    task()
     ```
    """

    var func: fn ()
    """Pointer to the function to call."""

    fn __call__(self):
        """Call the inner function."""
        self.func()


struct SerTaskPairRef[T1: Callable, T2: Callable, o1: Origin, o2: Origin](
    Callable
):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        series_runner(self.t1[], self.t2[])

    fn __add__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> ParTaskPairRef[Self, t, __origin_of(self), o]:
        return ParTaskPairRef(self, other)

    fn __rshift__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> SerTaskPairRef[Self, t, __origin_of(self), o]:
        return SerTaskPairRef(self, other)


struct ParTaskPairRef[T1: Callable, T2: Callable, o1: Origin, o2: Origin](
    Callable
):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        parallel_runner(self.t1[], self.t2[])

    fn __add__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> ParTaskPairRef[Self, t, __origin_of(self), o]:
        return ParTaskPairRef(self, other)

    fn __rshift__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> SerTaskPairRef[Self, t, __origin_of(self), o]:
        return SerTaskPairRef(self, other)


struct ImmTaskRef[T: Callable, origin: Origin](Callable, Movable):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]value: T):
        self.inner = Pointer(to=value)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        self.inner[]()

    fn __add__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> ParTaskPairRef[T, t, origin, o]:
        return ParTaskPairRef(self.inner[], other)

    fn __rshift__[
        t: Callable, o: Origin
    ](self, ref [o]other: t) -> SerTaskPairRef[T, t, origin, o]:
        return SerTaskPairRef(self.inner[], other)


# Variadic Parallel
struct ParallelTask[origin: Origin, *Ts: Callable](Callable):
    """Collection of immutable tasks to run in Parallel.

    Parameters:
        mut: If we can mutate the elements.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.

    ```mojo
    from move.immutable import ParallelTask, Callable

    struct ImmTask(Callable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Working...")

    t1 = ImmTask()
    t2 = ImmTask()
    t3 = ImmTask()

    parallel = ParallelTask(t1, t2, t3)
    # Running tasks in parallel.
    parallel()
    ```
    """

    var callables: CallablePack[origin, *Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(out self: ParallelTask[args.origin, *Ts], *args: *Ts):
        """Create a Parallel group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in parallel.
        """
        self.callables = args

    fn __call__(self):
        """This function executes all tasks at the same time."""
        parallel_runner(self.callables)


# # Variadic Series
struct SeriesTask[origin: Origin, *Ts: Callable](Callable):
    """Collection of immutable tasks to run in Series.

    Parameters:
        mut: If the elements could be mutated.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `Callable`.

    ```mojo
    from move.immutable import SeriesTask, Callable

    struct ImmTask(Callable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Working...")

    t1 = ImmTask()
    t2 = ImmTask()
    t3 = ImmTask()

    series = SeriesTask(t1, t2, t3)
    # Running tasks in series.
    series()
    ```
    """

    var callables: CallablePack[origin, *Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(out self: SeriesTask[args.origin, *Ts], *args: *Ts):
        """Create a Series group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in series.
        """
        self.callables = args

    fn __call__(self):
        """This function executes all tasks in ordered sequence."""
        series_runner(self.callables)
