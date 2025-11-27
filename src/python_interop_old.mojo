from runtime.asyncrt import TaskGroup, _run
from os import abort
from memory import UnsafePointer
from algorithm import sync_parallelize
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder, GILAcquired


@export
fn PyInit_old_mojo_strata() -> PythonObject:
    try:
        var strata = PythonModuleBuilder("old_mojo_strata")
        _ = (
            strata.add_type[PyTask]("PyTask")
            .def_py_init[PyTask.init]()
            .def_method[PyTask.__call__]("__call__", "Trigger the task")
        )
        _ = (
            strata.add_type[PyParallelTask]("PyParallelTask")
            .def_py_init[PyParallelTask.init]()
            .def_method[PyParallelTask.__call__](
                "__call__", "Trigger the tasks contained in the Task Group"
            )
        )
        _ = (
            strata.add_type[PySerialTask]("PySerialTask")
            .def_py_init[PySerialTask.init]()
            .def_method[PySerialTask.__call__](
                "__call__", "Trigger the tasks contained in the Task Group"
            )
        )

        return strata.finalize()
    except e:
        return abort[PythonObject](
            String("failed to create Python module: ", e)
        )


trait PythonCallable:
    alias S: AnyType

    @staticmethod
    def __call__(
        py_self: UnsafePointer[Self.S, MutAnyOrigin], args: PythonObject
    ) -> PythonObject:
        ...


alias PythonTask = PythonCallable & Representable & Movable


# Question: It is possible to initialize with something else than default?
struct PyTask(PythonTask):
    alias S = Self
    var inner: PythonObject

    fn __init__(out self, inner: PythonObject):
        self.inner = inner

    fn __repr__(self) -> String:
        return String("PyTask( inner=", self.inner, " )")

    @staticmethod
    fn init(out self: Self, args: PythonObject, kwargs: PythonObject) raises:
        if len(args) > 0 and "inner" not in kwargs:
            abort[PythonObject](
                String(
                    "invalid arguments for PyTask: ",
                    args,
                    ", ",
                    kwargs,
                    "Please use `inner` as kwarg.",
                )
            )
        self = Self(inner=kwargs["inner"])

    @staticmethod
    def __call__(
        self_ptr: UnsafePointer[Self, MutAnyOrigin], msg: PythonObject
    ) -> PythonObject:
        return self_ptr[].inner(msg)


struct PyParallelTask(PythonTask):
    alias S = Self
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self, task_1: PythonObject, task_2: PythonObject):
        self.task_1 = task_1
        self.task_2 = task_2

    fn __repr__(self) -> String:
        return String(
            "PyParallelTask( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn init(out self: Self, args: PythonObject, kwargs: PythonObject) raises:
        if len(args) > 0 and "task_1" not in kwargs and "task_2" not in kwargs:
            abort[PythonObject](
                String(
                    "invalid arguments for PyParallelTask: ",
                    args,
                    ", ",
                    kwargs,
                    "Please use `task_1` and `task_2` as kwargs.",
                )
            )
        self = Self(task_1=kwargs["task_1"], task_2=kwargs["task_2"])

    @staticmethod
    def __call__(
        self_ptr: UnsafePointer[Self, MutAnyOrigin], msg: PythonObject
    ) -> PythonObject:
        data = [Python.int(1), Python.int(1)]

        # TODO: Turn on again when NO GIL
        # @parameter
        # fn apply(i: Int) raises:
        #     if i == 0:
        #         data[i] = self_ptr[].task_1(msg)
        #     else:
        #         data[i] = self_ptr[].task_2(msg)

        # sync_parallelize[apply](2)

        # Workaround meanwhile.
        self_ptr[].task_1(msg)
        self_ptr[].task_2(msg)

        return Python.tuple(data[0], data[1])


struct PySerialTask(PythonTask):
    alias S = Self
    var task_1: PythonObject
    var task_2: PythonObject

    fn __init__(out self, task_1: PythonObject, task_2: PythonObject):
        self.task_1 = task_1
        self.task_2 = task_2

    fn __repr__(self) -> String:
        return String(
            "PySerialTask( task_1=",
            self.task_1,
            ", task_2=",
            self.task_2,
            " )",
        )

    @staticmethod
    fn init(out self: Self, args: PythonObject, kwargs: PythonObject) raises:
        if len(args) > 0 and "task_1" not in kwargs and "task_2" not in kwargs:
            abort[PythonObject](
                String(
                    "invalid arguments for PySerialTask: ",
                    args,
                    ", ",
                    kwargs,
                    "Please use `task_1` and `task_2` as kwargs.",
                )
            )
        self = Self(task_1=kwargs["task_1"], task_2=kwargs["task_2"])

    @staticmethod
    def __call__(
        self_ptr: UnsafePointer[Self, MutAnyOrigin], message: PythonObject
    ) -> PythonObject:
        first = self_ptr[].task_1(message)
        second = self_ptr[].task_2(first)
        return second
