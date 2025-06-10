from strata.unsafe import MutCallable
from time import sleep

alias time = 0.1


trait TaskWithValue(MutCallable):
    fn get_value(self) -> Int:
        ...


struct InitTask[name: String = "Init"](TaskWithValue):
    var value: Int

    fn __init__(out self):
        self.value = 0

    fn __call__(mut self):
        print("Starting [", name, "Task]: Setting up time!...")
        self.value = 0  # reset to zero if the graph is ran again
        sleep(time)
        print("Finishing [", name, "Task]: The value is:", self.value)

    fn get_value(self) -> Int:
        return self.value


# Just ensure your struct has fn __call__(mut self):
struct MyTask[name: StringLiteral, t: TaskWithValue, o: ImmutableOrigin](
    TaskWithValue
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
        sleep(time)
        print("Finishing [", name, "]: Now the value is", self.value)

    fn get_value(self) -> Int:
        return self.value


struct CollectResults[
    t1: TaskWithValue,
    t2: TaskWithValue,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](MutCallable):
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
        sleep(time)
        print("Final value is:", self.value)


fn main():
    # Task with cross reference (one refers to other) needs to be unsafe.
    # Lets say we have this set of tasks:

    print("\n\nHey! Running Mutable Examples (With cross Reference)...")

    initial = InitTask()
    group1_1 = MyTask["Group 1 First"](initial, 10)
    group1_2 = MyTask["Group 1 Second"](group1_1, 11)
    group2_1 = MyTask["Group 2 First"](initial, 20)
    group2_2 = MyTask["Group 2 Second"](group2_1, 21)
    final = CollectResults(group1_2, group2_2)

    # First option is to create Unsafe References for all of them, and then you can use
    # the Immutable API to do everything on those tasks.
    # It's assuming all of them are immutable, so everything will work.

    from strata.unsafe import UnsafeTaskRef as UT

    i = UT(initial)
    g11 = UT(group1_1)
    g12 = UT(group1_2)
    g21 = UT(group2_1)
    g22 = UT(group2_2)
    f = UT(final)

    # Using Immutable Group Types
    from strata.immutable import SeriesTask as S, ParallelTask as P

    print("Type graph...")
    imm_type_graph = S(i, P(S(g11, g12), S(g21, g22)), f)
    imm_type_graph()

    # Using Immutable Ref for airflow Syntax
    # NOTE: This one could cause confution because the UnsafeTaskRef itself contains
    # it's own airflow syntax, and could be mixed up by mistake with the Immutable airflow syntax
    # if you don't properly type the graph
    from strata.immutable import ImmTaskRef as IT

    print("Airflow graph...")
    imm_graph = IT(i) >> (IT(g11) >> g12) + (IT(g21) >> g22) >> f
    imm_graph()

    # If you don't want to take this step first (casting all tasks first and creating
    # those variables just to be able to use it) , then use the unsafe api, just
    # casting the first element in the group. The tasks will be treated as immutable
    # (as before), but you will be able to skip the casting for all elements.
    # WARNING: It could increase compile time.

    # Using unsafe directly
    print("Unsafe airflow graph...")
    mutable_graph = (
        UT(initial)
        >> (UT(group1_1) >> group1_2) + (UT(group2_1) >> group2_2)
        >> final
    )
    mutable_graph()
