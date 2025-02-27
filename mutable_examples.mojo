from time import sleep


# Just ensure your struct has fn __call__(mut self):
struct MyTask[name: StringLiteral]:
    var value: Int

    fn __init__(out self, value: Int):
        self.value = value

    fn __call__(mut self):
        print("Starting [", name, "]: Now the value is", self.value)
        self.value += 1
        sleep(0.5)
        print("Finishing [", name, "]: Now the value is", self.value)


fn main():
    print("Hey! Running Mutable Examples...")

    initial = MyTask["Initial"](0)
    group1_1 = MyTask["Group 1 First"](10)
    group1_2 = MyTask["Group 1 Second"](11)
    group2_1 = MyTask["Group 2 First"](20)
    group2_2 = MyTask["Group 2 Second"](21)
    final = MyTask["Final"](3)

    # Type syntax. Not so flexible because we cannot mix owned / mut refs in Variadic Inputs.
    # Needs to be one or the other. So, we can: transfer or declare groups and reference those groups.
    from move import ParallelMutableTask as PM, SeriesMutableTask as SM

    # This is needed because each group needs to be mutable.
    # To do that, those should exists somewhere. Cannot be Annonymous.
    # Other way is making the groups to own the values but this will make things difficult when you need to keep track of the changes on the structs.
    # NOTE: This is currently not working. Maybe it's because of a lot of castings and magic.
    # group1 = SM(group1_1, group1_2)
    # group2 = SM(group2_1, group2_2)
    # groups = PM(group1, group2)
    # mutable_type_graph = SM(initial, groups, final)

    # mutable_type_graph()

    # Airflow Syntax. We solve all these problems.
    # You can just wrap the initial struct with a MutableTask and do operations.
    from move import MutableTask as MT

    mutable_graph = (
        MT(initial)
        >> (MT(group1_1) >> group1_2) + (MT(group2_1) >> group2_2)
        >> final
    )

    # NOTE: Big graphs can crash the compiler with no aparent reason and no errors.

    mutable_graph()
    print("The final value for final is:", final.value)
