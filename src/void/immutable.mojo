from std.runtime._asyncrt import TaskGroup, _run

comptime CallablePack = VariadicPack[
    elt_is_mutable=False, element_trait=ImmCallable, False, ...
]


trait ImmCallable:
    """The struct should contain a def `__call__` method."""

    def __call__(self):
        ...

    @always_inline("nodebug")
    def __add__[
        s: ImmOrigin, o: ImmOrigin, t: ImmCallable, //
    ](ref[s] self, ref[o] other: t) -> ParallelTaskPairRef[o1=s, o2=o, Self, t]:
        return {self, other}

    @always_inline("nodebug")
    def __rshift__[
        s: ImmOrigin, o: ImmOrigin, t: ImmCallable, //
    ](ref[s] self, ref[o] other: t) -> SequentialTaskPairRef[
        o1=s, o2=o, Self, t
    ]:
        return {self, other}


@fieldwise_init("implicit")
struct Fn(ImmCallable):
    """This function takes any function with a signature: `def() -> None` and hold it to later call it using `__call__()`.
    """

    var func: def() thin
    """Pointer to the function to call."""

    def __call__(self):
        """Call the inner function."""
        self.func()


@fieldwise_init
struct SequentialTaskPairRef[
    o1: ImmOrigin,
    o2: ImmOrigin,
    //,
    T1: ImmCallable,
    T2: ImmCallable,
](ImmCallable, TrivialRegisterPassable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self):
        self.t1[].__call__()
        self.t2[].__call__()


@always_inline
__async def _run_imm_task[T: ImmCallable, o: ImmOrigin](t: Pointer[T, o]):
    t[].__call__()


@fieldwise_init
struct ParallelTaskPairRef[
    o1: ImmOrigin,
    o2: ImmOrigin,
    //,
    T1: ImmCallable,
    T2: ImmCallable,
](ImmCallable, TrivialRegisterPassable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self):
        var tg = TaskGroup()

        tg.create_task(_run_imm_task(self.t1))
        tg.create_task(_run_imm_task(self.t2))

        tg.wait()


# Variadic Parallel
struct ParallelTask[origin: ImmOrigin, //, *Ts: ImmCallable](ImmCallable):
    """Collection of immutable tasks to run in Parallel.

    Parameters:
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.
    """

    var callables: CallablePack[origin=Self.origin, *Self.Ts]
    """Underlying storage for tasks pointers."""

    def __init__(
        out self: ParallelTask[origin=args.origin, *Self.Ts], *args: *Self.Ts
    ):
        """Create a Parallel group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in parallel.
        """
        # self.callables = CallablePack[origin=args.origin, *Self.Ts](args._value)
        self.callables = CallablePack[origin=args.origin, *Self.Ts](args._value)

    def __call__(self):
        """This function executes all tasks at the same time."""
        comptime size = Self.Ts.length

        var tg = TaskGroup()
        comptime for ti in range(size):
            tg.create_task(
                _run_imm_task(
                    Pointer(to=self.callables[ti])
                )
            )

        tg.wait()


# # Variadic Series
struct SequentialTask[origin: ImmOrigin, //, *Ts: ImmCallable](ImmCallable):
    """Collection of immutable tasks to run in Series.

    Parameters:
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `Callable`.
    """

    var callables: CallablePack[origin=Self.origin, *Self.Ts]
    """Underlying storage for tasks pointers."""

    def __init__(
        out self: SequentialTask[origin=args.origin, *Self.Ts],
        *args: *Self.Ts,
    ):
        """Create a Series group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in series.
        """
        self.callables = CallablePack[origin=args.origin, *Self.Ts](args._value)

    def __call__(self):
        """This function executes all tasks in ordered sequence."""

        comptime for ci in range(Self.Ts.length):
            self.callables[ci].__call__()
