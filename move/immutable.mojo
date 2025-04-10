from move.callable import Callable, CallableMovable, CallablePack
from move.runners import series_runner, parallel_runner


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

    fn __init__(out self, func: fn ()):
        """Takes a `fn() -> None` and wrap it.

        Args:
            func: The function to be wraped.
        """
        self.func = func

    fn __call__(self):
        """Call the inner function."""
        self.func()


struct SerTaskPairRef[T1: Callable, T2: Callable, o1: Origin, o2: Origin](
    CallableMovable
):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1
        self.t2 = other.t2

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
    CallableMovable
):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1
        self.t2 = other.t2

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


struct ImmTaskRef[T: Callable, origin: Origin](CallableMovable):
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
        is_mutable: If we can mutate the elements.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.

    ```mojo
    from move.immutable import ParallelTask

    struct ImmTask:
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

    fn __init__(
        out self: ParallelTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        """Create a Parallel group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in parallel.
        """
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        """This function executes all tasks at the same time."""
        parallel_runner(self.callables)


# # Variadic Series
struct SeriesTask[origin: Origin, *Ts: Callable](Callable):
    """Collection of immutable tasks to run in Series.

    Parameters:
        is_mutable: If the elements could be mutated.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `Callable`.

    ```mojo
    from move.immutable import SeriesTask

    struct ImmTask:
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

    fn __init__(
        out self: SeriesTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        """Create a Series group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in series.
        """
        self.callables = rebind[CallablePack[__origin_of(args._value), *Ts]](
            CallablePack(args._value)
        )

    fn __call__(self):
        """This function executes all tasks in ordered sequence."""
        series_runner(self.callables)
