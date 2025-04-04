struct Task1:
    var value: Int

    fn __init__(out self):
        self.value = 0

    fn mut_something(mut self):
        pass


struct Task2[o: Origin[False]]:
    var taskref: Pointer[Task1, o]

    fn __init__(out self, ref [o]task: Task1):
        self.taskref = Pointer(to=task)

    fn mut_something(mut self):
        pass


struct GroupTask[o: Origin[False], o2: Origin[False]]:
    var task1: Pointer[Task1, o]
    var task2: Pointer[Task2[o], o2]

    fn __init__(out self, ref [o]task: Task1, ref [o2]task2: Task2[o]):
        self.task1 = Pointer(to=task)
        self.task2 = Pointer(to=task2)

    fn mut_something(mut self):
        pass


fn main():
    t1 = Task1()
    t2 = Task2(t1)
    tg = GroupTask(
        t1, t2
    )  # The error is fine, is showing a problem I can have in the future
