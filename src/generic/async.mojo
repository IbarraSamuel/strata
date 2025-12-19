from runtime.asyncrt import _run, create_task
from runtime.asyncrt import TaskGroup


@always_inline("nodebug")
async fn seq_fn[
    In: AnyType, Om: ImplicitlyDestructible, O: ImplicitlyDestructible, //, f:
    async fn (In) -> Om, l:
    async fn (Om) -> O,
](val: In) -> O:
    ref r1 = await f(val)
    return await l(r1)


@always_inline("nodebug")
async fn par_fn[
    In: AnyType, O1: Copyable & ImplicitlyDestructible, O2: Copyable & ImplicitlyDestructible, //, f:
    async fn (In) -> O1, l:
    async fn (In) -> O2,
](val: In) -> Tuple[O1, O2]:
    t1 = create_task(f(val))
    t2 = create_task(l(val))
    ref r1 = await t1
    ref r2 = await t2
    return (r1.copy(), r2.copy())


@register_passable("trivial")
struct Fn[i: AnyType, o: Copyable & Movable, //, F: async fn (i) -> o]:
    @always_inline("builtin")
    fn __init__(out self):
        pass

    fn run(self, val: Self.i) -> Self.o:
        return _run(self.F(val))

    @always_inline("builtin")
    fn __rshift__(
        self, other: Fn[i = Self.o, _]
    ) -> Fn[seq_fn[Self.F, other.F]]:
        return {}

    @always_inline("builtin")
    fn __add__(self, other: Fn[i = Self.i, _]) -> Fn[par_fn[Self.F, other.F]]:
        return {}
