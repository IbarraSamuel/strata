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
](val: In) -> Tuple[O1, O2]:
    t1 = create_task(f(val))
    t2 = create_task(l(val))
    ref r1 = await t1
    ref r2 = await t2
    return (r1.copy(), r2.copy())


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
