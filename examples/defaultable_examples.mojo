from time import sleep
from move.immutable import Callable

alias time = 0.1


struct MyDefaultTask[name: StringLiteral](Callable, Defaultable):
    fn __init__(out self):
        pass

    fn __call__(self):
        print("Task [", name, "] Running...")
        sleep(time)


fn main():
    print("\n\nHey! Running Defaultable Examples...")
    # Defaultables
    from move.defaultable import SeriesDefaultTask as SD
    from move.defaultable import ParallelDefaultTask as PD

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

    # # Airflow Syntax with structs Instanciated.
    from move.defaultable import DefaultTask as DT

    defaultables_graph = (
        DT[Initialize]()
        >> LoadData()
        >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    print("[Airflow Graph]...")
    defaultables_graph()
