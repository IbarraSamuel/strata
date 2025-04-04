from time import sleep
from move.callable import Callable


trait TaskWithValue(Callable):
    fn get_value(self) -> Int:
        ...


struct InitTask:
    var value: Int

    fn __init__(out self):
        self.value = 0

    fn __call__(mut self):
        print("Starting [Init Task]: Setting up time!...")
        self.value = 0
        sleep(0.5)
        print("Finishing [Init Task]: The value is:", self.value)

    fn get_value(self) -> Int:
        return self.value


# Just ensure your struct has fn __call__(mut self):
struct MyTask[name: StringLiteral, t: TaskWithValue, o: ImmutableOrigin]:
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
        print(
            "Finishing [", name, "]: Now the value is", self.task[].get_value()
        )

    fn get_value(self) -> Int:
        return self.value


fn main():
    print("\n\nHey! Running Mutable Examples...")

    initial = InitTask()
    group1_1 = MyTask["Group 1 First"](initial, 10)
    group1_2 = MyTask["Group 1 Second"](group1_1, 11)
    group2_1 = MyTask["Group 2 First"](initial, 20)
    group2_2 = MyTask["Group 2 Second"](group2_1, 21)
    final = MyTask["Final"](group1_2, 3)

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
    from move.task.immutable import ImmTask as T, MutTaskRef

    init = MutTaskRef(initial)
    g1_1 = MutTaskRef(group1_1)
    g1_2 = MutTaskRef(group1_2)
    g2_1 = MutTaskRef(group2_1)
    g2_2 = MutTaskRef(group2_2)
    fin = MutTaskRef(final)

    mutable_graph = T(init) >> (T(g1_1) >> g1_2) + (T(g2_1) >> g2_2) >> fin

    # NOTE: Big graphs can crash the compiler with no aparent reason and no errors.

    mutable_graph()
    print("The final value for final is:", final.value)
