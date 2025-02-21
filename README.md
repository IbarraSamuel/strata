# move
Series/Parallel Task runner for Mojo.

## Try it
Use the command and follow the move:
```sh
magic run examples
```

## Examples
The only thing needed to execute series/parallel Tasks, is to conform to the `Callable` trait:
```mojo
trait Callable:
    fn __call__(self):
        ...
```
Then, you can use the struct in multiple ways.

Let's create a couple tasks, one that conforms to `Callable`, another one that conforms to `CallableDefaultable`:
```mojo
from time import sleep

# CallableDefaultable
struct MyDefaultTask[name: StringLiteral]:
    fn __init__(out self):
        pass

    fn __call__(self):
        print("Task [", name, "] Running...")
        sleep(UInt(1))
```

### Defaultable Examples.
Since structs that conform to `Defaultable` doesn't need arguments to be instanciated, you can instanciate them just before running the `__call__()` method.

Also, we can build our graph in a `lazy` way, just by setting up the types needed as Variadic Parameters in `SeriesDefaultTask` and `ParallelDefaultTask`.

```mojo
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

types_graph = TypesGraph()
# Running the Graph
types_graph()
```

Great! But, what happens if I need to instanciate the structs before?. You can use an airflow like syntax to take the insances and run them.
* `+` means parallel (Can be changed in future.)
* `>>` mean series.
```mojo
defaultables_graph = (
    DT[Initialize]()
    >> LoadData()
    >> DT[FindMin]() + FindMax() + FindMean() + FindMedian()
    >> MergeResults()
)
defaultables_graph()
```

### No Defaultables
for Structs that not conforms to `Defaultable`, we can use a different kind of task Collection.

These tasks don't require the struct to conform to anything but `Callable`.

```mojo
# Callable
struct MyTask[job: StringLiteral]:
    var some_data: String

    fn __init__(out self, owned some_data: StringLiteral):
        self.some_data = some_data

    fn __call__(self):
        print("Running [", job, "]:", self.some_data)
        sleep(UInt(1))
```

We can use the TaskGroup syntax or Airflow syntax. Task groups are better and cleaner when it comes to types.

TaskGroup way:
```mojo
from move.task.model import Task as T, SeriesTask as ST, ParallelTask as PT

init = MyTask["Initialize"]("Setting up...")
load = MyTask["Load Data"]("Reading from some place...")
find_min = MyTask["Min"]("Calculating...")
find_max = MyTask["Max"]("Calculating...")
find_mean = MyTask["Mean"]("Calculating...")
find_median = MyTask["Median"]("Calculating...")
merge_results = MyTask["Merge Results"]("Getting all together...")

# Using TaskGroup syntax
graph_1 = ST(
    init,
    load,
    PT(find_min, find_max, find_mean, find_median),
    merge_results,
)
# Running graph
graph_1()
```

Airflow way:
```mojo
graph_2 = (
    T(init)
    >> load
    >> T(find_min) + find_max + find_mean + find_median
    >> merge_results
)
print("[GRAPH 2]...")
graph_2()
```

### Why needs to use `Task` and `DefaultTask` in Airflow Syntax?
In airflow syntax you can see some `T(task)` on non-defaultables and `DT(task)` for defaultables.

The reason is because airflow syntax relies on the `__add__` and `__rshift__` and since those Callable struct didn't implement the operator, we need to
wrap those tasks into a `Task` or `DefaultTask` to be able to do these two operations.

If the first task of the group is converted to a `Task`, the rest can be combined.

To avoid this, you can implement the `__add__` and `__rshift__` methods on your structs.

Something like:

```mojo
fn __add__[
    s: Origin, o: Origin, t: Callable, //
](ref [s]self, ref [o]other: t) -> OwnedTask[
    ParallelTaskPair[s, o, Self, t]
]:
    return OwnedTask(ParallelTaskPair(self, other))

fn __rshift__[
    s: Origin, o: Origin, t: Callable, //
](ref [s]self, ref [o]other: t) -> OwnedTask[
    SeriesTaskPair[s, o, Self, t]
]:
    return OwnedTask(SeriesTaskPair(self, other))
```

## TODO:
Fix problem with Variadic Arguments when trying to use it directly.
