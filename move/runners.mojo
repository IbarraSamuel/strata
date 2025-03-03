from move.callable import (
    CallablePack,
    CallableMsgPack,
    ImmCallable,
    CallableDefaultable,
    Callable,
    ImmCallableWithMessage,
)
from algorithm import sync_parallelize

# For msg
from move.message import Message
from memory import ArcPointer

# Execute tasks in series


fn series_runner[*Ts: CallableDefaultable]():
    """Run Runnable structs in sequence.

    ```mojo
    from move.runners import series_runner
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

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


fn series_runner[*Ts: ImmCallable](callables: CallablePack[_, *Ts]):
    """Run Runnable struct instances in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: ImmCallable](*args: *ts):
    rp = CallablePack(args._value)
    series_runner(rp)


# This could be Variadic but I don't want this overhead now, because we don't have a struct collection for MutableCallables.
fn series_runner[t1: Callable, t2: Callable](mut c1: t1, mut c2: t2):
    """Run a pair of `RunnableMutable` structs in sequence."""
    c1()
    c2()


fn series_runner[
    o: Origin[True], *Ts: Callable
](callables: VariadicPack[o, Callable, *Ts]):
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


fn parallel_runner[*Ts: ImmCallable](callables: CallablePack[_, *Ts]):
    """Run Runnable struct instances in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: ImmCallable](*callables: *ts):
    rp = CallablePack(callables._value)
    parallel_runner(rp)


# This could be Variadic but I don't want this overhead now, because we don't have a struct collection for MutableCallables.
fn parallel_runner[t1: Callable, t2: Callable](mut c1: t1, mut c2: t2):
    """Run Runnable struct instances in parallel."""

    @parameter
    fn exec(i: Int):
        if i == 1:
            c1()
        else:
            c2()

    sync_parallelize[exec](2)


fn parallel_runner[
    o: Origin[True], *Ts: Callable
](callables: VariadicPack[o, Callable, *Ts]):
    """Run Runnable struct instances in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


# ----------------- MESSAGE RUNNERS --------------------


fn parallel_msg_runner[
    *C: ImmCallableWithMessage
](owned msg: Message, *callables: *C) -> Message:
    cmp = CallableMsgPack(callables._value)
    return parallel_msg_runner(msg, cmp)


fn parallel_msg_runner[
    o: Origin, *C: ImmCallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    alias size = len(VariadicList(C))
    m = ArcPointer(msg.copy())

    @parameter
    fn append_msg(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                new_msg = callables[ti](msg)
                m[].update(new_msg)

    return msg


fn series_msg_runner[
    *C: ImmCallableWithMessage
](owned msg: Message, *callables: *C) -> Message:
    cmp = CallableMsgPack(callables._value)
    return series_msg_runner(msg, cmp)


fn series_msg_runner[
    o: Origin, *C: ImmCallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    alias size = len(VariadicList(C))
    msg_copy = msg.copy()

    @parameter
    for i in range(size):
        new_msg = callables[i](msg_copy)
        msg.update(new_msg)

    return msg
