from time import sleep


# Just ensure your struct has fn __call__(mut self):
struct MyTask[name: StringLiteral]:
    var value: Int

    fn __init__(out self, value: Int):
        self.value = value

    fn __call__(mut self):
        self.value += 1
        sleep(0.5)
        print("Finish [", name, "]: Value incremented. Now it's", self.value)


fn main():
    from move import MutableTask as MT

    initial = MyTask["Initial"](0)
    group1_1 = MyTask["Group 1 First"](10)
    group1_2 = MyTask["Group 1 Second"](11)
    group2_1 = MyTask["Group 2 First"](20)
    group2_2 = MyTask["Group 2 Second"](21)
    final = MyTask["Final"](3)

    # The easier way is to call runners directly
    mutable_graph = (
        MT(initial)
        >> (MT(group1_1) >> group1_2) + (MT(group2_1) >> group2_2)
        >> final
    )

    # NOTE: Big graphs can crash the compiler with no aparent reason and no errors.

    print("Hey! Running Mutable Examples...")
    mutable_graph()
    print("The final value for final is:", final.value)
