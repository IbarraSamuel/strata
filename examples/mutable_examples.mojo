from time import sleep
from move.mutable import MutCallable

alias time = 0.1


struct InitTask[name: String = "Init"](MutCallable):
    var value: Int

    fn __init__(out self, value: Int):
        self.value = value

    fn __call__(mut self):
        print("Starting [", name, "Task]: Value is", self.value, "...")
        self.value += 1
        sleep(time)
        print("Finishing [", name, "Task]: The value is:", self.value)


fn main():
    print("\n\nHey! Running Mutable Examples (No cross Reference)...")
    # Type syntax. Not so flexible because we cannot mix owned / mut refs in Variadic Inputs.
    # * Some need to be owned because those groups will not have origin.
    # * Some need to be mutrefs because we want to point to the original struct without using a wrapper to then transfer the wrapper.
    # It needs to be one or the other.
    # To solve it, we can:
    # * Declare a groups of Mut Ref structs into a variable.
    # * Refer to this variable using Mut Ref again.

    # Other way is making the groups to own the values but this will make things difficult when you need to keep track of the changes on the structs.
    # from move import ParallelTask as P, SeriesTask as S
    # group1 = S(group1_1, group1_2)
    # group2 = S(group2_1, group2_2)
    # groups = P(group1, group2)
    # mutable_type_graph = S(initial, groups, final)

    # BUG: This is currently not working. Maybe it's because of a lot of castings and magic.
    # I'm storing a VariadicPack inside each group, the VariadicPack should be mutable but not owned and we should be able to transfer it.

    # mutable_type_graph()

    from move.mutable import SeriesTask as ST, ParallelTask as PT

    task1 = InitTask["first"](0)
    task2 = InitTask["second parallel 1"](1)
    task3 = InitTask["second parallel 2"](1)
    task4 = InitTask["last"](2)

    print("Type graph...")
    grp = PT(task2, task3)
    type_graph = ST(task1, grp, task4)
    type_graph()

    # Airflow Syntax. We solve all these problems.
    # You can just wrap the initial struct with a MutableTask and do operations.

    # For tasks with independent values:
    from move.mutable import TaskRef as T

    print("Airflow graph...")
    graph = T(task1) >> T(task2) + task3 >> task4
    graph()

    # NOTE: This will not work if you want to do cross references to other tasks in the graph.
    # If you have this usecase, go to unsafe examples.
