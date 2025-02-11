from time import sleep

# Tasks should be Runnable

# from move.task.traits import Runnable


struct Initialize:
    fn __init__(out self):
        pass

    fn run(self):
        print("Initializing...")
        sleep(UInt(1))


struct LoadData:
    fn __init__(out self):
        pass

    fn run(self):
        print("Loading Data...")
        sleep(UInt(1))


struct FindMin:
    fn __init__(out self):
        pass

    fn run(self):
        print("Finding Min Value...")
        sleep(UInt(1))


struct FindMax:
    fn __init__(out self):
        pass

    fn run(self):
        print("Finding Max Value...")
        sleep(UInt(1))


struct FindMean:
    fn __init__(out self):
        pass

    fn run(self):
        print("Finding Mean Value...")
        sleep(UInt(1))


struct FindMedian:
    fn __init__(out self):
        pass

    fn run(self):
        print("Finding Median Value...")
        sleep(UInt(1))


struct MergeResults:
    fn __init__(out self):
        pass

    fn run(self):
        print("Merging the Data...")
        sleep(UInt(1))


fn main():
    # Run time values...
    from move.task.model import Task as T, SeriesTask as ST, ParallelTask as PT

    init = Initialize()
    load = LoadData()
    find_min = FindMin()
    find_max = FindMax()
    find_mean = FindMean()
    find_median = FindMedian()
    merge_results = MergeResults()

    # Using Type syntax
    # graph_1 = ST(
    #     init, load, PT(find_max, find_mean, find_median), merge_results
    # )
    # print("[GRAPH 1]...")
    # graph_1.run()

    # Airflow Syntax
    graph_2 = (
        T(init)
        >> load
        >> T(find_min) + find_max + find_mean + find_median
        >> merge_results
    )
    # T is needed to implement the __add__ and __rshift__ methods.
    # Will not be needed when default traits implementations works.
    # Or you can implement those methods yourself.
    print("[GRAPH 2]...")
    _ = graph_2^
    # graph_2.run()

    # If the tasks are defaultable, you can instanciate them when calling them, so it's more 'lazy'

    from move.task.model import (
        ParallelDefaultTask as PD,
        SeriesDefaultTask as SD,
        DefaultTask as DT,
    )

    alias types_graph_1 = SD[
        Initialize,
        LoadData,
        PD[FindMin, FindMax, FindMean, FindMedian],
        MergeResults,
    ]
    print("[TYPES GRAPH 1]...")
    # types_graph_1().run()

    # Test if nesting Parallels will not loose anything
    r = PD[FindMin, FindMax, PD[FindMean, FindMedian]]()
    r.run()

    # Airflow Syntax

    types_graph_2 = (
        DT[Initialize]()
        >> LoadData()
        >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    print("[TYPES GRAPH 2]...")
    _ = types_graph_2^
    # types_graph_2.run()

    # runner.run()
