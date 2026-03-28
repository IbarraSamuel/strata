from std.runtime.asyncrt import _run, create_task, TaskGroup


@always_inline("nodebug")
async def seq_fn[
    In: AnyType, Om: ImplicitlyDestructible, O: ImplicitlyDestructible, //, f:
    async def (In) -> Om, l:
    async def (Om) -> O,
](val: In) -> O:
    ref r1 = await f(val)
    return await l(r1)


@always_inline("nodebug")
async def par_fn[
    In: AnyType, O1: Copyable & ImplicitlyDestructible, O2: Copyable & ImplicitlyDestructible, //, f:
    async def (In) -> O1, l:
    async def (In) -> O2,
](val: In, out o: Tuple[O1, O2]):

    tg = TaskGroup()

    __mlir_op.`lit.ownership.mark_initialized`(
        __get_mvalue_as_litref(o)
    )

    @parameter
    async def task1():
        o[0] = await f(val)
    @parameter
    async def task2():
        o[1] = await l(val)

    tg.create_task(task1())
    tg.create_task(task2())

    await tg


struct Fn[i: AnyType, o: Copyable & Movable & ImplicitlyDestructible, //, F: async def (i) -> o](TrivialRegisterPassable):
    @always_inline("builtin")
    def __init__(out self):
        pass

    def run(self, val: Self.i) -> Self.o:
        return _run(self.F(val))

    @always_inline("builtin")
    def __rshift__(
        self, other: Fn[i = Self.o, _]
    ) -> Fn[seq_fn[Self.F, other.F]]:
        return {}

    @always_inline("builtin")
    def __add__(self, other: Fn[i = Self.i, _]) -> Fn[par_fn[Self.F, other.F]]:
        return {}
