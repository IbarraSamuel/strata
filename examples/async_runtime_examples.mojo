from move.async_runtime import AsyncCallable
from time import sleep

alias time = 0.1


struct MyTask[job: StringLiteral](AsyncCallable):
    var some_data: String

    fn __init__(out self, owned some_data: StringLiteral):
        self.some_data = some_data

    async fn __call__(self):
        print("Running [", job, "]:", self.some_data)
        sleep(time)


fn main():
    print("\n\nHey! Running Async Runtime Examples...")
    from move.async_runtime import TaskRef as IT

    init = MyTask["Initialize"]("Setting up...")
    load = MyTask["Load Data"]("Reading from some place...")
    find_min = MyTask["Min"]("Calculating...")
    find_max = MyTask["Max"]("Calculating...")
    find_mean = MyTask["Mean"]("Calculating...")
    find_median = MyTask["Median"]("Calculating...")
    merge_results = MyTask["Merge Results"]("Getting all together...")

    airflow_graph = (
        IT(init)
        >> load
        >> IT(find_min) + find_max + find_mean + find_median
        >> merge_results
    )
    print("[GRAPH 2]...")
    from move.async_runtime import execute

    execute(airflow_graph())
