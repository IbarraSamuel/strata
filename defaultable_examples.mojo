from time import sleep


struct MyDefaultTask[name: StringLiteral]:
    fn __init__(out self):
        pass

    fn __call__(self):
        print("Task [", name, "] Running...")
        sleep(0.5)


fn main():
    print("Hey! Running Defaultable Examples...")
    # Defaultables
    from move.task_groups.series import SeriesDefaultTask as SD
    from move.task_groups.parallel import ParallelDefaultTask as PD

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
    print("[Types Graph 1]...")
    types_graph = TypesGraph()
    types_graph()

    # Airflow Syntax with structs Instanciated.
    from move.task.unit import DefaultTask as DT

    defaultables_graph = (
        DT[Initialize]()
        >> LoadData()
        >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    print("[Airflow Graph]...")
    defaultables_graph()
