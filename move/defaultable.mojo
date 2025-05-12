from algorithm import sync_parallelize

from move.immutable import Callable


fn parallel_runner[*Ts: Callable & Defaultable]():
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.defaultable import parallel_runner, Callable
    from time import sleep

    struct Task(Callable, Defaultable):
        fn __init__(out self):
            pass
        fn __call__(self):
            print("running")
            sleep(1.0) # Less times didn't work well on doctests
            print("Done")

    alias t1 = Task
    alias t2 = Task

    # Will run t1 and t2 at the same time
    parallel_runner[t1, t2]()

    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                Ts[ti]()()

    sync_parallelize[exec](size)


fn series_runner[*Ts: Callable & Defaultable]():
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.defaultable import series_runner, Callable

    struct Task(Callable, Defaultable):
        fn __init__(out self):
            pass
        fn __call__(self):
            print()

    alias t1 = Task
    alias t2 = Task

    # Will run t1 first, then t2
    series_runner[t1, t2]()

    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        Ts[i]()()


struct DefaultTask[T: Callable & Defaultable](Callable, Defaultable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        T: Type that conforms to `CallableDefaultable`.

    ```mojo
    from move.defaultable import DefaultTask, Callable

    struct DefTask(Callable, Defaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("default task")

    alias Task = DefaultTask[DefTask]
    task = Task()
    task()
    ```
    """

    fn __init__(out self):
        """Defualt initializer."""
        pass

    @implicit
    fn __init__(out self, val: T):
        """Initialize the DefaultTask from a runtime reference to a type.

        Args:
            val: The defaultable task. It's just to take the type.
        """
        pass

    fn __call__(self):
        """Call the task."""
        t = T()
        t()

    fn __add__[
        t: Callable & Defaultable
    ](self, other: t) -> DefaultTask[ParallelDefaultTask[Self.T, t]]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return DefaultTask[ParallelDefaultTask[Self.T, t]]()

    fn __rshift__[
        t: Callable & Defaultable
    ](self, other: t) -> DefaultTask[SeriesDefaultTask[Self.T, t]]:
        """Add this task pair with another task, to be executed in sequence.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed fater this group.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return DefaultTask[SeriesDefaultTask[Self.T, t]]()


struct ParallelDefaultTask[*Ts: Callable & Defaultable](Callable, Defaultable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `CallableDefaultable`.

    ```mojo
    from move.defaultable import ParallelDefaultTask, Callable

    struct DefTask(Callable, Defaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running...")

    struct DefTask2(Callable, Defaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running...")

    # Because could be instanciated in future, you can pass it as a type.

    alias Parallel = ParallelDefaultTask[DefTask, DefTask2]

    # then, you can run it in future.
    par = Parallel()

    # Run it
    par()
    ```
    """

    fn __init__(out self):
        """Default initializer. Just to conform to CallableDefaultable."""
        pass

    fn __call__(self):
        """Call the tasks based on the types in a parallel order."""
        parallel_runner[*Ts]()


struct SeriesDefaultTask[*Ts: Callable & Defaultable](Callable, Defaultable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `CallableDefaultable`.

    ```mojo
    from move.defaultable import SeriesDefaultTask, Callable

    struct DefTask(Callable, Defaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running...")

    struct DefTask2(Callable, Defaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running...")
    # Because could be instanciated in future, you can pass it as a type.

    alias Series = SeriesDefaultTask[DefTask, DefTask2]

    # then, you can run it in future.
    ser = Series()

    # Run it
    ser()
    ```
    """

    fn __init__(out self):
        """Default initializer. Just to conform to CallableDefaultable."""
        pass

    fn __call__(self):
        """Call the tasks based on the types on a sequence order."""
        series_runner[*Ts]()
