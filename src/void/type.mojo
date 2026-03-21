from std.algorithm import sync_parallelize
from std.builtin import Variadic


trait TypeCallable:
    @staticmethod
    def __call__():
        ...

    @always_inline("nodebug")
    def __rshift__[
        t: TypeCallable, //
    ](var self, other: t) -> SeriesTypeTask[Self, t]:
        self^.forget()
        return {}

    @always_inline("nodebug")
    def __add__[
        t: TypeCallable, //
    ](var self, other: t) -> ParallelTypeTask[Self, t]:
        self^.forget()
        return {}

    @always_inline("nodebug")
    def forget(deinit self):
        pass


@fieldwise_init
struct ParallelTypeTask[*Ts: TypeCallable](
    TrivialRegisterPassable, TypeCallable
):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.
    """

    @staticmethod
    @always_inline("nodebug")
    def __call__():
        """Call the tasks based on the types in a parallel order."""
        comptime size = Variadic.size(Self.Ts)

        @parameter
        def exec(i: Int):
            comptime for ti in range(size):
                if ti == i:
                    Self.Ts[ti].__call__()
                    return

        sync_parallelize[exec](size)


@fieldwise_init
struct SeriesTypeTask[*Ts: TypeCallable](TrivialRegisterPassable, TypeCallable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `TypeCallable`.
    """

    @staticmethod
    @always_inline("nodebug")
    def __call__():
        """Call the tasks based on the types on a sequence order."""
        comptime size = Variadic.size(Self.Ts)

        comptime for i in range(size):
            Self.Ts[i].__call__()
