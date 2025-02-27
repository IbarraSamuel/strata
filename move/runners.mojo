from move.callable import (
    CallablePack,
    Callable,
    CallableDefaultable,
    CallableMutable,
)
from algorithm import sync_parallelize


# Execute tasks in series


fn series_runner[*Ts: CallableDefaultable]():
    """Run Runnable structs in sequence.

    ```mojo
    from move.runners import series_runner
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts= UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish= UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]]:
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 first, then t2
    series_runner(t1, t2)

    assert_true(t1_starts < t2_starts and t1_finish < t2_starts)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        Ts[i]()()


fn series_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable struct instances in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: Callable](*args: *ts):
    rp = CallablePack(args._value)
    series_runner(rp)


fn series_runner[*Ts: CallableMutable](mut*callables: *Ts):
    """Run Runnable struct instances in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


# Execute tasks in parallel


fn parallel_runner[*Ts: CallableDefaultable]():
    """Run `Runnable` struct instances in parallel.

    ```mojo
    from move.runners import parallel_runner
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts= UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish= UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]]:
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 first, then t2
    parallel_runner(t1, t2)

    assert_true(t1_starts < t2_finish and t1_starts < t2_finish)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                Ts[ti]()()

    sync_parallelize[exec](size)


fn parallel_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable struct instances in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: Callable](*callables: *ts):
    rp = CallablePack(callables._value)
    parallel_runner(rp)


fn parallel_runner[*Ts: CallableMutable](mut*callables: *Ts):
    """Run Runnable struct instances in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)
