from algorithm import sync_parallelize


trait TypeCallable:
    @staticmethod
    fn __call__():
        ...


fn parallel_runner[*Ts: TypeCallable]():
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.type import parallel_runner, TypeCallable
    from time import sleep

    struct Task(TypeCallable):
        @staticmethod
        fn __call__():
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
                Ts[ti].__call__()

    sync_parallelize[exec](size)


fn series_runner[*Ts: TypeCallable]():
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.type import series_runner, TypeCallable

    struct Task(TypeCallable):
        @staticmethod
        fn __call__():
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
        Ts[i].__call__()


@fieldwise_init
struct TypeTask[T: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        T: Type that conforms to `CallableDefaultable`.

    ```mojo
    from move.type import TypeTask, TypeCallable

    struct DefTask(TypeCallable):
        fn __init__(out self):
            pass

        @staticmethod
        fn __call__():
            print("default task")

    alias Task = TypeTask[DefTask]
    Task.__call__()
    ```
    """

    @implicit
    fn __init__(out self, _task: T):
        pass

    @staticmethod
    fn __call__():
        """Call the task."""
        T.__call__()

    fn __add__[
        t: TypeCallable
    ](owned self, owned other: t) -> ParallelTypeTask[T, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `TypeCallable`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return {}

    fn __rshift__[
        t: TypeCallable
    ](owned self, owned other: t) -> SeriesTypeTask[T, t]:
        """Add this task pair with another task, to be executed in sequence.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `TypeCallable`.

        Args:
            other: The task to be executed fater this group.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return {}


@fieldwise_init
struct ParallelTypeTask[*Ts: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.

    ```mojo
    from move.type import ParallelTypeTask, TypeCallable

    struct DefTask(TypeCallable):
        @staticmethod
        fn __call__():
            print("Running...")

    struct DefTask2(TypeCallable):
        @staticmethod
        fn __call__():
            print("Running...")

    # Because could be instanciated in future, you can pass it as a type.

    alias Parallel = ParallelTypeTask[DefTask, DefTask2]

    Parallel.__call__()

    ```
    """

    @staticmethod
    fn __call__():
        """Call the tasks based on the types in a parallel order."""
        parallel_runner[*Ts]()

    fn __add__[
        t: TypeCallable
    ](owned self, owned other: t) -> ParallelTypeTask[Self, t]:
        return {}

    fn __rshift__[
        t: TypeCallable
    ](owned self, owned other: t) -> SeriesTypeTask[Self, t]:
        return {}


@fieldwise_init
struct SeriesTypeTask[*Ts: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.

    ```mojo
    from move.type import SeriesTypeTask, TypeCallable

    struct DefTask(TypeCallable):
        @staticmethod
        fn __call__():
            print("Running...")

    struct DefTask2(TypeCallable):
        @staticmethod
        fn __call__():
            print("Running...")
    # Because could be instanciated in future, you can pass it as a type.

    alias Series = SeriesTypeTask[DefTask, DefTask2]

    # then, you can run it in future.
    Series.__call__()

    ```
    """

    @staticmethod
    fn __call__():
        """Call the tasks based on the types on a sequence order."""
        series_runner[*Ts]()

    fn __add__[
        t: TypeCallable
    ](owned self, owned other: t) -> ParallelTypeTask[Self, t]:
        return {}

    fn __rshift__[
        t: TypeCallable
    ](owned self, owned other: t) -> SeriesTypeTask[Self, t]:
        return {}
