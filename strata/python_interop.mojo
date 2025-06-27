from os import abort
from memory import OwnedPointer
from python import PythonObject, Python, ConvertibleFromPython
from python.bindings import PythonModuleBuilder, GILAcquired

# from algorithm import parallelize
from runtime.asyncrt import TaskGroup as TG, _run


@export
fn PyInit_mojo_strata() -> PythonObject:
    try:
        var strata = PythonModuleBuilder("mojo_strata")

        _ = (
            strata.add_type[Graph]("Graph")
            .def_method[Graph.call_task](
                "call_task", "Execute the graph and return the result."
            )
            .def_method[Graph.capture_elems](
                "capture_elems", "Capture the tasks in the graph."
            )
        )

        _ = (
            strata.add_type[TaskGroup]("TaskGroup")
            .def_method[TaskGroup.add_task](
                "add_task", "Add a task to the group."
            )
            .def_method[TaskGroup.from_single_task](
                "from_single_task", "Add a single task to the group."
            )
            .def_method[TaskGroup.call]("call", "Make this group callable.")
        )
        # strata.def_function[PyTask]("PyTask")
        # _ = (
        #     strata.add_type[_PyTask]("_PyTask")
        #     # .def_method[PyTask.build]("build")
        #     .def_method[_PyTask.__call__]("__call__")
        # )
        # _ = (
        #     strata.add_type[PyParallelTask]("PyParallelTask")
        #     .def_method[PyParallelTask.build]("build")
        #     .def_method[PyParallelTask.__call__]("__call__")
        # )
        # _ = (
        #     strata.add_type[PySerialTask]("PySerialTask")
        #     .def_method[PySerialTask.build]("build")
        #     .def_method[PySerialTask.__call__]("__call__")
        # )

        return strata.finalize()
    except e:
        return abort[PythonObject](
            String("failed to create Python module: ", e)
        )


trait PythonCallable:
    @staticmethod
    def call_task(py_self: PythonObject, args: PythonObject) -> PythonObject:
        ...


alias PythonType = Representable & Movable & Defaultable


# fn PyTask(task: PythonObject) raises -> PythonObject:
#     return PythonObject(alloc=_PyTask(task))


struct Graph(PythonCallable, PythonType):
    var elems: TaskGroup

    fn __init__(out self):
        self.elems = TaskGroup()

    fn __repr__(self) -> String:
        return String("Graph(...)")

    fn _call(self, v: PythonObject) raises -> PythonObject:
        var cpython = Python().cpython()
        with GILAcquired(cpython):
            return self.elems._call(v)

    fn _capture_elems(mut self, owned elems: TaskGroup) raises:
        self.elems = elems^

    @staticmethod
    fn _get_self(s: PythonObject) -> UnsafePointer[Self]:
        return s.unchecked_downcast_value_ptr[Self]()

    @staticmethod
    fn call_task(s: PythonObject, v: PythonObject) raises -> PythonObject:
        self = Self._get_self(s)
        return self[]._call(v)

    @staticmethod
    fn capture_elems(s: PythonObject, elems: PythonObject) raises:
        self = Self._get_self(s)
        e = elems.downcast_value_ptr[TaskGroup]()
        self[]._capture_elems(e[])


struct TaskGroup(Copyable, PythonType):
    alias undefined = TaskGroup(-1)
    alias Serial = TaskGroup(0)
    alias Parallel = TaskGroup(1)

    var mode: Int
    var objects: List[PythonObject]

    fn __init__(out self):
        self.mode = -1
        self.objects = []

    fn __repr__(self) -> String:
        objs = "[" + String(", ").join(self.objects) + "]"
        mode = (
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel"
        )
        return String("TaskGroup(mode:", mode, ", objects:", objs, ")")

    fn __init__(out self, mode: Int):
        self.mode = mode
        self.objects = []

    fn add(mut self, t: PythonObject, mode: Int) raises:
        if self.mode == Self.undefined.mode:
            self.mode = mode

        if self.mode == mode:
            self.objects.append(t)
            return

        new_group = TaskGroup(mode=mode)
        new_group.objects.append(PythonObject(alloc=self))
        new_group.objects.append(t)
        self = new_group

    fn _call(self, msg: PythonObject) raises -> PythonObject:
        if len(self.objects) == 0:
            return msg

        if self.mode == Self.undefined.mode:
            raise "Group mode not set up"

        print(
            "in mode:",
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel",
        )

        if self.mode == Self.Serial.mode:
            iv = msg
            for obj in self.objects:
                pg = obj._try_downcast_value[TaskGroup]()
                if pg:
                    return pg.value()[]._call(iv)

                iv = pg.__call__(iv)
            print("Done!..")
            return iv  # Before, here we had a tuple

        var values = List[PythonObject](
            length=len(self.objects), fill=PythonObject()
        )

        @parameter
        @always_inline
        fn run_task(i: Int):
            tsk = self.objects.unsafe_get(i)
            grp = tsk._try_downcast_value[TaskGroup]()
            if grp:
                values[i] = grp.value()[]._call(msg)
                return

            try:
                values[i] = tsk.__call__(msg)
            except:
                print("Task Failed!")
                values[i] = PyhtonObject(None)

        @parameter
        @always_inline
        async fn run_async(i: Int):
            run_task(i)

        tg = TG()
        for idx in range(len(self.objects)):
            tg.create_task(run_async(idx))

        tg.wait()

        print("Done!..")
        tp = Python.tuple()
        for res in values:
            tp += Python.tuple(res)
        return tp

    @staticmethod
    fn _get_self(s: PythonObject) -> UnsafePointer[Self]:
        return s.unchecked_downcast_value_ptr[Self]()

    @staticmethod
    fn from_single_task(s: PythonObject, t: PythonObject) raises:
        self = Self._get_self(s)
        self[].objects.append(t)

    @staticmethod
    fn add_task(s: PythonObject, t: PythonObject, _mode: PythonObject) raises:
        self = Self._get_self(s)
        self[].add(t, Int(_mode))

    @staticmethod
    fn call(s: PythonObject, v: PythonObject) raises -> PythonObject:
        self = Self._get_self(s)
        return self[]._call(v)


