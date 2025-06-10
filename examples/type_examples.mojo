from time import sleep
from strata.type import TypeCallable

alias time = 0.1


struct MyTypeTask[name: StringLiteral](TypeCallable):
    fn __init__(out self):
        pass

    @staticmethod
    fn __call__():
        print("Task [", name, "] Running...")
        sleep(time)


fn main():
    print("\n\nHey! Running Defaultable Examples...")
    # Defaultables
    from strata.type import SeriesTypeTask as SD
    from strata.type import ParallelTypeTask as PD

    alias Initialize = MyTypeTask["Initialize"]
    alias LoadData = MyTypeTask["LoadData"]
    alias FindMin = MyTypeTask["FindMin"]
    alias FindMax = MyTypeTask["FindMax"]
    alias FindMean = MyTypeTask["FindMean"]
    alias FindMedian = MyTypeTask["FindMedian"]
    alias MergeResults = MyTypeTask["MergeResults"]

    alias TypesGraph = SD[
        Initialize,
        LoadData,
        PD[FindMin, FindMax, FindMean, FindMedian],
        MergeResults,
    ]
    print("[Types Graph 1]...")
    TypesGraph.__call__()

    # # Airflow Syntax.
    from strata.type import TypeTask as DT

    alias airflow_graph = (
        DT[Initialize]()
        >> LoadData()
        >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    print("[Airflow Graph]...")
    airflow_graph.__call__()
