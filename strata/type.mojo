from algorithm import sync_parallelize
from builtin import variadic_size


trait TypeCallable:
    @staticmethod
    fn __call__():
        ...

    @always_inline("nodebug")
    fn __rshift__[
        t: TypeCallable, //
    ](var self, other: t) -> SeriesTypeTask[Self, t]:
        return {}

    @always_inline("nodebug")
    fn __add__[
        t: TypeCallable, //
    ](var self, other: t) -> ParallelTypeTask[Self, t]:
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
        alias size = variadic_size(Ts)

        @parameter
        fn exec(i: Int):
            @parameter
            for ti in range(size):
                if ti == i:
                    Ts[ti].__call__()
                    return

        sync_parallelize[exec](size)


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
        alias size = variadic_size(Ts)

        @parameter
        for i in range(size):
            Ts[i].__call__()
