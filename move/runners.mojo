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

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.runners import series_runner

    struct Task:
        fn __init__(out self):
            pass
        fn __call__(self):
            print()

    alias t1 = Task
    alias t2 = Task

    # Will run t1 first, then t2
    series_runner[t1, t2]()

    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        Ts[i]()()


fn series_runner[*Ts: ImmCallable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.runners import series_runner
    from move.callable import ImmCallable, CallablePack
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

    fn series_variadic_inp[*ts: ImmCallable](*args: *ts):
        cp = CallablePack(args._value)
        series_runner(cp)
    # Will run t1 first, then t2
    series_variadic_inp(t1, t2)

    assert_true(t1_starts < t2_starts and t1_finish < t2_starts)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: ImmCallable](*callables: *ts):
    """Run Runnable structs in sequence.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A collection of `ImmCallable` types.

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
    rp = CallablePack(callables._value)
    series_runner(rp)


# This could be Variadic but I don't want this overhead now, because we don't have a struct collection for MutableCallables.
fn series_runner[t1: Callable, t2: Callable](mut c1: t1, mut c2: t2):
    """Run a pair of `RunnableMutable` structs in sequence.

    Parameters:
        t1: Task type to be grouped.
        t2: Task type to be grouped.

    Args:
        c1: Callable 1 from t1.
        c2: Callable 2 from t2.
    """
    c1()
    c2()


fn series_runner[
    o: Origin[True], *Ts: Callable
](callables: VariadicPack[o, Callable, *Ts]):
    """Run Runnable structs in sequence.

    Parameters:
        o: Origin of the VariadicPack.
        Ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.

    ```mojo
    from move.runners import series_runner
    from move.callable import Callable
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    struct Task(Callable):
        var start: UInt
        var finish: UInt
        fn __init__(out self):
            self.start = 0
            self.finish = 0
        fn __call__(mut self):
            self.start = perf_counter_ns()
            sleep(0.1)
            self.finish = perf_counter_ns()

    t1 = Task()
    t2 = Task()

    # Will run t1 first, then t2
    series_runner(t1, t2)

    assert_true(t1.finish < t2.start and t1.finish < t2.finish)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


# Execute tasks in parallel


fn parallel_runner[*Ts: CallableDefaultable]():
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `CallableDefaltable` types.

    ```mojo
    from move.runners import parallel_runner
    from time import sleep

    struct Task:
        fn __init__(out self):
            pass
        fn __call__(self):
            print("running")
            sleep(0.1)
            print("Done")

    alias t1 = Task
    alias t2 = Task

    # Will run t1 and t2 at the same time
    parallel_runner[t1, t2]()

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
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.runners import parallel_runner
    from move.callable import ImmCallable, CallablePack
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

    fn parallel_variadic_inp[*ts: ImmCallable](*args: *ts):
        cp = CallablePack(args._value)
        parallel_runner(cp)
    # Will run t1 and t2 at the same time
    parallel_variadic_inp(t1, t2)

    # TODO: Uncomment this when mojo supports threads in doctest
    # assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                callables[ti]()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: ImmCallable](*callables: *ts):
    """Run Runnable structs in parallel.

    Parameters:
        ts: Variadic `ImmCallable` types.

    Args:
        callables: A collection of `ImmCallable` types.

    ```mojo
    from move.runners import parallel_runner
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

    # Will run t1 and t2 at the same time
    parallel_runner(t1, t2)

    # TODO: Uncomment this when mojo supports threads in doctest
    # assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```
    """
    rp = CallablePack(callables._value)
    parallel_runner(rp)


