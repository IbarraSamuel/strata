from algorithm import sync_parallelize
from builtin import variadic_size


trait TypeCallable:
    @staticmethod
    fn __call__():
        ...

    @always_inline("nodebug")
    fn __rshift__(
        deinit self, other: Some[TypeCallable]
    ) -> SeriesTypeTask[Self, __type_of(other)]:
        return {}

    @always_inline("nodebug")
    fn __add__(
        deinit self, other: Some[TypeCallable]
    ) -> ParallelTypeTask[Self, __type_of(other)]:
        return {}


fn parallel_runner[*Ts: TypeCallable]():
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.
    """
    alias size = variadic_size(Ts)

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
    alias size = variadic_size(Ts)

    @parameter
    for i in range(size):
        Ts[i].__call__()


# @fieldwise_init
# @register_passable("trivial")
# struct TypeTask[T: TypeCallable](TypeCallable):
#     """Refers to a task that can be instanciated in the future, because it's defaultable.

#     Parameters:
#         T: Type that conforms to `CallableDefaultable`.
#     """

#     @implicit
#     @always_inline("nodebug")
#     fn __init__(out self, _task: T):
#         pass

#     @staticmethod
#     @always_inline("nodebug")
#     fn __call__():
#         """Call the task."""
#         T.__call__()


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
