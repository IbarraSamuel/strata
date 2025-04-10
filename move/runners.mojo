from move.callable import (
    CallablePack,
    Callable,
    MutableCallable,
)
from algorithm import sync_parallelize

# For msg
from move.message import Message
from memory import ArcPointer

# Execute tasks in series


fn series_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in sequence.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.runners import series_runner
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

    fn series_variadic_inp[*ts: Callable](*args: *ts):
        cp = CallablePack(args._value)
        series_runner(cp)
    # Will run t1 first, then t2
    series_variadic_inp(t1, t2)

    assert_true(t1_finish < t2_starts)
    ```
    """
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


fn series_runner[*ts: Callable](*callables: *ts):
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
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 first, then t2
    series_runner(t1, t2)

    assert_true(t1_finish < t2_starts)
    ```
    """
    series_runner(CallablePack(callables._value))


# fn series_runner[
#     t1: MutableCallable, t2: MutableCallable
# ](mut c1: t1, mut c2: t2):
#     """Run a pair of `RunnableMutable` structs in sequence.

#     Parameters:
#         t1: Task type to be grouped.
#         t2: Task type to be grouped.

#     Args:
#         c1: Callable 1 from t1.
#         c2: Callable 2 from t2.
#     """
#     c1()
#     c2()


# fn series_runner[
#     o: MutableOrigin, *Ts: MutableCallable
# ](callables: VariadicPack[o, MutableCallable, *Ts]):
#     """Run Runnable structs in sequence.

#     Parameters:
#         o: Origin of the VariadicPack.
#         Ts: Variadic `Callable` types.

#     Args:
#         callables: A `VariadicPack` collection of types.

#     ```mojo
#     from move.runners import series_runner
#     from move.callable import MutableCallable
#     from time import perf_counter_ns, sleep
#     from memory import Pointer
#     from testing import assert_true

#     struct Task(MutableCallable):
#         var start: UInt
#         var finish: UInt
#         fn __init__(out self):
#             self.start = 0
#             self.finish = 0
#         fn __call__(mut self):
#             self.start = perf_counter_ns()
#             sleep(0.1)
#             self.finish = perf_counter_ns()

#     t1 = Task()
#     t2 = Task()

#     # Will run t1 first, then t2
#     series_runner(t1, t2)

#     assert_true(t1.finish < t2.finish)
#     ```
#     """
#     alias size = len(VariadicList(Ts))

#     @parameter
#     for i in range(size):
#         callables[i]()


# Execute tasks in parallel


fn parallel_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable structs in parallel.

    Parameters:
        Ts: Variadic `ImmCallable` types.

    Args:
        callables: A `CallablePack` collection of types.

    ```mojo
    from move.runners import parallel_runner
    from move.callable import Callable, CallablePack
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
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    fn parallel_variadic_inp[*ts: Callable](*args: *ts):
        cp = CallablePack(args._value)
        parallel_runner(cp)
    # Will run t1 and t2 at the same time
    parallel_variadic_inp(t1, t2)

    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
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


fn parallel_runner[*ts: Callable](*callables: *ts):
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
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self):
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    parallel_runner(t1, t2)

    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```
    """
    parallel_runner(CallablePack(callables._value))


# This could be Variadic but I don't want this overhead now, because we don't have a struct collection for MutableCallables.
# fn parallel_runner[
#     t1: MutableCallable, t2: MutableCallable
# ](mut c1: t1, mut c2: t2):
#     """Run a pair of `RunnableMutable` structs in parallel.

#     Parameters:
#         t1: Task type to be grouped.
#         t2: Task type to be grouped.

#     Args:
#         c1: Callable 1 from t1.
#         c2: Callable 2 from t2.
#     """

#     @parameter
#     fn exec(i: Int):
#         if i == 1:
#             c1()
#         else:
#             c2()

#     sync_parallelize[exec](2)


# fn parallel_runner[
#     o: MutableOrigin, *Ts: MutableCallable
# ](callables: VariadicPack[o, MutableCallable, *Ts]):
#     """Run Runnable structs in parallel.

#     Parameters:
#         o: Origin of the VariadicPack.
#         Ts: Variadic `Callable` types.

#     Args:
#         callables: A `VariadicPack` collection of types.

#     ```mojo
#     from move.runners import parallel_runner
#     from move.callable import MutableCallable
#     from time import perf_counter_ns, sleep
#     from memory import Pointer
#     from testing import assert_true

#     struct Task(MutableCallable):
#         var start: UInt
#         var finish: UInt
#         fn __init__(out self):
#             self.start = 0
#             self.finish = 0
#         fn __call__(mut self):
#             self.start = perf_counter_ns()
#             sleep(1.0) # Less times didn't work well on doctests
#             self.finish = perf_counter_ns()

#     t1 = Task()
#     t2 = Task()

#     # Will run t1 and t2 at the same time.
#     parallel_runner(t1, t2)

#     assert_true(t2.start < t1.finish and t1.start < t2.finish)
#     ```
#     """
#     alias size = len(VariadicList(Ts))

#     @parameter
#     fn exec(i: Int):
#         @parameter
#         for ti in range(size):
#             if ti == i:
#                 callables[ti]()

#     sync_parallelize[exec](size)


# ----------------- MESSAGE RUNNERS --------------------
