from algorithm import sync_parallelize

from os import abort
from memory import UnsafePointer
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder, TypeIdentifiable


@export
fn PyInit_mojo_move() -> PythonObject:
    try:
        var move = PythonModuleBuilder("mojo_move")
        _ = (
            move.add_type[PyTask]("PyTask")
            .def_method[PyTask._build]("_build")
            .def_method[PyTask.__call__]("__call__")
        )

        _ = (
            move.add_type[PyParallelTask]("PyParallelTask")
            .def_method[PyParallelTask._build]("_build")
            .def_method[PyParallelTask.__call__]("__call__")
        )
        _ = (
            move.add_type[PySerialTask]("PySerialTask")
            .def_method[PySerialTask._build]("_build")
            .def_method[PySerialTask.__call__]("__call__")
        )

        return move.finalize()
    except e:
        return abort[PythonObject](
            String("failed to create Python module: ", e)
        )


trait PythonCallable:
    @staticmethod
    def __call__(py_self: PythonObject, args: PythonObject) -> PythonObject:
        ...


alias PythonTask = PythonCallable & TypeIdentifiable & Representable & Defaultable & Movable


# Question: It is possible to initialize with something else than default?
struct PyTask(PythonTask):
    alias TYPE_ID = "move.PyTask"
    var inner: PythonObject

    fn __init__(out self):
        self.inner = PythonObject()

    fn __repr__(self) -> String:
        return String(Self.TYPE_ID, "( inner=", self.inner, " )")

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn _build(py_self: PythonObject, task: PythonObject) raises:
        self = Self._get_self_ptr(py_self)
        self[].inner = task

    @staticmethod
    def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
        self = Self._get_self_ptr(py_self)
        return self[].inner(message)


struct PyParallelTask(PythonTask):
    alias TYPE_ID = "move.PyParallelTask"
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self):
        self.task_1 = PythonObject()
        self.task_2 = PythonObject()

    fn __repr__(self) -> String:
        return String(
            Self.TYPE_ID,
            "( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn _build(
        py_self: PythonObject, task_1: PythonObject, task_2: PythonObject
    ) raises:
        self = Self._get_self_ptr(py_self)
        self[].task_1 = task_1
        self[].task_2 = task_2

    @staticmethod
    def __call__(py_self: PythonObject, message: PythonObject) -> PythonObject:
        self = Self._get_self_ptr(py_self)

        alias size = 2
        var msgs: PythonObject = [PythonObject(), PythonObject()]

        @parameter
        fn append_msg(i: Int) raises:
            @parameter
            for ti in range(size):

                @parameter
                if ti == 0:
                    msgs[0] = self[].task_1(message)
                else:
                    msgs[1] = self[].task_2(message)

        sync_parallelize[append_msg](size)
        return Python.tuple(msgs[0], msgs[1])


struct PySerialTask(PythonTask):
    alias TYPE_ID = "move.PySerialTask"
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self):
        self.task_1 = PythonObject()
        self.task_2 = PythonObject()

    fn __repr__(self) -> String:
        return String(
            Self.TYPE_ID,
            "( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn _get_self_ptr(py_self: PythonObject) raises -> UnsafePointer[Self]:
        return py_self.downcast_value_ptr[Self]()

    @staticmethod
    fn _build(
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
