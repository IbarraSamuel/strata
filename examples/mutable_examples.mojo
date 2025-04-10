from time import sleep
from move.callable import Callable, MutableCallable


trait TaskWithValue(MutableCallable):
    fn get_value(self) -> Int:
        ...


struct InitTask[name: String = "Init"](TaskWithValue):
    var value: Int

    fn __init__(out self, value: Int):
        self.value = value

    fn __call__(mut self):
        print("Starting [", name, "Task]: Setting up time!...")
        self.value = 0
        sleep(0.5)
        print("Finishing [", name, "Task]: The value is:", self.value)

    fn get_value(self) -> Int:
        return self.value


# Just ensure your struct has fn __call__(mut self):
struct MyTask[name: StringLiteral, t: TaskWithValue, o: ImmutableOrigin](
    MutableCallable
):
    var task: Pointer[t, o]
    var value: Int
    var additional: Int

    fn __init__(out self, ref [o]task: t, additional: Int):
        self.task = Pointer(to=task)
        self.additional = additional
        self.value = 0

    fn __call__(mut self):
        print(
            "Starting [", name, "]: Now the value is", self.task[].get_value()
        )
        self.value = self.task[].get_value() + 1
        sleep(0.5)
        print("Finishing [", name, "]: Now the value is", self.value)

    fn get_value(self) -> Int:
        return self.value


struct CollectResults[
    t1: TaskWithValue,
    t2: TaskWithValue,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](MutableCallable):
    var result_1: Pointer[t1, o1]
    var result_2: Pointer[t2, o2]
    var value: Int

    fn __init__(out self, ref [o1]r1: t1, ref [o2]r2: t2):
        self.result_1 = Pointer(to=r1)
        self.result_2 = Pointer(to=r2)
        self.value = 0

    fn __call__(mut self):
        r1 = self.result_1[].get_value()
        r2 = self.result_2[].get_value()
        print("Collecting results:", r1, "from group_1 and", r2, "from group_2")
        self.value = r1 * r2
        sleep(0.5)
        print("Final value is:", self.value)


fn main():
    # Type syntax. Not so flexible because we cannot mix owned / mut refs in Variadic Inputs.
    # * Some need to be owned because those groups will not have origin.
    # * Some need to be mutrefs because we just want to run the function, but not transfer anything.
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

    # Airflow Syntax. We solve all these problems.
    # You can just wrap the initial struct with a MutableTask and do operations.

    # For tasks with independent values:
    from move.task import TaskRef as T

    task1 = InitTask["first"](0)
    task2 = InitTask["second parallel 1"](0)
    task3 = InitTask["second parallel 2"](0)
    task4 = InitTask["last"](0)

    print()
    graph = T(task1) >> T(task2) + task3 >> task4
    print("\n\nHey! Running Mutable Examples (No cross Reference)...")
    graph()

    # Task with cross reference (one refers to other) needs to be unsafe.

    initial = InitTask(0)
    group1_1 = MyTask["Group 1 First"](initial, 10)
    group1_2 = MyTask["Group 1 Second"](group1_1, 11)
    group2_1 = MyTask["Group 2 First"](initial, 20)
    group2_2 = MyTask["Group 2 Second"](group2_1, 21)
    final = CollectResults(group1_2, group2_2)

    from move.task import UnsafeTaskRef as UT

    mutable_graph = (
        UT(initial)
        >> (UT(group1_1) >> group1_2) + (UT(group2_1) >> group2_2)
        >> final
    )

    # NOTE: Big graphs can crash the compiler with no aparent reason and no errors.
    print("\n\nHey! Running Mutable Examples (With cross Reference)...")
    mutable_graph()
    print("The final value for final is:", final.value)
