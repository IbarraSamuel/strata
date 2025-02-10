from move.task.runnable_pack import RunnablePack
from move.task.traits import Runnable, RunnableDefaultable
from algorithm import parallelize


# Execute tasks in series


fn series_runner[*ts: Runnable](*args: *ts):
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        args[i].run()


fn series_runner[*Ts: RunnableDefaultable]():
    """Run Runnable structs in sequence."""
    alias lst = VariadicList(Ts)

    @parameter
    for i in range(len(lst)):
        Ts[i]().run()


fn series_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    """Run Runnable struct instances in sequence."""
    alias lst = VariadicList(Ts)

    @parameter
    for i in range(len(lst)):
        runnables[i].run()


# Execute tasks in parallel
fn parallel_runner[*ts: Runnable](*args: *ts):
    alias size = len(VariadicList(ts))

    @parameter
    fn exec(i: Int):
        @parameter
        for ci in range(size):
            if ci == i:
                args[ci].run()

    parallelize[exec](size)


fn parallel_runner[*Ts: RunnableDefaultable]():
    """Run Runnable structs in parallel."""

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(len(VariadicList(Ts))):
            if ti == i:
                Ts[ti]().run()

    parallelize[exec](len(VariadicList(Ts)))


fn parallel_runner[*Ts: Runnable](runnables: RunnablePack[_, *Ts]):
    """Run Runnable struct instances in parallel."""

    @parameter
    fn exec(i: Int):
        @parameter
        for ti in range(len(VariadicList(Ts))):
            if ti == i:
                runnables[ti].run()

    parallelize[exec](len(VariadicList(Ts)))