# This could be Variadic but I don't want this overhead now, because we don't have a struct collection for MutableCallables.
fn parallel_runner[t1: Callable, t2: Callable](mut c1: t1, mut c2: t2):
    """Run a pair of `RunnableMutable` structs in parallel.

    Parameters:
        t1: Task type to be grouped.
        t2: Task type to be grouped.

    Args:
        c1: Callable 1 from t1.
        c2: Callable 2 from t2.
    """

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
    """Run Runnable structs in parallel.

    Parameters:
        o: Origin of the VariadicPack.
        Ts: Variadic `Callable` types.

    Args:
        callables: A `VariadicPack` collection of types.

    ```mojo
    from move.runners import parallel_runner
    from move.callable import Callable
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    struct Task(Callable):
        var start: UInt
        var finish: UInt
        fn __init__(out self):
            self.start = 0
            self.finish = 0
        fn __call__(mut self):
            self.start = perf_counter_ns()
            sleep(0.1)
            self.finish = perf_counter_ns()

    t1 = Task()
    t2 = Task()

    # Will run t1 and t2 at the same time.
    parallel_runner(t1, t2)

    # TODO: Uncomment this when mojo supports threads in doctest
    # assert_true(t2.start < t1.finish and t1.start < t2.finish)
    ```
    """
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
    """Run Runnable structs in parallel.
    In parallel, messages could not be modified.

    Parameters:
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A collection of `ImmCallable` types.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from move.runners import parallel_msg_runner
    from move.message import Message
    from move.callable import ImmCallableWithMessage
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](ImmCallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = parallel_msg_runner(msg, t1, t2)

    # TODO: Add assertions on message.
    # TODO: Uncomment this when mojo supports threads in doctest
    # assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```

    Syncs automatically.
    """
    cmp = CallableMsgPack(callables._value)
    return parallel_msg_runner(msg, cmp)


fn parallel_msg_runner[
    o: Origin, *C: ImmCallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    """Run Runnable structs in parallel.
    In parallel, messages could not be modified.

    Parameters:
        o: Origin of the CallableMsgPack.
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A CallableMsgPack.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from move.runners import parallel_msg_runner
    from move.message import Message
    from move.callable import ImmCallableWithMessage, CallableMsgPack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](ImmCallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    fn fromvpack[*ts: ImmCallableWithMessage](msg: Message, *args: *ts) -> Message:
        cmp = CallableMsgPack(args._value)
        return parallel_msg_runner(msg, cmp)

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = fromvpack(msg, t1, t2)

    # TODO: Add assertions on message.
    # TODO: Uncomment this when mojo supports threads in doctest
    # assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```

    Syncs automatically.
    """
    alias size = len(VariadicList(C))
    inp = msg.copy()

    @parameter
    fn append_msg(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                new_msg = callables[ti](inp)
                msg.update(new_msg)

    sync_parallelize[append_msg](size)
    return msg


fn series_msg_runner[
    *C: ImmCallableWithMessage
](owned msg: Message, *callables: *C) -> Message:
    """Run Runnable structs in series.
    In series, messages could be modified.

    Parameters:
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A collection of `ImmCallable` types.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from move.runners import series_msg_runner
    from move.message import Message
    from move.callable import ImmCallableWithMessage
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](ImmCallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and then t2
    msg = Message()
    msg_out = series_msg_runner(msg, t1, t2)
    # TODO: Add assertions on message.
    assert_true(t1_starts < t2_starts and t1_finish < t2_starts)
    ```

    Syncs automatically.
    """
    cmp = CallableMsgPack(callables._value)
    return series_msg_runner(msg, cmp)


fn series_msg_runner[
    o: Origin, *C: ImmCallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    """Run Runnable structs in series.
    In series, messages could be modified.

    Parameters:
        o: Origin of the CallableMsgPack.
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A CallableMsgPack.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from move.runners import series_msg_runner
    from move.message import Message
    from move.callable import ImmCallableWithMessage, CallableMsgPack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](ImmCallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer.address_of(start)
            self.finish = Pointer.address_of(finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    fn fromvpack[*ts: ImmCallableWithMessage](msg: Message, *args: *ts) -> Message:
        cmp = CallableMsgPack(args._value)
        return series_msg_runner(msg, cmp)

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = fromvpack(msg, t1, t2)

    assert_true(t1_starts < t2_starts and t1_finish < t2_starts)
    # TODO: Add assertions on message.
    ```

    Syncs automatically.
    """
    alias size = len(VariadicList(C))

    @parameter
    for i in range(size):
        msg = callables[i](msg^)

    return msg
