from move.callable import CallableMovable  # , Callable
from move.runners import series_runner


# Series Mutable Pair
struct SeriesTaskPair[t1: CallableMovable, t2: CallableMovable](
    CallableMovable
):
    """Collection of Movable tasks to run in Series.

    Parameters:
        t1: Callable Movable type that conforms to `CallableMovable`.
        t2: Callable Movable type that conforms to `CallableMovable`.

    ```mojo
    from move.task_groups.series.mutable import SeriesTaskPair
    from move.callable import CallableMovable

    struct MovableTask(CallableMovable):
        fn __init__(out self):
            pass

        fn __moveinit__(out self, owned existing: Self):
            pass

        fn __call__(mut self):
            print("Working...")

    # TODO: Moves in docstrings are failing.
    # t1 = MovableTask()
    # t2 = MovableTask()
    # series = SeriesTaskPair(t1^, t2^)

    series = SeriesTaskPair(MovableTask(), MovableTask())
    # Running tasks in series.
    series()
    ```
    """

    var v1: t1
    """The task to be executed first."""
    var v2: t2
    """The task to be executed last."""

    @always_inline("nodebug")
    fn __init__(out self, owned v1: t1, owned v2: t2):
        """Initialize a `TaskPair` by passing two owned CallableMovable Tasks.

        Args:
            v1: Task that should be `CallableMovable`.
            v2: Task that should be `CallableMovable`.
        """
        self.v1 = v1^
        self.v2 = v2^

    @always_inline("nodebug")
    fn __moveinit__(out self, owned existing: Self):
        """Move the tasks from another instance of `Self`.

        Args:
            existing: The other instance to move the tasks from.
        """
        self.v1 = existing.v1^
        self.v2 = existing.v2^

    @always_inline("nodebug")
    fn __call__(mut self):
        """Triggers the group to be executed in sequence."""
        series_runner(self.v1, self.v2)


# Parallel Mutable Collections: (NOT WORKING)
# struct SeriesTask[origin: Origin[True], *types: Callable](Callable):
#     var tasks: VariadicPack[origin, Callable, *types]

#     fn __init__(
#         out self: SeriesTask[
#             MutableOrigin.cast_from[__origin_of(args._value)].result, *types
#         ],
#         mut*args: *types,
#     ):
#         value = rebind[__type_of(self.tasks)._mlir_type](args._value)
#         self.tasks = VariadicPack(value, is_owned=False)

#     fn __call__(mut self):
#         series_runner(self.tasks)
