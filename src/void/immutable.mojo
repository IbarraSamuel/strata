from algorithm import sync_parallelize
from builtin import Variadic

comptime CallablePack = VariadicPack[
    elt_is_mutable=False, origin=_, False, ImmutCallable, *_
]


trait ImmutCallable:
    """The struct should contain a fn `__call__` method."""

    fn __call__(self):
        ...

    @always_inline("nodebug")
    fn __add__[
        s: ImmutOrigin, o: ImmutOrigin, t: ImmutCallable, //
    ](ref [s]self, ref [o]other: t) -> ParallelTaskPairRef[o1=s, o2=o, Self, t]:
        return {self, other}

    @always_inline("nodebug")
    fn __rshift__[
        s: ImmutOrigin, o: ImmutOrigin, t: ImmutCallable, //
    ](ref [s]self, ref [o]other: t) -> SequentialTaskPairRef[
        o1=s, o2=o, Self, t
    ]:
        return {self, other}


@fieldwise_init("implicit")
struct Fn(ImmutCallable):
    """This function takes any function with a signature: `fn() -> None` and hold it to later call it using `__call__()`.
    """

    var func: fn ()
    """Pointer to the function to call."""

    fn __call__(self):
        """Call the inner function."""
        self.func()


@fieldwise_init
@register_passable("trivial")
struct SequentialTaskPairRef[
    o1: ImmutOrigin,
    o2: ImmutOrigin,
    //,
    T1: ImmutCallable,
    T2: ImmutCallable,
](ImmutCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    fn __init__(out self, ref [Self.o1]t1: Self.T1, ref [Self.o2]t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        self.t1[].__call__()
        self.t2[].__call__()


@fieldwise_init
@register_passable("trivial")
struct ParallelTaskPairRef[
    o1: ImmutOrigin,
    o2: ImmutOrigin,
    //,
    T1: ImmutCallable,
    T2: ImmutCallable,
](ImmutCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    fn __init__(out self, ref [Self.o1]t1: Self.T1, ref [Self.o2]t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self):
        @parameter
        fn exec(i: Int):
            if i == 0:
                self.t1[].__call__()
            else:
                self.t2[].__call__()

        sync_parallelize[exec](2)


# Variadic Parallel
struct ParallelTask[origin: ImmutOrigin, //, *Ts: ImmutCallable](ImmutCallable):
    """Collection of immutable tasks to run in Parallel.

    Parameters:
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `ImmCallable`.
    """

    var callables: CallablePack[origin = Self.origin, *Self.Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(
        out self: ParallelTask[origin = args.origin, *Self.Ts], *args: * Self.Ts
    ):
        """Create a Parallel group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in parallel.
        """
        self.callables = CallablePack(args._value)

    fn __call__(self):
        """This function executes all tasks at the same time."""
        comptime size = Variadic.size(Self.Ts)

        @parameter
        fn exec(i: Int):
            @parameter
            for ti in range(size):
                if ti == i:
                    self.callables[ti].__call__()
                    return

        sync_parallelize[exec](size)


# # Variadic Series
struct SequentialTask[origin: ImmutOrigin, //, *Ts: ImmutCallable](
    ImmutCallable
):
    """Collection of immutable tasks to run in Series.

    Parameters:
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallable types that conforms to `Callable`.
    """

    var callables: CallablePack[origin = Self.origin, *Self.Ts]
    """Underlying storage for tasks pointers."""

    fn __init__(
        out self: SequentialTask[origin = args.origin, *Self.Ts],
        *args: * Self.Ts,
    ):
        """Create a Series group, using the args provided. Origin need to be casted.

        Args:
            args: All tasks to be executed in series.
        """
        self.callables = CallablePack(args._value)

    fn __call__(self):
        """This function executes all tasks in ordered sequence."""
        comptime size = Variadic.size(Self.Ts)

        @parameter
        for ci in range(size):
            self.callables[ci].__call__()
