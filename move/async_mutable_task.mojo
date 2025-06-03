from runtime.asyncrt import (
    TaskGroupContext,
    AnyCoroutine,
    TaskGroup,
    _Chain,
    _del_asyncrt_chain,
    _run as execute,
)

from memory.unsafe_pointer import UnsafePointer


trait AsyncCallable:
    async fn __call__(mut self):
        ...


# struct Par(Movable, Copyable):
#     var group: UnsafePointer[TaskGroup]

#     fn __init__(out self, mut group: TaskGroup):
#         self.group = UnsafePointer[TaskGroup, origin = __origin_of(group)](
#             to=group
#         )

#     @implicit
#     fn __init__[t: AsyncCallable](out self, mut task: t):
#         self = Self()
#         self.add_task(task)

#     @implicit
#     fn __init__(out self, owned tasks: Seq):
#         if len(tasks.tasks) == 1:
#             self = tasks.tasks[0]
#             return

#         self = Self()
#         self.group[].create_task(tasks._exec())

#     fn __init__(out self, owned *tsks: Seq, __set_literal__: () = ()):
#         self = Self()
#         for ref task in tsks:
#             self.group[].create_task(task._exec())

#     fn add_task[t: AsyncCallable](self, mut task: t):
#         self.group[].create_task(task())

#     fn __add__[t: AsyncCallable](self, mut other: t) -> Par:
#         self.add_task(other)
#         return self

#     fn __add__(self, other: Seq) -> Par:
#         self.group[].create_task(other._exec())
#         return self

#     fn __rshift__[t: AsyncCallable](self, mut other: t) -> Seq:
#         tasks = Seq(self)
#         tasks.add_task(other)
#         return tasks^

#     async fn _exec(self):
#         await self.group[]

#     fn run(self):
#         execute(self._exec())


# struct Seq(Movable):
#     var tasks: Tasks

#     @implicit
#     fn __init__(out self, group: Par):
#         self.tasks = [group]

#     @implicit
#     fn __init__[t: AsyncCallable](out self, mut task: t):
#         self.tasks = [Par(task)]

#     @implicit
#     fn __init__(out self, *args: AsyncCallable, __list_literal__: () = ()):
#         self.tasks = Tasks()
#         for p in args:
#             self.tasks.append(p^)

#     fn add_task[t: AsyncCallable](mut self, mut task: t):
#         tg = Par(task)
#         self.tasks.append(tg^)

#     fn __add__[t: AsyncCallable](owned self, mut other: t) -> Par:
#         tg = Par(self^)
#         tg.add_task(other)
#         return tg^

#     fn __rshift__[t: AsyncCallable](owned self, mut other: t) -> Seq:
#         self.add_task(other)
#         return self^

#     fn __rshift__(owned self, owned other: Par) -> Seq:
#         self.tasks.append(other)
#         return self^

#     async fn _exec(self):
#         for ref t in self.tasks:
#             await t._exec()

#     fn run(self):
#         execute(self._exec())

struct Task(Movable):
    var inner: AnyCoroutine

    @implicit
    fn __init__[t: AsyncCallable](out self, handle: AnyCoroutine):
        self.inner = handle

    fn __del__(owned self):
       __mlir_op.`co.destroy`(self.inner)

struct Tasks(Movable):
    var storage: List[AnyCoroutine]

    fn __init__(out self):
        self.storage = []

    @implicit
    fn __init__[t: AsyncCallable](out self, mut task: t):
        self = Self()
        self.add_task(task)
    
    fn add_task[t: AsyncCallable](mut self, mut task: t):
        self.storage.append(task.__call__()._handle) 

    # @implicit
    # fn __init__(out self, *args: Par, __list_literal__: () = ()):
    #     self.tasks = List[Par]()
    #     for p in args:
    #         self.tasks.append(p^)

    # # fn add_task[t: AsyncCallable](mut self, mut task: t):
    # #     tg = Par(task)
    # #     self.tasks.append(tg^)

    # fn __add__[t: AsyncCallable](owned self, mut other: t) -> Par:
    #     tg = Par(self^)
    #     tg.add_task(other)
    #     return tg^

    # fn __rshift__[t: AsyncCallable](owned self, mut other: t) -> Seq:
    #     self.add_task(other)
    #     return self^

    # fn __rshift__(owned self, owned other: Par) -> Seq:
    #     self.tasks.append(other)
    #     return self^

    # async fn _exec(self):
    #     for ref t in self.tasks:
    #         await t._exec()

    # fn run(self):
    #     execute(self._exec())

