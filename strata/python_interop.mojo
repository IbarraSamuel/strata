from os import abort
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
from runtime.asyncrt import TaskGroup as TG


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

        return strata.finalize()
    except e:
        return abort[PythonObject](
            String("failed to create Python module: ", e)
        )


alias PythonType = Representable


struct Graph(PythonType):
    var elems: TaskGroup

    fn __init__(out self):
        self.elems = TaskGroup()

    fn __repr__(self) -> String:
        return String("Graph(...)")

    fn _call(self, v: PythonObject) raises -> PythonObject:
        return self.elems._call(v)

    fn _capture_elems(mut self, owned elems: TaskGroup) raises:
        self.elems = elems^

    @staticmethod
    fn call_task(
        self_ptr: UnsafePointer[Self], v: PythonObject
    ) raises -> PythonObject:
        return self_ptr[]._call(v)

    @staticmethod
    fn capture_elems(self_ptr: UnsafePointer[Self], elems: PythonObject) raises:
        e = elems.downcast_value_ptr[TaskGroup]()
        self_ptr[]._capture_elems(e[])


struct TaskGroup(Copyable, Movable, PythonType):
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
        # @parameter
        # @always_inline
        # fn run_task(i: Int):
        #     tsk = self.objects.unsafe_get(i)
        #     try:
        #         grp = tsk._try_downcast_value[TaskGroup]()
        #         if grp:
        #             values[i] = grp.value()[]._call(msg)
        #             return

        #         values[i] = tsk.__call__(msg)
        #     except:
        #         print("Task Failed!")
        #         values[i] = PythonObject(None)

        # @parameter
        # @always_inline
        # async fn run_async(i: Int):
        #     run_task(i)

        # tg = TG()
        # for idx in range(len(self.objects)):
        #     tg.create_task(run_async(idx))

        # tg.wait()

        print("Done!..")
        tp = Python.tuple()
        for res in values:
            tp += Python.tuple(res)
        return tp

    @staticmethod
    fn from_single_task(self_ptr: UnsafePointer[Self], t: PythonObject) raises:
        self_ptr[].objects.append(t)

    @staticmethod
    fn add_task(
        self_ptr: UnsafePointer[Self], t: PythonObject, _mode: PythonObject
    ) raises:
        self_ptr[].add(t, Int(_mode))

    @staticmethod
    fn call(
        self_ptr: UnsafePointer[Self], v: PythonObject
    ) raises -> PythonObject:
        return self_ptr[]._call(v)
