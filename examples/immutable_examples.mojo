from time import sleep
from strata.immutable import Callable

alias time = 0.1


@fieldwise_init
struct MyTask[job: StringLiteral](Callable):
    var some_data: String

    fn __call__(self):
        print("Running [", job, "]:", self.some_data)
        sleep(time)


fn main():
    print("\n\nHey! Running Immutable Examples...")
    from strata.immutable import SequentialTask as IS
    from strata.immutable import ParallelTask as IP

    init = MyTask["Initialize"]("Setting up...")
    load = MyTask["Load Data"]("Reading from some place...")
    find_min = MyTask["Min"]("Calculating...")
    find_max = MyTask["Max"]("Calculating...")
    find_mean = MyTask["Mean"]("Calculating...")
    find_median = MyTask["Median"]("Calculating...")
    merge_results = MyTask["Merge Results"]("Getting all together...")

    # Using Type syntax
    graph_1 = IS(
        init,
        load,
        IP(find_min, find_max, find_mean, find_median),
        merge_results,
    )
    print("[GRAPH 1]...")
    graph_1()

    # Airflow Syntax

    graph_2 = (
        init
        >> load
        >> find_min + find_max + find_mean + find_median
        >> merge_results
    )
    print("[GRAPH 2]...")
    graph_2()

    # What about functions? Yes, those can be considered as ImmTasks.
    # But, you need to wrap those function into a FnTask type.
    # No arguments or captures are allowed, no returns. So it's not so useful.

    fn first_task():
        print("Initialize everything...")
        sleep(time)

    fn last_task():
        print("Finalize everything...")
        sleep(time)

    fn parallel1():
        print("Parallel 1...")
        sleep(time)

    fn parallel2():
        print("Parallel 2...")
        sleep(time)

    # NOTE: You need to do it here, because we need to have an Origin to be able to
    # use a reference to this functions. We can do it also by passing ownership, but I
    # don't want to do it right now. It will require to duplicate a lot of functions and
    # structs. But this is how I did for Mutable ones.

    from strata.immutable import Fn

    ft = Fn(first_task)
    p1 = Fn(parallel1)
    p2 = Fn(parallel2)
    lt = Fn(last_task)
    print("[ Function Graph ]...")
    fn_graph = ft >> p1 + p2 >> lt
    fn_graph()

    # Hey, but these things are not useful, because you cannot mutate anything.
    # That's not true, but if you really need that, see mutable_examples.mojo
