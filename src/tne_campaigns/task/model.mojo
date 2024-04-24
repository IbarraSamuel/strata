from builtin.coroutine import Coroutine
from collections.optional import OptionalReg
alias TaskOut = UInt32


struct Task[task_id: StringLiteral, T: AnyRegType, R: async fn(*args: T, **kwargs: T) -> T]():
    var id: StringLiteral

    async fn __init__(inout self) -> None:
        self.id = task_id

    async fn run(self, *args: T, **kwargs: T) -> OptionalReg[T]:
        print("Running task", self.task_id, "with arguments len", len(args), "and kwargs len", len(kwargs))
        if len(args) == 0:
            return None
        else:
            var arg = await R(args[0])
            return OptionalReg[T](arg)


async fn run[T: AnyRegType](*args: T, **kwargs: T) -> T:
    return args[0]


async fn run_tasks():
    var task = Task["example_task", TaskOut, run[TaskOut]]()
    var out = await task.run(4)
    print("Task output is:", out.value())
    # print(run(1)())
    # print(run[Float64](1.2)())
