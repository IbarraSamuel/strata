from move.task.callable_pack import CallablePack
from move.task.traits import Callable, CallableDefaultable
from algorithm import sync_parallelize


# Execute tasks in series


fn series_runner[*Ts: CallableDefaultable]():
    """Run Runnable structs in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        alias T = Ts[i]
        t = T()
        t()


fn series_runner[*ts: Callable](*args: *ts):
    rp = CallablePack(args._value)
    series_runner(rp)


fn series_runner[*Ts: Callable](callables: CallablePack[_, *Ts]):
    """Run Runnable struct instances in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        callables[i]()


# Execute tasks in parallel


fn parallel_runner[*Ts: CallableDefaultable]():
    """Run Runnable structs in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                alias T = Ts[ti]
                t = T()
                t()

    sync_parallelize[exec](size)


fn parallel_runner[*ts: Callable](*args: *ts):
    rp = CallablePack(args._value)
    parallel_runner(rp)


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
