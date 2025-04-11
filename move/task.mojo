from move.callable import (
    MutableCallable,
    MutableCallableMovable,
    GenericCallablePack,
)
from algorithm import sync_parallelize

# from move.runners import series_runner, parallel_runner

# ====================== SAFE VERSION =======================


fn series_runner[
    o: MutableOrigin, *ts: MutableCallable
](callables: GenericCallablePack[o, MutableCallable, *ts]):
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: MutableCallable](mut*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.task import series_runner
    from move.callable import Callable, CallablePack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](Callable):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    series_runner(t1, t2)

    assert_true(t1_finish < t2_starts)
    ```
    """
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        callables[i]()


fn parallel_runner[
    o: MutableOrigin, *ts: MutableCallable
](callables: GenericCallablePack[o, MutableCallable, *ts]):
    alias size = len(VariadicList(ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: MutableCallable](mut*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.

    ```mojo
    from move.task import parallel_runner
    from move.callable import MutableCallable
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    struct Task(MutableCallable):
        var start: UInt
        var finish: UInt
        fn __init__(out self):
            self.start = 0
            self.finish = 0
        fn __call__(mut self):
            self.start = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish = perf_counter_ns()

    t1 = Task()
    t2 = Task()

    # Will run t1 and t2 at the same time.
    parallel_runner(t1, t2)

    assert_true(t2.start < t1.finish and t1.start < t2.finish)
    ```
    """
    alias size = len(VariadicList(ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


struct SeriesTask[o: MutableOrigin, *ts: MutableCallable](MutableCallable):
    var storage: GenericCallablePack[o, MutableCallable, *ts]

    fn __init__(
        out self: SeriesTask[
            MutableOrigin.cast_from[__origin_of(args._value)].result, *ts
        ],
        mut*args: *ts,
    ):
        self.storage = rebind[__type_of(self.storage)](
            GenericCallablePack(args._value)
        )

    # fn __moveinit__(out self, owned other: Self):
    #     self.storage = other.storage

    fn __call__(mut self):
        series_runner(self.storage)


struct ParallelTask[o: MutableOrigin, *ts: MutableCallable](MutableCallable):
    var storage: GenericCallablePack[o, MutableCallable, *ts]

    fn __init__(
        out self: ParallelTask[
            MutableOrigin.cast_from[__origin_of(args._value)].result, *ts
        ],
        mut*args: *ts,
    ):
        self.storage = rebind[__type_of(self.storage)](
            GenericCallablePack(args._value)
        )

    # fn __moveinit__(out self, owned other: Self):
    #     self.storage = other.storage

    fn __call__(mut self):
        parallel_runner(self.storage)


struct SerTaskPair[T1: MutableCallableMovable, T2: MutableCallableMovable](
    MutableCallableMovable
):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(mut self):
        series_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return ParTaskPair(self^, other^)

    fn __rshift__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return SerTaskPair(self^, other^)


struct ParTaskPair[T1: MutableCallableMovable, T2: MutableCallableMovable](
    MutableCallableMovable
):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(mut self):
        parallel_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return ParTaskPair(self^, other^)

    fn __rshift__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return SerTaskPair(self^, other^)


struct TaskRef[T: MutableCallable, origin: MutableOrigin](
    MutableCallableMovable
):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __copyinit__(out self, other: Self):
        self.inner = other.inner

    fn __call__(mut self):
        self.inner[]()

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return ParTaskPair(self^, TaskRef(other))

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return SerTaskPair(self^, TaskRef(other))

    # ---- FOR MUTABLE MOVABLE VERSIONS -----
    fn __add__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> ParTaskPair[Self, t]:
        return ParTaskPair(self^, other^)

    fn __rshift__[
        t: MutableCallableMovable
    ](owned self, owned other: t) -> SerTaskPair[Self, t]:
        return SerTaskPair(self^, other^)
