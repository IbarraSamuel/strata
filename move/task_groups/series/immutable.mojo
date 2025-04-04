from move.callable import (
    Callable,
    CallablePack,
    CallableMsgPack,
    CallableDefaultable,
    ImmCallable,
    ImmCallableWithMessage,
    CallableMovable,
)
from move.runners import series_runner, series_msg_runner
from move.task_groups.parallel.immutable import (
    ImmParallelTaskPair,
    ImmParallelMsgTaskPair,
)
from move.message import Message


# Variadic Series
struct ImmSeriesTask[origin: ImmutableOrigin, *Ts: ImmCallable](ImmCallable):
    """Collection of immutable tasks to run in Series.

    Parameters:
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.

    ```mojo
    from move.task_groups.series.immutable import ImmSeriesTask

    struct ImmTask:
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Working...")

    t1 = ImmTask()
    t2 = ImmTask()
    t3 = ImmTask()

    series = ImmSeriesTask(t1, t2, t3)
    # Running tasks in series.
    series()
    ```
    """

    var callables: CallablePack[origin, *Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(
        out self: ImmSeriesTask[__origin_of(args._value), *Ts], *args: *Ts
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


# Series Pair
struct ImmSeriesTaskPair[
    T1: ImmCallable,
    T2: ImmCallable,
    origin_1: ImmutableOrigin,
    origin_2: ImmutableOrigin,
](ImmCallable, Movable):
    """Collects a pair of immutable tasks pointers.

    Parameters:
        T1: Type that conforms to `ImmCallable`.
        T2: Type that conforms to `ImmCallable`.
        origin_1: Origin for the first type.
        origin_2: Origin for the second type.

    ```mojo
    from move.task_groups.series.immutable import ImmSeriesTaskPair
    from move.callable import ImmCallable

    struct ImmTask(ImmCallable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Working")

    task_1 = ImmTask()
    task_2 = ImmTask()
    pair = ImmSeriesTaskPair(task_1, task_2)

    # This will run both in a sequence.
    pair()
    ```
    """

    var v1: Pointer[T1, origin_1]
    """First task."""
    var v2: Pointer[T2, origin_2]
    """Second task."""

    fn __init__(out self, ref [origin_1]v1: T1, ref [origin_2]v2: T2):
        """Initialize the task pair using pointers.

        Args:
            v1: First task to point to.
            v2: Second task to point to.
        """
        self.v1 = Pointer(to=v1)
        self.v2 = Pointer(to=v2)

    fn __moveinit__(out self, owned existing: Self):
        """Move tasks from an existing task pair.

        Args:
            existing: The value to move from.
        """
        self.v1 = existing.v1
        self.v2 = existing.v2

    fn __call__(self):
        """Executes both tasks in series."""
        series_runner(self.v1[], self.v2[])

    fn __add__[
        t: ImmCallable, s: ImmutableOrigin, o: ImmutableOrigin
    ](ref [s]self, ref [o]other: t) -> ImmParallelTaskPair[Self, t, s, o]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `ImmCallable`.
            s: Origin of self.
            o: Origin of the other type.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return ImmParallelTaskPair(self, other)

    fn __rshift__[
        t: ImmCallable, s: ImmutableOrigin, o: ImmutableOrigin
    ](ref [s]self, ref [o]other: t) -> ImmSeriesTaskPair[Self, t, s, o]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            t: Type that conforms to `ImmCallable`.
            s: Origin of self.
            o: Origin of the other type.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return ImmSeriesTaskPair(self, other)


# Variadic Parallel
struct ImmSeriesMsgTask[origin: Origin, *Ts: ImmCallableWithMessage](
    ImmCallableWithMessage
):
    """Immutable tasks that will use a message in, message out.

    Parameters:
        is_mutable: Wether if the origin of `VariadicPack` is mutable or not.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallableWithMessage types that conforms to `ImmCallableWithMessage`.

    ```mojo
    from move.task_groups.series.immutable import ImmSeriesMsgTask
    from move.message import Message

    struct MsgTask:
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Reading message keys...")
            for k in msg.keys():
                print(k[])

            return msg

    m1 = MsgTask()
    m2 = MsgTask()

    series = ImmSeriesMsgTask(m1, m2)

    # this will run both message tasks in sequence.
    msg = Message()
    msg_out = series(msg)
    print(msg_out.__str__())
    ```
    """

    var callables: CallableMsgPack[origin, *Ts]
    """The underlying storage for message pointers."""

    fn __init__(
        out self: ImmSeriesMsgTask[__origin_of(args._value), *Ts], *args: *Ts
    ):
        """Create a group of msg tasks.

        Args:
            args: The msg tasks to be included in the group.
        """
        self.callables = rebind[CallableMsgPack[__origin_of(args._value), *Ts]](
            CallableMsgPack(args._value)
        )

    fn __call__(self, owned msg: Message) -> Message:
        """This will run the underlying tasks using the message,
        but the message could be modified in the execution of the sequence.

        Args:
            msg: The message to read.

        Returns:
            The message modified.
        """
        return series_msg_runner(msg, self.callables)


# Series Pair
struct ImmSeriesMsgTaskPair[
    o1: Origin,
    o2: Origin,
    t1: ImmCallableWithMessage,
    t2: ImmCallableWithMessage,
](ImmCallableWithMessage):
    """A pair of Message Immutalbe Tasks.

    Parameters:
        is_mutable: Wether if the origin is mutable.
        o1: Origin for the first type.
        o2: Origin for the second type.
        t1: First type that conforms to `ImmCallableWithMessage`.
        t2: Second type that conforms to `ImmCallableWithMessage`.

    ```mojo
    from move.task_groups.series.immutable import ImmSeriesMsgTaskPair
    from move.message import Message

    struct MsgTask:
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Do something with the message")
            return msg

    t1 = MsgTask()
    t2 = MsgTask()
    stp = ImmSeriesMsgTaskPair(t1, t2)

    # Run the pair
    msg = Message()
    msg_out = stp(msg)
    print(msg_out.__str__())
    ```
    """

    var v1: Pointer[t1, o1]
    """First msg task."""
    var v2: Pointer[t2, o2]
    """Second msg task."""

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        """Start a Msg Task pair using two reference to messages.

        Args:
            v1: First message task.
            v2: Second message task.
        """
        self.v1 = Pointer(to=v1)
        self.v2 = Pointer(to=v2)

    fn __call__(self, owned message: Message) -> Message:
        """Call both message tasks in sequence.

        Args:
            message: The message or context to read.

        Returns:
            The message output from this task or job.
        """
        return series_msg_runner(message, self.v1[], self.v2[])

    fn __add__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return ImmParallelMsgTaskPair(self, other)

    fn __rshift__[
        s: Origin, o: Origin, t: ImmCallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return ImmSeriesMsgTaskPair(self, other)


struct SeriesDefaultTask[*Ts: CallableDefaultable](CallableDefaultable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        Ts: Types that conforms to `CallableDefaultable`.

    ```mojo
    from move.task_groups.series.immutable import SeriesDefaultTask

    struct DefTask:
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running...")

    struct DefTask2:
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
