struct MutableTask:
    var value: Int

    fn __init__(out self):
        self.value = 0

    fn mut_something(mut self):
        self.value += 1


# Nothing here is mutated, we only mutate via the pointer
@value
struct ImmutableRefToMutTask[o: MutableOrigin]:
    var value: Pointer[MutableTask, o]

    fn __init__(out self, ref [o]mt: MutableTask):
        self.value = Pointer(to=mt)

    fn mut_inner(self):
        self.value[].mut_something()


@value
struct ImmutableTask:
    fn __init__(out self):
        pass

    fn run_something(self):
        pass


struct GroupTask[o: MutableOrigin]:
    var imtask: ImmutableTask
    var muttask: ImmutableRefToMutTask[o]

    fn __init__(
        out self,
        owned imtask: ImmutableTask,
        owned mutask: ImmutableRefToMutTask[o],
    ):
        self.imtask = imtask^
        self.muttask = mutask^

    fn mut_something(mut self):
        self.imtask.run_something()
        self.muttask.mut_inner()


fn main():
    mt = MutableTask()
    mtr = ImmutableRefToMutTask(mt)
    it = ImmutableTask()

    gt = GroupTask(it, mtr)
