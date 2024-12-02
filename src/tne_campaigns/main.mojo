from collections.optional import OptionalReg
from task.model import run, IsTask, TaskGroup


@value
struct MyTask(IsTask):
    fn run(self) -> None:
        print("Running My Task")


@value
struct MySecondTask(IsTask):
    fn run(self) -> None:
        print("Running My Second Task")


fn main():
    var task = MyTask()
    var task2 = MySecondTask()
    var first_group = TaskGroup(task2)
    var second_group = TaskGroup(task2)
    run(first_tasks=first_group, second_tasks=second_group)
