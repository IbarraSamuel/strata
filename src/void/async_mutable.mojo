"""Asynchronous mutable void-returning task pipeline primitives."""

from std.runtime._asyncrt import TaskGroup


trait AsyncCallable:
    """Trait for asynchronous callables with mutable state."""

    __async def __call__(mut self):
        """Asynchronously execute the mutable task."""
        ...

    def __add__[
        s: MutOrigin, o: MutOrigin
    ](ref[s] self, ref[o] other: Some[AsyncCallable]) -> ParTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        """Combine two mutable async task references in parallel.

        Parameters:
            s: Origin of self.
            o: Origin of other.

        Args:
            other: Parallel mutable async task.

        Returns:
            A ParTaskPair executing both concurrently.
        """
        return {TaskRef(self), TaskRef(other)}

    def __add__[
        s: MutOrigin,
    ](
        ref[s] self,
        var other: Some[AsyncCallable & Movable & Deinitable],
    ) -> ParTaskPair[TaskRef[Self, s], type_of(other)]:
        """Combine this mutable async task reference with an owned task in parallel.

        Parameters:
            s: Origin of self.

        Args:
            other: Owned mutable async task.

        Returns:
            A ParTaskPair executing both concurrently.
        """
        return {TaskRef(self), other^}

    def __rshift__[
        s: MutOrigin,
        o: MutOrigin,
    ](ref[s] self, ref[o] other: Some[AsyncCallable]) -> SerTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        """Sequence two mutable async task references.

        Parameters:
            s: Origin of self.
            o: Origin of other.

        Args:
            other: Next mutable async task.

        Returns:
            A SerTaskPair executing self then other.
        """
        return {TaskRef(self), TaskRef(other)}

    def __rshift__[
        s: MutOrigin,
    ](
        ref[s] self,
        var other: Some[AsyncCallable & Movable & Deinitable],
    ) -> SerTaskPair[TaskRef[Self, s], type_of(other)]:
        """Sequence this mutable async task reference with an owned task.

        Parameters:
            s: Origin of self.

        Args:
            other: Owned mutable async task.

        Returns:
            A SerTaskPair executing self then other.
        """
        return {TaskRef(self), other^}


trait AsyncCallableMovable(AsyncCallable, Deinitable, Movable):
    """Trait for movable asynchronous callables."""

    def __add__[
        o: MutOrigin,
    ](var self, ref[o] other: Some[AsyncCallable]) -> ParTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        """Combine owned task with a task reference in parallel.

        Parameters:
            o: Origin of other.

        Args:
            other: Reference to parallel task.

        Returns:
            A ParTaskPair executing both concurrently.
        """
        return {self^, TaskRef(other)}

    def __add__(
        var self,
        var other: Some[AsyncCallable & Movable & Deinitable],
    ) -> ParTaskPair[Self, type_of(other)]:
        """Combine two owned tasks in parallel.

        Args:
            other: Other owned async task.

        Returns:
            A ParTaskPair executing both concurrently.
        """
        return {self^, other^}

    def __rshift__[
        o: MutOrigin,
    ](var self, ref[o] other: Some[AsyncCallable]) -> SerTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        """Sequence an owned task with a task reference.

        Parameters:
            o: Origin of other.

        Args:
            other: Reference to next task.

        Returns:
            A SerTaskPair executing self then other.
        """
        return {self^, TaskRef(other)}

    def __rshift__(
        var self,
        var other: Some[AsyncCallable & Movable & Deinitable],
    ) -> SerTaskPair[Self, type_of(other)]:
        """Sequence two owned tasks.

        Args:
            other: Next owned async task.

        Returns:
            A SerTaskPair executing self then other.
        """
        return {self^, other^}


struct TaskRef[T: AsyncCallable, origin: MutOrigin](AsyncCallableMovable):
    """Reference wrapper for a mutable async task.

    Parameters:
        T: Type of the referenced task.
        origin: Lifetime origin of the reference.
    """

    var v: Pointer[Self.T, Self.origin]
    """Pointer to the referenced task."""

    def __init__(out self, ref[Self.origin] v: Self.T):
        """Initialize with a mutable reference to an async task.

        Args:
            v: Reference to async task.
        """
        self.v = Pointer(to=v)

    __async def __call__(mut self):
        """Asynchronously invoke the referenced task."""
        __await self.v[]()


@fieldwise_init
struct SerTaskPair[
    T1: AsyncCallable & Movable & Deinitable,
    T2: AsyncCallable & Movable & Deinitable,
](AsyncCallableMovable):
    """Sequential pair of movable async tasks.

    Parameters:
        T1: Type of first task.
        T2: Type of second task.
    """

    var t1: Self.T1
    """First task."""
    var t2: Self.T2
    """Second task."""

    __async def __call__(mut self):
        """Asynchronously execute first task, then second task."""
        __await self.t1()
        __await self.t2()

    def run(mut self):
        """Execute the sequential pair synchronously using a TaskGroup."""
        var tg = TaskGroup()
        tg.create_task(self())
        tg.wait()


@fieldwise_init
struct ParTaskPair[
    T1: AsyncCallable & Movable & Deinitable,
    T2: AsyncCallable & Movable & Deinitable,
](AsyncCallableMovable):
    """Parallel pair of movable async tasks.

    Parameters:
        T1: Type of first task.
        T2: Type of second task.
    """

    var t1: Self.T1
    """First task."""
    var t2: Self.T2
    """Second task."""

    __async def __call__(mut self):
        """Asynchronously execute both tasks concurrently."""
        var tg = TaskGroup()
        tg.create_task(self.t1())
        tg.create_task(self.t2())
        __await tg

    def run(mut self):
        """Execute the parallel pair synchronously using a TaskGroup."""
        var tg = TaskGroup()
        tg.create_task(self())
        tg.wait()
