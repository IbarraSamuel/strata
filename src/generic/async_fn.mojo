from std.runtime._asyncrt import TaskGroup, _run


@always_inline("nodebug")
__async def seq_fn[
    In: AnyType, Om: Deinitable, O: Deinitable, //, f:
    __async def(In) thin -> Om, l:
    __async def(Om) thin -> O,
](val: In) -> O:
    ref r1 = __await f(val)
    return __await l(r1)


@always_inline("nodebug")
__async def par_fn[
    In: AnyType, O1: Movable & Deinitable, O2: Movable & Deinitable, //, f:
    __async def(In) thin -> O1, l:
    __async def(In) thin -> O2,
](val: In, out o: Tuple[O1, O2]):
    var tg = TaskGroup()

    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o))

    __async def task1() {imm val, mut o}:
        o[0] = __await f(val)

    __async def task2() {imm val, mut o}:
        o[1] = __await l(val)

    tg.create_task(task1())
    tg.create_task(task2())

    __await tg


struct Fn[i: AnyType, o: Movable & Deinitable, //, F: __async def(i) thin -> o](
    TrivialRegisterPassable
):
    @always_inline("builtin")
    def __init__(out self):
        pass

    def run(self, val: Self.i) -> Self.o:
        var result = _run(self.F(val))
        return result^

    @always_inline("builtin")
    def __rshift__(self, other: Fn[i=Self.o, _]) -> Fn[seq_fn[Self.F, other.F]]:
        return {}

    @always_inline("builtin")
    def __add__(self, other: Fn[i=Self.i, _]) -> Fn[par_fn[Self.F, other.F]]:
        return {}
