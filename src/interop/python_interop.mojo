from os import abort
from python import PythonObject, Python
from python._cpython import GILReleased
from runtime.asyncrt import TaskGroup as TG
from python.bindings import PythonModuleBuilder, PyObjectFunction


@export
fn PyInit_mojo_strata() -> PythonObject:
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


struct TaskGroup(Movable, Representable):
    alias undefined = TaskGroup(-1)
    alias Serial = TaskGroup(0)
    alias Parallel = TaskGroup(1)

    var mode: Int
    var objects: List[PythonObject]

    # fn __init__(out self):
    #     self.mode = -1
    #     self.objects = []

    fn __init__(out self, task: PythonObject):
        self.mode = -1
        self.objects = [task]

    fn __init__(out self, mode: Int):
        self.mode = mode
        self.objects = []

    fn copy(self, out o: Self):
        o = Self(mode=self.mode)
        o.objects = self.objects.copy()

    fn __repr__(self) -> String:
        objs = "[" + String(", ").join(self.objects) + "]"
        mode = (
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel"
        )
        return String("TaskGroup(mode:", mode, ", objects:", objs, ")")

    fn add(mut self, t: PythonObject, mode: Int) raises:
        if self.mode == Self.undefined.mode:
            self.mode = mode

        if self.mode == mode:
            self.objects.append(t)
            return

        new_group = TaskGroup(mode=mode)
        new_group.objects.append(PythonObject(alloc=self.copy()))
        new_group.objects.append(t)
        self = new_group^

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

                iv = obj.__call__(iv)
            print("Done!..")
            return iv  # Before, here we had a tuple

        var values = List[PythonObject](
            length=len(self.objects), fill=PythonObject()
        )

        # WORKAROUND:
        for i in range(len(self.objects)):
            ref task = self.objects.unsafe_get(i)
            pg = task._try_downcast_value[TaskGroup]()
            if pg:
                values[i] = pg.value()[]._call(msg)
                continue

            values[i] = task.__call__(msg)

        # TODO: Turn on when NO GIL is possible
        # RELEASE GIL
        # var python = Python()
        # with GILReleased(python):

        #     @parameter
        #     @always_inline
        #     fn run_task(i: Int):
        #         tsk = self.objects.unsafe_get(i)
        #         try:
        #             grp = tsk._try_downcast_value[TaskGroup]()
        #             if grp:
        #                 values[i] = grp.value()[]._call(msg)
        #                 return

        #             values[i] = tsk.__call__(msg)
        #         except:
        #             print("Task Failed!")
        #             values[i] = PythonObject(None)

        #     @parameter
        #     @always_inline
        #     async fn run_async(i: Int):
        #         run_task(i)

        #     tg = TG()
        #     for idx in range(len(self.objects)):
        #         tg.create_task(run_async(idx))

        #     tg.wait()

        print("Done!..")
        tp = Python.tuple()
        for res in values:
            tp += Python.tuple(res)
        return tp

    @staticmethod
    fn py_init(out self: Self, args: PythonObject, kwargs: PythonObject) raises:
        self = Self(task=kwargs["task"])

    @staticmethod
    fn add_task(
        self_ptr: UnsafePointer[Self, MutAnyOrigin],
        t: PythonObject,
        _mode: PythonObject,
    ) raises:
        self_ptr.unsafe_mut_cast[True]()[].add(t, Int(_mode))

    @staticmethod
    fn py_method():
        pass

    @staticmethod
    fn call(
        self_ptr: UnsafePointer[Self, MutAnyOrigin], v: PythonObject
    ) raises -> PythonObject:
        return self_ptr[]._call(v)
