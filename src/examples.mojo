from time import sleep


struct MyDefaultTask[name: StringLiteral]:
    fn __init__(out self):
        pass

    fn __call__(self):
        print("Task [", name, "] Running...")
        sleep(UInt(1))


struct MyTask[job: StringLiteral]:
    var some_data: String

    fn __init__(out self, owned some_data: StringLiteral):
        self.some_data = some_data

    fn __call__(self):
        print("Running [", job, "]:", self.some_data)
        sleep(UInt(1))


fn main():
    # Defaultables
    from move.task.model import (
        ParallelDefaultTask as PD,
        SeriesDefaultTask as SD,
        DefaultTask as DT,
    )

    alias Initialize = MyDefaultTask["Initialize"]
    alias LoadData = MyDefaultTask["LoadData"]
    alias FindMin = MyDefaultTask["FindMin"]
    alias FindMax = MyDefaultTask["FindMax"]
    alias FindMean = MyDefaultTask["FindMean"]
    alias FindMedian = MyDefaultTask["FindMedian"]
    alias MergeResults = MyDefaultTask["MergeResults"]

    alias TypesGraph = SD[
        Initialize,
        LoadData,
        PD[FindMin, FindMax, FindMean, FindMedian],
        MergeResults,
    ]
    print("[TYPES GRAPH 1]...")
    types_graph = TypesGraph()
    types_graph()

    # Airflow Syntax with structs Instanciated.

    defaultables_graph = (
        DT[Initialize]()
        >> LoadData()
        >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    print("[TYPES GRAPH 2]...")
    defaultables_graph()

    # Run time values...
    from move.task.model import Task as T, SeriesTask as ST, ParallelTask as PT

    init = MyTask["Initialize"]("Setting up...")
    load = MyTask["Load Data"]("Reading from some place...")
    find_min = MyTask["Min"]("Calculating...")
    find_max = MyTask["Max"]("Calculating...")
    find_mean = MyTask["Mean"]("Calculating...")
    find_median = MyTask["Median"]("Calculating...")
    merge_results = MyTask["Merge Results"]("Getting all together...")

    # Using Type syntax
    graph_1 = ST(
        init,
        load,
        PT(find_min, find_max, find_mean, find_median),
        merge_results,
    )
    print("[GRAPH 1]...")
    graph_1()

    # # Airflow Syntax
    graph_2 = (
        T(init)
        >> load
        >> T(find_min) + find_max + find_mean + find_median
        >> merge_results
    )
    print("[GRAPH 2]...")
    graph_2()

    # What about functions? Yes, but need to be wrapped in the Fn struct.
    # Internally it will be converted to a Fn struct that implements __call__
    from move.task.model import Fn

    fn first_task():
        print("Initialize everything...")
        sleep(UInt(1))

    fn last_task():
        print("Finalize everything...")
        sleep(UInt(1))

    fn parallel1():
        print("Parallel 1...")
        sleep(UInt(1))

    fn parallel2():
        print("Parallel 2...")
        sleep(UInt(1))

    # Fn will make them callable since `fn() -> None` not implements __call__(self)
    ft = Fn(first_task)
    p1 = Fn(parallel1)
    p2 = Fn(parallel2)
    lt = Fn(last_task)
    print("[ Function Graph ]...")
    fn_graph = T(ft) >> T(p1) + p2 >> lt
    fn_graph()
