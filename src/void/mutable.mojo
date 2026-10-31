"""Mutable void-returning task pipeline primitives."""

from std.runtime._asyncrt import TaskGroup, _run

comptime MutCallablePack = VariadicPack[
    elt_is_mutable=True, element_trait=MutCallable, False, ...
]
"""Variadic pack alias for mutable callables."""


trait _Callable:
    def __call__(mut self):
        ...


trait MutCallable(_Callable):
    """Trait for callables requiring mutable access to self."""

    # ---- FOR MUTABLE VERSIONS -----
    def __add__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        """Combine two mutable callables in parallel by reference.

        Parameters:
            s: Origin of self.
            o: Origin of other.

        Args:
            other: Other mutable callable.

        Returns:
            A ParallelTaskPair executing both tasks in parallel.
        """
        return {_TaskRef(self), _TaskRef(other)}

    def __rshift__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        """Sequence two mutable callables by reference.

        Parameters:
            s: Origin of self.
            o: Origin of other.

        Args:
            other: Other mutable callable.

        Returns:
            A SequentialTaskPair executing self then other.
        """
        return {_TaskRef(self), _TaskRef(other)}

    # When a pure MutCallable (first value) mets a var
    def __add__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & Deinitable],
    ) -> ParallelTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        """Combine this mutable callable reference with an owned callable in parallel.

        Parameters:
            s: Origin of self.

        Args:
            other: Owned callable.

        Returns:
            A ParallelTaskPair executing both.
        """
        return {_TaskRef(self), other^}

    def __rshift__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & Deinitable],
    ) -> SequentialTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        """Sequence this mutable callable reference with an owned callable.

        Parameters:
            s: Origin of self.

        Args:
            other: Owned callable.

        Returns:
            A SequentialTaskPair executing self then other.
        """
        return {_TaskRef(self), other^}


trait _MovableMutCallable(Deinitable, Movable, _Callable):
    def __call__(mut self):
        ...

    def __add__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    def __rshift__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    def __add__(
        var self, var other: Some[_Callable & Movable & Deinitable]
    ) -> ParallelTaskPair[Self, type_of(other)]:
        return {self^, other^}

    def __rshift__(
        var self, var other: Some[_Callable & Movable & Deinitable]
    ) -> SequentialTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct SeriesTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    """Sequential execution group of mutable tasks.

    Parameters:
        origin: Origin of task references.
        ts: Types of tasks in the group.
    """

    var storage: MutCallablePack[origin=Self.origin, *Self.ts]
    """Underlying storage for mutable task pointers."""

    def __init__(
        out self: SeriesTask[origin=args.origin, *Self.ts],
        mut *args: *Self.ts,
    ):
        """Initialize the SeriesTask with mutable task references.

        Args:
            args: Mutable task references.
        """
        self.storage = MutCallablePack[origin=args.origin, *Self.ts](
            args._value
        )

    def __call__(mut self):
        """Execute tasks sequentially in order."""
        comptime for ci in range(Self.ts.length):
            self.storage[ci].__call__()


struct ParallelTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    """Parallel execution group of mutable tasks.

    Parameters:
        origin: Origin of task references.
        ts: Types of tasks in the group.
    """

    var storage: MutCallablePack[origin=Self.origin, *Self.ts]
    """Underlying storage for mutable task pointers."""

    def __init__(
        out self: ParallelTask[origin=args.origin, *Self.ts],
        mut *args: *Self.ts,
    ):
        """Initialize the ParallelTask with mutable task references.

        Args:
            args: Mutable task references.
        """
        self.storage = MutCallablePack[origin=args.origin, *Self.ts](
            args._value
        )

    @staticmethod
    __async def _run_mut_task[T: MutCallable, o: MutOrigin](t: Pointer[T, o]):
        t[].__call__()

    def __call__(mut self):
        """Execute all mutable tasks concurrently in a TaskGroup."""
        comptime size = Self.ts.length

        var tg = TaskGroup()
        comptime for ci in range(size):
            tg.create_task(
                Self._run_mut_task[Self.ts[ci], Self.origin](
                    Pointer(to=self.storage[ci])
                )
            )

        tg.wait()


@fieldwise_init
struct SequentialTaskPair[
    T1: Movable & _Callable & Deinitable,
    T2: Movable & _Callable & Deinitable,
](_MovableMutCallable):
    """Sequential pair of owned or reference mutable tasks.

    Parameters:
        T1: Type of first task.
        T2: Type of second task.
    """

    var t1: Self.T1
    """First task."""
    var t2: Self.T2
    """Second task."""

    def __call__(mut self):
        """Execute both tasks sequentially."""
        self.t1.__call__()
        self.t2.__call__()


@fieldwise_init
struct ParallelTaskPair[
    T1: Movable & _Callable & Deinitable,
    T2: Movable & _Callable & Deinitable,
](_MovableMutCallable):
    """Parallel pair of owned or reference mutable tasks.

    Parameters:
        T1: Type of first task.
        T2: Type of second task.
    """

    var t1: Self.T1
    """First task."""
    var t2: Self.T2
    """Second task."""

    @staticmethod
    __async def _run_pair_task[T: _Callable, o: MutOrigin](t: Pointer[T, o]):
        t[].__call__()

    def __call__(mut self):
        """Execute both tasks concurrently in a TaskGroup."""
        var tg = TaskGroup()

        tg.create_task(Self._run_pair_task(Pointer(to=self.t1)))
        tg.create_task(Self._run_pair_task(Pointer(to=self.t2)))
        tg.wait()


struct _TaskRef[origin: MutOrigin, //, T: _Callable](
    Movable, TrivialRegisterPassable, _Callable
):
    var inner: Pointer[Self.T, Self.origin]

    def __init__(out self, ref[Self.origin] inner: Self.T):
        self.inner = Pointer(to=inner)

    def __call__(self):
        self.inner[]()
