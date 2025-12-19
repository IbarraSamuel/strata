from strata.async_mutable_task import AsyncCallable, TaskRef
from time import sleep

comptime time = 0.1


struct MyTask[job: StringLiteral](AsyncCallable):
    var some_data: String

    fn __init__(out self, var some_data: StringLiteral):
        self.some_data = some_data

    async fn __call__(self):
        print("Running [", Self.job, "]:", self.some_data)
        sleep(time)


fn main():
    print("\n\nHey! Running Async Mutable Examples...")

    init = MyTask["Initialize"]("Setting up...")
    load = MyTask["Load Data"]("Reading from some place...")
    find_min = MyTask["Min"]("Calculating...")
    find_max = MyTask["Max"]("Calculating...")
    find_mean = MyTask["Mean"]("Calculating...")
    find_median = MyTask["Median"]("Calculating...")
    merge_results = MyTask["Merge Results"]("Getting all together...")

    airflow_graph = (
        TaskRef(init)
        >> load
        >> TaskRef(find_min) + find_max + find_mean + find_median
        >> merge_results
    )
    print("[GRAPH 2]...")

    airflow_graph.run()

    # Lit Graph
    # [] mean 'Serial Executor'
    # {} mean 'Parallel Executor'

    # lit_graph: Seq = [
    #     init,
    #     load,
    #     {find_min, find_max, find_mean, find_median},
    #     merge_results,
    # ]
    # Import the executor and provide the coroutine

    # lit_graph.run()
