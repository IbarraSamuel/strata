"""Asynchronous immutable void-returning task pipeline primitives."""

from std.runtime._asyncrt import TaskGroup


trait AsyncCallable:
    """Trait for asynchronous void-returning callables."""

    __async def __call__(self):
        """Asynchronously execute the task."""
        ...

    def __add__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref[s] self, ref[o] other: t) -> ParTaskPair[Self, t, s, o]:
        """Combine two async tasks in parallel.

        Parameters:
            s: Origin of self.
            o: Origin of other.
            t: Type of other task.

        Args:
            other: Parallel async task.

        Returns:
            A ParTaskPair executing both concurrently.
        """
        return {self, other}

    def __rshift__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref[s] self, ref[o] other: t) -> SerTaskPair[Self, t, s, o]:
        """Sequence two async tasks.

        Parameters:
            s: Origin of self.
            o: Origin of other.
            t: Type of other task.

        Args:
            other: Next async task.

        Returns:
            A SerTaskPair executing self then other.
        """
        return {self, other}


struct SerTaskPair[
    m1: Bool,
    m2: Bool,
    //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[mut=m1],
    o2: Origin[mut=m2],
](AsyncCallable):
    """Sequential pair of async task references.

    Parameters:
        m1: Mutability of first task reference.
        m2: Mutability of second task reference.
        T1: Type of first task.
        T2: Type of second task.
        o1: Origin of first task.
        o2: Origin of second task.
    """

    var t1: Pointer[Self.T1, Self.o1]
    """Pointer to first task."""
    var t2: Pointer[Self.T2, Self.o2]
    """Pointer to second task."""

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        """Initialize with references to two async tasks.

        Args:
            t1: Reference to first task.
            t2: Reference to second task.
        """
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    __async def __call__(self):
        """Asynchronously execute first task, then second task."""
        __await self.t1[]()
        __await self.t2[]()

    def run(self):
        """Execute the sequential pair synchronously using a TaskGroup."""
        var tg = TaskGroup()
        tg.create_task(self())
        tg.wait()


struct ParTaskPair[
    m1: Bool,
    m2: Bool,
    //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[mut=m1],
    o2: Origin[mut=m2],
](AsyncCallable):
    """Parallel pair of async task references.

    Parameters:
        m1: Mutability of first task reference.
        m2: Mutability of second task reference.
        T1: Type of first task.
        T2: Type of second task.
        o1: Origin of first task.
        o2: Origin of second task.
    """

    var t1: Pointer[Self.T1, Self.o1]
    """Pointer to first task."""
    var t2: Pointer[Self.T2, Self.o2]
    """Pointer to second task."""

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        """Initialize with references to two async tasks.

        Args:
            t1: Reference to first task.
            t2: Reference to second task.
        """
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    __async def __call__(self):
        """Asynchronously execute both tasks concurrently."""
        var tg = TaskGroup()
        tg.create_task(self.t1[]())
        tg.create_task(self.t2[]())
        __await tg

    def run(self):
        """Execute the parallel pair synchronously using a TaskGroup."""
        var tg = TaskGroup()
        tg.create_task(self())
        tg.wait()
