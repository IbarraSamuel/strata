from time import sleep

# Tasks


@value
struct Initialize:
    fn run(self):
        print("Initializing...")
        sleep(UInt(1))


@value
struct LoadData:
    fn run(self):
        print("Loading Data...")
        sleep(UInt(1))


@value
struct FindMax:
    fn run(self):
        print("Finding Max Value...")
        sleep(UInt(1))


@value
struct FindMean:
    fn run(self):
        print("Finding Mean Value...")
        sleep(UInt(1))


@value
struct Merge:
    fn run(self):
        print("Merging the Data...")
        sleep(UInt(1))


fn main():
    # Run time values...
    from task.model import Task as T, SeriesTask as ST

    init = Initialize()
    load = LoadData()
    findmax = FindMax()
    findmean = FindMean()
    merge = Merge()

    graph0 = T(init) >> load >> T(findmax) + findmean >> merge

    # Runtime tasks.
    print("Running the Graph...")
    graph0.run()

    # If the tasks are defaultable, you can compile time them.

    from task.model import (
        ParallelDefaultTask as PD,
        SeriesDefaultTask as SD,
        DefaultTask as DT,
    )

    alias graph = SD[Initialize, LoadData, PD[FindMax, FindMean], Merge]
    print("Running the Graph...")
    graph().run()

    print("Running the Graph2 using kind of airflow syntax...")
    graph2 = (
        DT[Initialize]() >> LoadData() >> DT[FindMax]() + FindMean() >> Merge()
    )
    graph2.run()

    # runner.run()
