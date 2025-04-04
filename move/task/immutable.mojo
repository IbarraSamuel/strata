from move.callable import (
    ImmCallable,
    CallableDefaultable,
    ImmCallableWithMessage,
    Callable,
    ImmCallableMovable,
)
from move.task_groups.parallel.immutable import (
    ImmParallelTaskPair,
    ParallelDefaultTask,
    ImmParallelMsgTaskPair,
    ParallelTaskPair,
)
from move.task_groups.series.immutable import (
    ImmSeriesTaskPair,
    SeriesDefaultTask,
    ImmSeriesMsgTaskPair,
    SeriesTaskPair,
)
from move.message import Message


struct FnTask(ImmCallable):
    """This function takes any function with a signature: `fn() -> None`
     and hold it to later call it using `__call__()`.

     ```mojo
    from move.task.immutable import FnTask

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


struct ImmTask[T: ImmCallable, origin: ImmutableOrigin](ImmCallableMovable):
    """Refers to a task that cannot be mutated.

    Parameters:
        T: A type that conforms to `ImmCallable`.
        origin: The source for the `Immcallable` Task.

    ```mojo
    from move.task.immutable import ImmTask, FnTask

    fn simple_imm_task():
        print("Running immutable task...")

    # Conver the function to an object with a __call__ method.
    task = FnTask(simple_imm_task)

    # Create an Immutable Task
    imt = ImmTask(task)

    # Run the task
    imt()
    ```

    """

    var inner: Pointer[T, origin]
    """The immutable task wrapped."""

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        """Create a wrapper to a ImmutableTask using a pointer.

        Args:
            inner: The ImmutableTask to be wrapped.
        """
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        """Move the pointer.

        Args:
            other: The value to move the pointer from.
        """
        self.inner = other.inner

    fn __call__(self):
        """Invoke the inner value of the ImmutableTask."""
        self.inner[]()

    fn __add__[
        t: ImmCallable, o: ImmutableOrigin
    ](owned self, ref [o]other: t) -> ParallelTaskPair[Self, t, o]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `ImmCallable`.
            o: Origin of the other type.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return ParallelTaskPair(self^, other)

    fn __rshift__[
        t: ImmCallable, o: ImmutableOrigin
    ](owned self, ref [o]other: t) -> SeriesTaskPair[Self, t, o]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            t: Type that conforms to `ImmCallable`.
            o: Origin of the other type.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return SeriesTaskPair(self^, other)


struct MutTaskRef[T: Callable, origin: ImmutableOrigin](ImmCallable, Movable):
    """Refers to a task that contains interior mutability for the pointer that he stores.

    Parameters:
        T: A type that conforms to `ImmCallable`.
        origin: The source for the `Immcallable` Task.

    ```mojo
    from move.task.immutable import MutTaskRef
    from move.callable import Callable
    from testing import assert_true

    struct Task(Callable):
        var val: Int
        fn __init__(out self):
            self.val = 0

        fn __call__(mut self):
            print("Running mutable task...")
            self.val += 1

    task = Task()

    # Create an Immutable Task
    immutable = MutTaskRef(task)

    # Run the task
    immutable()

    # Check that it really mutates in the inside.
    assert_true(task.val == 1)
    ```

    """

    var inner: Pointer[T, origin]
    """Mutable Task Inside."""

    fn __init__[
        o: MutableOrigin
    ](
        out self: MutTaskRef[T, ImmutableOrigin.cast_from[o].result],
        ref [o]task: T,
    ):
        self.inner = Pointer(to=task).get_immutable()

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        # Make it mutable Again. Workarond for false positive.
        alias Ptr = Pointer[T, MutableOrigin.cast_from[origin].result]
        ptr = rebind[Ptr](self.inner)
        ptr[]()


trait MovImmCallable(Movable, ImmCallable):
    ...


# struct MutTask[T: MovImmCallable](ImmCallable):
#     var inner: T

#     fn __init__[
#         t: Callable, o: MutableOrigin
#     ](out self: MutTask[MutTaskRef[t, o]], ref [o]task: t):
#         self.inner = MutTaskRef(task)

#     fn __call__(self):
#         self.inner()


struct MsgFnTask(ImmCallableWithMessage):
    """This function takes any function with a signature: `fn(owned Message) -> Message`
    and hold it to later call it using `__call__()`.

    ```mojo
    from move.task.immutable import MsgFnTask
    from move.message import Message
    from testing import assert_true

    fn modify_message(owned msg: Message) -> Message:
        name = msg.get("name", "Sam")
        msg["greet"] = String("Hello, ", name)
        return msg

    msg = Message()
    msg["name"] = "Elio"
    task = MsgFnTask(modify_message)
    out_msg = task(msg)
    assert_true(out_msg.get("greet", "none"), "Hello, Elio")
    ```
    """

    var func: fn (owned Message) -> Message
    """Pointer to the function to call."""

    fn __init__(out self, func: fn (owned Message) -> Message):
        """Takes a `fn() -> None` and wrap it.

        Args:
            func: The function to be wraped.
        """
        self.func = func

    fn __call__(self, owned msg: Message) -> Message:
        """Call the inner function.

        Args:
            msg: The message to read.

        Returns:
            Message: The result of the task execution.
        """
        return self.func(msg^)


struct ImmMessageTask[origin: Origin, T: ImmCallableWithMessage](
    ImmCallableWithMessage
):
    """Refers to a task that cannot be mutated and receives a `Message` as argument,
    to give back a `Message` as output.

    Parameters:
        is_mutable: Wether if the task is mutable or not.
        origin: The source of the task.
        T: It's a task that conforms to `ImmCallableWithMessage`.

    ```mojo
    from move.task.immutable import ImmMessageTask, MsgFnTask
    from move.message import Message
    from testing import assert_true

    fn message_task(owned msg: Message) -> Message:
        name = msg.get("name", "Sam")
        print("reading message: ", name)
        msg["greet"] = String("Hello, ", name)
        return msg

    msg = Message()
    msg["name"] = "Bob"
    fntask = MsgFnTask(message_task)
    task = ImmMessageTask(fntask)
    out_msg = task(msg)
    assert_true(out_msg["greet"], "Hello, Bob")
    ```
    """

    var inner: Pointer[T, origin]
    """Pointer to the Task."""

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        """Create a wrapper to a ImmMessageTask using a pointer.

        Args:
            inner: The ImmMessageTask to be wrapped.
        """
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        """Move the pointer.

        Args:
            other: The value to move the pointer from.
        """
        self.inner = other.inner

    fn __call__(self, owned msg: Message) -> Message:
        """Call the inner function.

        Args:
            msg: The message to read.

        Returns:
            Message: The result of the task execution.
        """
        return self.inner[](msg^)

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


struct DefaultTask[T: CallableDefaultable](CallableDefaultable):
    """Refers to a task that can be instanciated in the future, because it's defaultable.

    Parameters:
        T: Type that conforms to `CallableDefaultable`.

    ```mojo
    from move.task.immutable import DefaultTask

    struct DefTask:
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
        T()()

    fn __add__[
        t: CallableDefaultable
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
        t: CallableDefaultable
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