# Question: It is possible to initialize with something else than default?
# struct _PyTask(ConvertibleFromPython, PythonCallable, PythonType):
#     var inner: PythonObject
#     var msg: Optional[PythonObject]

#     fn __init__(out self):
#         self.inner = PythonObject()
#         self.msg = None

#     # ConvertibleFromPython Trait
#     fn __init__(out self, task: PythonObject) raises:
#         self.inner = task
#         self.msg = None

#     fn __moveinit__(out self, owned other: Self):
#         self.inner = other.inner^
#         self.msg = other.msg^

#     fn __copyinit__(out self, other: Self):
#         self.inner = other.inner
#         self.msg = other.msg

#     # PythonConvertible Trait
#     fn to_python_object(owned self) raises -> PythonObject:
#         return PythonObject(alloc=self^)

#     # PythonType Trait
#     fn __repr__(self) -> String:
#         return String("PyTask(...)")

#     @staticmethod
#     fn _get_self_ptr(py_self: PythonObject) -> UnsafePointer[Self]:
#         return py_self.unchecked_downcast_value_ptr[Self]()

#     # @staticmethod
#     # fn build(py_self: PythonObject, task: PythonObject) raises:
#     #     self = Self._get_self_ptr(py_self)
#     #     self[] = Self(task)
#     #     self[].inner = task

#     # fn call(self, message: PythonObject) raises -> PythonObject:
#     #     return self.inner(message)

#     @staticmethod
#     def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
#         self = Self._get_self_ptr(py_self)
#         return self[].inner(message.copy())


# struct PyParallelTask(PythonTask):
#     var task_1: PythonObject
#     var task_2: PythonObject

#     fn __init__(out self):
#         self.task_1 = PythonObject()
#         self.task_2 = PythonObject()

#     fn __repr__(self) -> String:
#         return String(
#             "PyParallelTask( task_1=",
#             self.task_1,
#             ", task_2=",
#             self.task_2,
#             " )",
#         )

#     @staticmethod
#     fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
#         return py_self.downcast_value_ptr[Self]()

#     @staticmethod
#     fn build(
#         py_self: PythonObject, task_1: PythonObject, task_2: PythonObject
#     ) raises:
#         self = Self._get_self_ptr(py_self)
#         self[].task_1 = task_1
#         self[].task_2 = task_2

#     @staticmethod
#     def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
#         self = Self._get_self_ptr(py_self)

#         # t1, m1 = self[].task_1.copy(), message.copy()
#         # t2, m2 = self[].task_2.copy(), message.copy()

#         data = [Python.int(1), Python.int(1)]

#         @parameter
#         fn apply[i: Int]():
#             try:

#                 @parameter
#                 if i == 0:
#                     data[i] = self[].task_1(message)
#                 else:
#                     data[i] = self[].task_2(message)
#             except e:
#                 print(e)

#         apply[0]()
#         apply[1]()
#         # tg = TaskGroup()
#         # tg.create_task(apply[0]())
#         # tg.create_task(apply[1]())

#         # @parameter
#         # async fn run():
#         #     await tg

#         # _run(run())

#         # @parameter
#         # fn append_msg(i: Int) raises:
#         #     if i == 0:
#         #         r1 = t1(m1)
#         #     else:
#         #         r2 = t2(m2)

#         # sync_parallelize[append_msg](2)
#         return Python.tuple(data[0], data[1])


# struct PySerialTask(PythonTask):
#     var task_1: PythonObject
#     var task_2: PythonObject

#     fn __init__(out self):
#         self.task_1 = PythonObject()
#         self.task_2 = PythonObject()

#     fn __repr__(self) -> String:
#         return String(
#             "PySerialTask( task_1=",
#             self.task_1,
#             ", task_2=",
#             self.task_2,
#             " )",
#         )

#     @staticmethod
#     fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
#         return py_self.downcast_value_ptr[Self]()

#     @staticmethod
#     fn build(
#         py_self: PythonObject, task_1: PythonObject, task_2: PythonObject
#     ) raises:
#         self = Self._get_self_ptr(py_self)
#         self[].task_1 = task_1
#         self[].task_2 = task_2

#     @staticmethod
#     def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
#         self = Self._get_self_ptr(py_self)
#         first = self[].task_1(message)
#         second = self[].task_2(first)
#         return second
