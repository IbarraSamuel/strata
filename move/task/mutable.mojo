from move.callable import CallableMovable, Callable
from move.task_groups.series.mutable import SeriesTaskPair
from move.task_groups.parallel.mutable import ParallelTaskPair


struct Task[T: CallableMovable](CallableMovable):
    """A Wrapper to an owned Callable.

    Parameters:
        T: A task that conforms to `CallableMovable`.

    ```mojo
    from move.task.mutable import Task
    from testing import assert_true

    struct MyTask:
        var inner: Int
        fn __init__(out self):
            self.inner = 0

        fn __call__(mut self):
            print("mutate something")
            self.inner += 1

    my_task = MyTask()
    task = Task(my_task)

    # Run the task
    task()
    assert_true(my_task.inner == 1)
    ```
    """

    var inner: T
    """The wrapped task."""

    @implicit
    @always_inline("nodebug")
    fn __init__(out self, owned v: T):
        """Initialize a task using an owned task.

        Args:
            v: The task to take ownership. Should conform to CallableMovable.
        """
        self.inner = v^

    @implicit
    @always_inline("nodebug")
    fn __init__[
        o: Origin[True], t: Callable
    ](out self: Task[TaskRef[o, t]], ref [o]v: t):
        """Initialize a task from a reference to another task.

        Parameters:
            o: Origin of the task that we will use to build a reference to.
            t: A Task that conforms to `Callable`. Doesn't need to be `Movable` because the `TaskRef` will build a pointer, and move inside here.

        Args:
            v: The task to build a reference from. Only needs to conform to `Callable`.
        """
        self.inner = TaskRef(v)

    @always_inline("nodebug")
    fn __moveinit__(out self, owned other: Self):
        """Move the task from other instance.

        Args:
            other: The task to move the inner value from.
        """
        self.inner = other.inner^

    @always_inline("nodebug")
    fn __call__(mut self):
        """Call the inner task directly."""
        self.inner()

    @always_inline("nodebug")
    fn __add__[
        o: Origin[True], t: Callable, //
    ](owned self, ref [o]other: t) -> Task[
        ParallelTaskPair[Self, TaskRef[o, t]]
    ]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            o: The origin of the other callable.
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of values: self, and other task, to be ran on parallel.
        """
        return ParallelTaskPair(self^, TaskRef(other))

    @always_inline("nodebug")
    fn __add__[
        t: CallableMovable, //
    ](owned self, owned other: t) -> Task[ParallelTaskPair[Self, t]]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of values: self, and other task, to be ran on parallel.
        """
        return ParallelTaskPair(self^, other^)

    @always_inline("nodebug")
    fn __rshift__[
        o: Origin[True], t: Callable, //
    ](owned self, ref [o]other: t) -> Task[SeriesTaskPair[Self, TaskRef[o, t]]]:
        """Add this task pair with another task, to be executed in sequence.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            o: Origin of the other task.
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed fater this group.

        Returns:
            A pair of values: self, and other task, to be ran on sequence.
        """
        return SeriesTaskPair(self^, TaskRef(other))

    @always_inline("nodebug")
    fn __rshift__[
        t: CallableMovable, //
    ](owned self, owned other: t) -> Task[SeriesTaskPair[Self, t]]:
        """Add this task pair with another task, to be executed in sequence.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            t: Type that conforms to `CallableDefaultable`.

        Args:
            other: The task to be executed fater this group.

        Returns:
            A pair of values: self, and other task, to be ran on sequence.
        """
        return SeriesTaskPair(self^, other^)


@register_passable("trivial")
struct TaskRef[origin: Origin[True], T: Callable](CallableMovable):
    """A reference to a Mutable Task with `Operation` capabilities.

    There is a known issue. When doing expressions, the Left hand side needs to be
    transferred to the result, because if not, we cannot mutate a expression value.
    We actually can transfer the reference, but not the Wrapping type.

    Parameters:
        origin: Where the `Callable` type it's defined.
        T: A task that conforms to `Callable`.

    ```mojo
    from move.task.mutable import TaskRef
    from testing import assert_true

    struct MyTask:
        var value: Int
        fn __init__(out self):
            self.value = 0

        fn __call__(mut self):
            print("Mutate something...")
            self.value += 1

    my_task = MyTask()
    taskref = TaskRef(my_task)
    taskref()

    assert_true(my_task.value == 1)

    ```
    """

    var inner: Pointer[T, origin]
    """The task we will keep a reference from."""

    @always_inline("nodebug")
    fn __init__(out self, ref [origin]inner: T):
        """Initialize the TaskRef using an existing variable of type `Callable`.

        Args:
            inner: The task that we will refer to.
        """
        self.inner = Pointer(to=inner)

    @always_inline("nodebug")
    fn __call__(self):
        """Call the inner task, and mutate if needed."""
        self.inner[]()
