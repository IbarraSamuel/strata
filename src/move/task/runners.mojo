from move.task.runnable_pack import RunnablePack
from move.task.traits import Runnable, RunnableDefaultable
from algorithm import parallelize


# Execute tasks in series


fn series_runner[*Ts: RunnableDefaultable]():
    """Run Runnable structs in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        Ts[i]().run()


fn series_runner[*ts: Runnable](*args: *ts):
    rp = RunnablePack(args._value)
    series_runner(rp)


fn series_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    """Run Runnable struct instances in sequence."""
    alias size = len(VariadicList(Ts))

    @parameter
    for i in range(size):
        runnables[i].run()


# Execute tasks in parallel


fn parallel_runner[*Ts: RunnableDefaultable]():
    """Run Runnable structs in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                Ts[ti]().run()

    parallelize[exec](size)


fn parallel_runner[*ts: Runnable](*args: *ts):
    rp = RunnablePack(args._value)
    parallel_runner(runnables=rp)


fn parallel_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    """Run Runnable struct instances in parallel."""
    alias size = len(VariadicList(Ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                runnables[ti].run()

    parallelize[exec](size)
