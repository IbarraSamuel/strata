"""Python interoperability module for task group execution."""

from std.os import abort
from std.python import PythonObject, Python
from std.python._cpython import GILReleased, GILAcquired
from std.runtime._asyncrt import TaskGroup as TG
from std.python.bindings import PythonModuleBuilder


__async def _run_async_task(
    task_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    msg_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    out_ptr: Pointer[PythonObject, MutUntrackedOrigin],
):
    with GILAcquired(Python()):
        try:
            var grp = task_ptr[]._try_downcast_value[TaskGroup]()
            if grp:
                out_ptr[] = grp.value()[]._call(msg_ptr[])
                return
            out_ptr[] = task_ptr[](msg_ptr[])
        except:
            pass


@export
def PyInit_mojo_strata() abi("C") -> PythonObject:
    """Initialize the CPython extension module for mojo_strata.

    Returns:
        The initialized Python module object.
    """
    try:
        var strata = PythonModuleBuilder("mojo_strata")

        _ = (
            strata.add_type[TaskGroup]("TaskGroup")
            .def_py_init[TaskGroup.py_init]()
            .def_method[TaskGroup.add_task](
                "add_task", "Add a task to the group."
            )
            .def_method[TaskGroup.call]("call", "Make this group callable.")
        )

        return strata.finalize()
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

    def _call(self, msg: PythonObject) raises -> PythonObject:
        if len(self.objects) == 0:
            return msg

        if self.mode == Self.undefined.mode:
            if len(self.objects) == 1:
                var pg = self.objects[0]._try_downcast_value[TaskGroup]()
                if pg:
                    return pg.value()[]._call(msg)
                return self.objects[0].__call__(msg)
            raise "Group mode not set up"

        print(
            "in mode:",
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel",
        )

        if self.mode == Self.Serial.mode:
            var iv = msg
            for obj in self.objects:
                var pg = obj._try_downcast_value[TaskGroup]()
                if pg:
                    iv = pg.value()[]._call(iv)
                else:
                    iv = obj.__call__(iv)
            print("Done!..")
            return iv

        var values = List[PythonObject](
            length=len(self.objects), fill=PythonObject()
        )

        var tg = TG()
        var msg_copy = msg
        var msg_ptr = Pointer(to=msg_copy).unsafe_origin_cast[MutUntrackedOrigin]()

        for idx in range(len(self.objects)):
            var t_ptr = Pointer(to=self.objects[idx]).unsafe_origin_cast[MutUntrackedOrigin]()
            var out_ptr = Pointer(to=values[idx]).unsafe_origin_cast[MutUntrackedOrigin]()
            tg.create_task(_run_async_task(t_ptr, msg_ptr, out_ptr))

        with GILReleased(Python()):
            tg.wait()

        print("Done!..")
        var tp = Python.tuple()
        for res in values:
            tp += Python.tuple(res)
        return tp

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
    def add_task(
        self_ptr: Pointer[Self, MutAnyOrigin],
        t: PythonObject,
        _mode: PythonObject,
    ) raises:
        """Add a task to the group from Python.

        Args:
            self_ptr: Pointer to self.
            t: Python task to add.
            _mode: Mode integer.

        Raises:
            Error if task addition fails.
        """
        self_ptr[]._add_task(t, Int(py=_mode))

    @staticmethod
    def py_method():
        """Stub method for Python interop."""
        pass

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
        return self_ptr[]._call(v)
