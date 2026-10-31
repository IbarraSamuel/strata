"""Static type-level task pipelines for stateless task execution."""

from std.runtime._asyncrt import TaskGroup


trait TypeCallable:
    """Trait for types that can be invoked statically without an instance."""

    @staticmethod
    def __call__():
        """Invoke the static callable."""
        ...

    @always_inline("nodebug")
    def __rshift__[
        t: TypeCallable, //
    ](var self, other: t) -> SeriesTypeTask[Self, t]:
        """Sequence two static type callables.

        Parameters:
            t: Type of next stage.

        Args:
            other: Next type callable.

        Returns:
            A SeriesTypeTask executing self then other.
        """
        self^.forget()
        return {}

    @always_inline("nodebug")
    def __add__[
        t: TypeCallable, //
    ](var self, other: t) -> ParallelTypeTask[Self, t]:
        """Combine two static type callables in parallel.

        Parameters:
            t: Type of parallel stage.

        Args:
            other: Parallel type callable.

        Returns:
            A ParallelTypeTask executing self and other.
        """
        self^.forget()
        return {}

    @always_inline("nodebug")
    def forget(deinit self):
        """Consume and discard this instance."""
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

        var tg = TaskGroup()
        comptime for ti in range(Self.Ts.length):

            __async def t():
                Self.Ts[ti].__call__()

            tg.create_task(t())

        tg.wait()


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

        comptime for i in range(Self.Ts.length):
            Self.Ts[i].__call__()
