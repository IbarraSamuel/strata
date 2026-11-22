"""Python interoperability module for task group execution."""

from std.os import abort
from std.python import PythonObject, Python
from std.python._cpython import (
    GILReleased,
    GILAcquired,
    PyObjectPtr,
    Py_ssize_t,
)
from std.runtime._asyncrt import TaskGroup as TG
from std.python.bindings import PythonModuleBuilder


struct _CallResult(Movable):
    """Internal result holding either a Python value or a captured exception."""

    var value: PythonObject
    var error: Optional[PythonObject]

    def __init__(out self, var value: PythonObject):
        self.value = value^
        self.error = None

    def __init__(out self, *, var error: PythonObject):
        self.value = PythonObject()
        self.error = error^


def _invoke_py(task: PythonObject, msg: PythonObject) -> _CallResult:
    """Invoke a Python callable or nested TaskGroup while preserving exceptions.

    Must be called while holding the GIL.
    """
    try:
        if case .Some(grp_ptr) = task._try_downcast_value[TaskGroup]():
            return grp_ptr[]._call_result(msg)
    except:
        pass

    ref cpython = Python().cpython()
    var args_ptr = cpython.PyTuple_New(1)
    if not args_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))

    var msg_owned = msg
    _ = cpython.PyTuple_SetItem(args_ptr, 0, msg_owned^.steal_data())
    var args = PythonObject(from_owned=args_ptr)

    var res_ptr = cpython.PyObject_CallObject(task._obj_ptr, args._obj_ptr)
    if not res_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))

    return _CallResult(PythonObject(from_owned=res_ptr))


def _restore_python_exception(var exc: PythonObject) -> PythonObject:
    """Set CPython's error indicator to `exc` and return a NULL PythonObject.

    Must be called while holding the GIL right before returning to CPython.
    """
    ref cpython = Python().cpython()
    try:
        var builtins = Python.import_module("builtins")
        var exc_type = builtins.type(exc)
        var exc_tb = exc.__traceback__
        var tb_ptr = PyObjectPtr()
        if exc_tb._obj_ptr != Python.none()._obj_ptr:
            tb_ptr = exc_tb^.steal_data()
        cpython.PyErr_Restore(
            exc_type^.steal_data(),
            exc^.steal_data(),
            tb_ptr,
        )
        return PythonObject(from_owned=PyObjectPtr())
    except:
        var err_type = cpython.get_error_global("PyExc_RuntimeError")
        var fallback_msg = String("Failed to propagate Python exception")
        cpython.PyErr_SetString(err_type, fallback_msg.as_c_string_span().ptr())
        return PythonObject(from_owned=PyObjectPtr())


__async def _run_async_task(
    task_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    msg_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    out_ptr: Pointer[PythonObject, MutUntrackedOrigin],
    err_ptr: Pointer[Optional[PythonObject], MutUntrackedOrigin],
):
    with GILAcquired(Python()):
        var res = _invoke_py(task_ptr[], msg_ptr[])
        if case .Some(exc) = res.error:
            err_ptr[] = exc
        else:
            out_ptr[] = res.value


@export
def PyInit_mojo_strata() abi("C") -> PythonObject:
    """Initialize the CPython extension module for mojo_strata.

    Returns:
        The initialized Python module object.
    """
    try:
        var strata = PythonModuleBuilder("mojo_strata")

        _ = (
            strata.add_type[TaskGroup]("mojo_strata.TaskGroup")
            .def_py_init[TaskGroup.py_init]()
            .def_method[TaskGroup.with_task](
                "with_task",
                "Return a new TaskGroup with an additional task without mutating self.",
            )
            .def_method[TaskGroup.call]("call", "Execute this task group.")
        )

        var mod = strata.finalize()
        var tg_type = mod.__getattr__("mojo_strata.TaskGroup")
        mod.TaskGroup = tg_type
        _ = Python.import_module("builtins").delattr(
            mod, "mojo_strata.TaskGroup"
        )
        return mod
    except e:
        abort(String("failed to create Python module: ", e))


