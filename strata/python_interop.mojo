from runtime.asyncrt import TaskGroup, _run
from os import abort
from memory import UnsafePointer
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder


@export
fn PyInit_mojo_strata() -> PythonObject:
    try:
        var strata = PythonModuleBuilder("mojo_strata")
        _ = (
            strata.add_type[PyTask]("PyTask")
            .def_method[PyTask.build]("build")
            .def_method[PyTask.__call__]("__call__")
        )
        _ = (
            strata.add_type[PyParallelTask]("PyParallelTask")
            .def_method[PyParallelTask.build]("build")
            .def_method[PyParallelTask.__call__]("__call__")
        )
        _ = (
            strata.add_type[PySerialTask]("PySerialTask")
            .def_method[PySerialTask.build]("build")
            .def_method[PySerialTask.__call__]("__call__")
        )

        return strata.finalize()
    except e:
        return abort[PythonObject](
            String("failed to create Python module: ", e)
        )


trait PythonCallable:
    @staticmethod
    def __call__(py_self: PythonObject, args: PythonObject) -> PythonObject:
        ...


alias PythonTask = PythonCallable & Representable & Defaultable & Movable


# Question: It is possible to initialize with something else than default?
struct PyTask(PythonTask):
    var inner: PythonObject

    fn __init__(out self):
        self.inner = PythonObject()

    fn __repr__(self) -> String:
        return String("PyTask( inner=", self.inner, " )")

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn build(py_self: PythonObject, task: PythonObject) raises:
        self = Self._get_self_ptr(py_self)
        self[].inner = task

    @staticmethod
    def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
        self = Self._get_self_ptr(py_self)
        return self[].inner(message)


struct PyParallelTask(PythonTask):
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self):
        self.task_1 = PythonObject()
        self.task_2 = PythonObject()

    fn __repr__(self) -> String:
        return String(
            "PyParallelTask( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn build(
        py_self: PythonObject, task_1: PythonObject, task_2: PythonObject
    ) raises:
        self = Self._get_self_ptr(py_self)
        self[].task_1 = task_1
        self[].task_2 = task_2

    @staticmethod
    def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
        self = Self._get_self_ptr(py_self)

        # t1, m1 = self[].task_1.copy(), message.copy()
        # t2, m2 = self[].task_2.copy(), message.copy()

        data = [Python.int(1), Python.int(1)]

        @parameter
        fn apply[i: Int]():
            try:

                @parameter
                if i == 0:
                    data[i] = self[].task_1(message)
                else:
                    data[i] = self[].task_2(message)
            except e:
                print(e)

        apply[0]()
        apply[1]()
        # tg = TaskGroup()
        # tg.create_task(apply[0]())
        # tg.create_task(apply[1]())

        # @parameter
        # async fn run():
        #     await tg

        # _run(run())

        # @parameter
        # fn append_msg(i: Int) raises:
        #     if i == 0:
        #         r1 = t1(m1)
        #     else:
        #         r2 = t2(m2)

        # sync_parallelize[append_msg](2)
        return Python.tuple(data[0], data[1])


struct PySerialTask(PythonTask):
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self):
        self.task_1 = PythonObject()
        self.task_2 = PythonObject()

    fn __repr__(self) -> String:
        return String(
            "PySerialTask( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn build(
        py_self: PythonObject, task_1: PythonObject, task_2: PythonObject
    ) raises:
        self = Self._get_self_ptr(py_self)
        self[].task_1 = task_1
        self[].task_2 = task_2

    @staticmethod
    def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
        self = Self._get_self_ptr(py_self)
        first = self[].task_1(message)
        second = self[].task_2(first)
        return second
