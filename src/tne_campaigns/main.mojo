from collections.optional import OptionalReg

async fn run(*args: Int, **kwargs: Int) -> Int:
    return args[0]

struct MyTask[R: async fn(*args: Int, **kwargs: Int) -> Int]:
    @staticmethod
    async fn run(*args: Int, **kwargs: Int) -> Int:
        if len(args) == 0:
            return 0
        return await R(args[0])


async fn run_tasks():
    var my_task = await MyTask[run].run(1)
    print("Task output is:", my_task)


fn main():
    run_tasks()()