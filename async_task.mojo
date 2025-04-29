trait AsyncCallable:
    async fn __call__(mut self) -> None:
        pass


from time import sleep
from runtime.asyncrt import Task, TaskGroup, TaskGroupContext, run
from runtime.asyncrt import create_task


# async fn series_runner[*ts: AsyncCallable](mut*args: *ts):
#     alias size = len(VariadicList(ts))

#     @parameter
#     for i in range(size):
#         await args[i]()


async fn ParallelTask[*ts: AsyncCallable](mut*args: *ts):
    alias size = len(VariadicList(ts))

    grp = TaskGroup()

    @parameter
    for i in range(size):
        grp.create_task(args[i]())

    await grp


# struct ParallelTask[*ts: AsyncCallable]:
#     var group: TaskGroup

#     fn __init__(out self, mut*args: *ts):
#         alias size = len(VariadicList(ts))

#         self.group = TaskGroup()

#         @parameter
#         for i in range(size):
#             self.group.create_task(args[i]())

#     async fn __call__(mut self):
#         await self.group


async fn SeriesTask[*ts: AsyncCallable](mut*args: *ts):
    alias size = len(VariadicList(ts))

    @parameter
    for i in range(size):
        await args[i]()


async fn call_1():
    print("Hello World 1!")
    sleep(1.0)
    print("Bye World 1!")


async fn call_2():
    print("Hello World 2!")
    sleep(1.0)
    print("Bye World 2!")


struct FnToCall[o: OriginSet]:
    var func: Coroutine[NoneType, o]

    fn __init__(out self, owned func: Coroutine[NoneType, o]):
        self.func = func^

    async fn __call__(mut self) -> None:
        await self.func^


fn main() raises:
    var fntocall = FnToCall(call_1())
    var graph = SeriesTask(fntocall)
    var gp = TaskGroup()
    gp.create_task(call_1())
    gp.create_task(call_2())
    gp.wait()