struct TaskGroup(Movable, Writable):
    """Python-interoperable task group managing serial or parallel task pipelines."""

    comptime undefined = TaskGroup(-1)
    """Undefined group mode constant."""
    comptime Serial = TaskGroup(0)
    """Serial execution group mode constant."""
    comptime Parallel = TaskGroup(1)
    """Parallel execution group mode constant."""

    var mode: Int
    """Execution mode of the task group (-1: undefined, 0: serial, 1: parallel)."""
    var objects: List[PythonObject]
    """List of task PythonObjects in the group."""

    def __init__(out self, task: PythonObject):
        """Construct a TaskGroup with a single initial task.

        Args:
            task: Initial Python task object.
        """
        self.mode = -1
        self.objects = [task]

    def __init__(out self, mode: Int):
        """Construct an empty TaskGroup with a specific execution mode.

        Args:
            mode: Mode integer (0 for serial, 1 for parallel).
        """
        self.mode = mode
        self.objects = []

    def copy(self, out o: Self):
        """Copy the TaskGroup.

        Returns:
            A cloned copy of this TaskGroup.
        """
        o = Self(mode=self.mode)
        o.objects = self.objects.copy()

    def __repr__(self) -> String:
        """Return string representation of the TaskGroup.

        Returns:
            A string describing mode and contained tasks.
        """
        var objs = "[" + String(", ").join(self.objects) + "]"
        var mode = (
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel"
        )
        return String("TaskGroup(mode:", mode, ", objects:", objs, ")")

    def _add_task(mut self, t: PythonObject, mode: Int) raises:
        if self.mode == Self.undefined.mode:
            self.mode = mode

        if self.mode == mode:
            self.objects.append(t)
            return

        var new_group = TaskGroup(mode=mode)
        new_group.objects.append(PythonObject(alloc=self.copy()))
        new_group.objects.append(t)
        self = new_group^

    def _with_task(self, t: PythonObject, mode: Int) raises -> Self:
        var cloned = self.copy()
        cloned._add_task(t, mode)
        return cloned^

    def _call_result(self, msg: PythonObject) -> _CallResult:
        var count = len(self.objects)
        if count == 0:
            return _CallResult(msg)

        if self.mode == Self.undefined.mode:
            if count == 1:
                return _invoke_py(self.objects[0], msg)
            try:
                var builtins = Python.import_module("builtins")
                return _CallResult(
                    error=builtins.ValueError("Group mode not set up")
                )
            except:
                return _CallResult(msg)

        if self.mode == Self.Serial.mode:
            var iv = msg
            for obj in self.objects:
                var res = _invoke_py(obj, iv)
                if case .Some(exc) = res.error:
                    return _CallResult(error=exc)
                iv = res.value
            return _CallResult(iv^)

        var values = List[PythonObject](length=count, fill=PythonObject())
        var errors = List[Optional[PythonObject]](length=count, fill=None)

        var tg = TG()
        var msg_ptr = Pointer(to=msg).unsafe_origin_cast[ImmUntrackedOrigin]()

        for idx in range(count):
            var t_ptr = Pointer(to=self.objects[idx]).unsafe_origin_cast[
                ImmUntrackedOrigin
            ]()
            var out_ptr = Pointer(to=values[idx]).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            var err_ptr = Pointer(to=errors[idx]).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            tg.create_task(_run_async_task(t_ptr, msg_ptr, out_ptr, err_ptr))

        with GILReleased(Python()):
            tg.wait()

        var failed = List[PythonObject]()
        for idx in range(count):
            if case .Some(exc) = errors[idx]:
                failed.append(exc)

        if len(failed) == 1:
            return _CallResult(error=failed[0])
        if len(failed) > 1:
            try:
                var builtins = Python.import_module("builtins")
                var py_errs = Python.list()
                for exc in failed:
                    _ = py_errs.append(exc)
                var group = builtins.BaseExceptionGroup(
                    "Parallel task failures", py_errs
                )
                return _CallResult(error=group^)
            except:
                return _CallResult(error=failed[0])

        ref cpython = Python().cpython()
        var tp_ptr = cpython.PyTuple_New(Py_ssize_t(count))
        if not tp_ptr:
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _CallResult(error=PythonObject(from_owned=exc_ptr))
        for idx in range(count):
            var item = values[idx]
            _ = cpython.PyTuple_SetItem(
                tp_ptr, Py_ssize_t(idx), item^.steal_data()
            )
        return _CallResult(PythonObject(from_owned=tp_ptr))

    @staticmethod
    def py_init(
        out self: Self, args: PythonObject, kwargs: PythonObject
    ) raises:
        """Initialize from Python arguments.

        Args:
            args: Positional Python arguments.
            kwargs: Keyword Python arguments.

        Returns:
            The initialized TaskGroup.

        Raises:
            Error if invalid arguments are passed.
        """
        if len(args) != 1 and PythonObject("task") not in kwargs:
            raise "Bad arguments."

        var task_obj = (
            args[0] if len(args) == 1 else kwargs[PythonObject("task")]
        )
        self = Self(task=task_obj)

    @staticmethod
    def with_task(
        self_ptr: Pointer[Self, MutAnyOrigin],
        t: PythonObject,
        _mode: PythonObject,
    ) raises -> PythonObject:
        """Return a new TaskGroup with `t` added, without mutating `self`.

        Args:
            self_ptr: Pointer to self.
            t: Python task to add.
            _mode: Mode integer (0 for serial, 1 for parallel).

        Returns:
            A new TaskGroup PythonObject containing the appended task.

        Raises:
            Error if task addition fails.
        """
        var next_group = self_ptr[]._with_task(t, Int(py=_mode))
        return PythonObject(alloc=next_group^)

    @staticmethod
    def call(
        self_ptr: Pointer[Self, MutAnyOrigin], v: PythonObject
    ) raises -> PythonObject:
        """Invoke the task group from Python.

        Args:
            self_ptr: Pointer to self.
            v: Input argument.

        Returns:
            Output from group execution.

        Raises:
            Error if execution fails.
        """
        var res = self_ptr[]._call_result(v)
        if case .Some(exc) = res.error:
            return _restore_python_exception(exc)
        return res.value
