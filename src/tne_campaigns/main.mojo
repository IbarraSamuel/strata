from collections.optional import OptionalReg
from task.model import run, IsTask


@value
struct MyTask(IsTask):
    fn run(self) -> None:
        print("Running My Task")


@value
struct MySecondTask(IsTask):
    fn run(self) -> None:
        print("Running My Second Task")


# TODO: Generalize to be able to use anytype on the runner. Now all tasks need to have the same type, and isn't a good implementation


fn main():
    var task = MyTask()
    var task2 = MySecondTask()
    var first_group = List(task, task, task, task, task, task, task, task)
    run(first_tasks=first_group)
