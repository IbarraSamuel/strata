from algorithm import sync_parallelize


trait TypeCallable:
    @staticmethod
    fn __call__():
        ...


fn parallel_runner[*Ts: TypeCallable]():
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.
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
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        Ts[i].__call__()


@fieldwise_init
@register_passable("trivial")
struct TypeTask[T: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        T: Type that conforms to `CallableDefaultable`.
    """

    @implicit
    @always_inline("nodebug")
    fn __init__(out self, _task: T):
        pass

    @staticmethod
    @always_inline("nodebug")
    fn __call__():
        """Call the task."""
        T.__call__()

    @always_inline("nodebug")
    fn __add__[t: TypeCallable](self, other: t) -> ParallelTypeTask[T, t]:
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

    @always_inline("nodebug")
    fn __rshift__[t: TypeCallable](self, other: t) -> SeriesTypeTask[T, t]:
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
@register_passable("trivial")
struct ParallelTypeTask[*Ts: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.
    """

    @staticmethod
    @always_inline("nodebug")
    fn __call__():
        """Call the tasks based on the types in a parallel order."""
        parallel_runner[*Ts]()

    @always_inline("nodebug")
    fn __add__[t: TypeCallable](self, other: t) -> ParallelTypeTask[Self, t]:
        return {}

    @always_inline("nodebug")
    fn __rshift__[t: TypeCallable](self, other: t) -> SeriesTypeTask[Self, t]:
        return {}


@fieldwise_init
@register_passable("trivial")
struct SeriesTypeTask[*Ts: TypeCallable](TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.
    """

    @staticmethod
    @always_inline("nodebug")
    fn __call__():
        """Call the tasks based on the types on a sequence order."""
        series_runner[*Ts]()

    @always_inline("nodebug")
    fn __add__[t: TypeCallable](self, other: t) -> ParallelTypeTask[Self, t]:
        return {}

    @always_inline("nodebug")
    fn __rshift__[t: TypeCallable](self, other: t) -> SeriesTypeTask[Self, t]:
        return {}
