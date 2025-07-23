from runtime.asyncrt import TaskGroup, _run


@always_inline("nodebug")
async fn seq_fn[
    In: AnyType, Om: AnyType, O: AnyType, //, f:
    async fn (In) -> Om, l:
    async fn (Om) -> O,
](val: In) -> O:
    r1 = await f(val)
    return await l(r1)


@always_inline("nodebug")
async fn par_fn[
    In: AnyType, O1: Copyable & Movable, O2: Copyable & Movable, //, f:
    async fn (In) -> O1, l:
    async fn (In) -> O2,
](val: In) -> (O1, O2):
    tg = TaskGroup()

    var r1: O1
    var r2: O2

    @parameter
    async fn task_1():
        r1 = await f(val)

    @parameter
    async fn task_2():
        r2 = await l(val)

    # This is safe because the variables will be initialized at the return.
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(r1))
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(r2))

    tg.create_task(task_1())
    tg.create_task(task_2())

    await tg
    return (r1^, r2^)


@register_passable("trivial")
struct Fn[i: AnyType, o: Copyable & Movable, //, F: async fn (i) -> o]:
    @always_inline("builtin")
    fn __init__(out self):
        pass

    fn run(self, val: i) -> o:
        return _run(self.F(val))

    @staticmethod
    @always_inline("builtin")
    fn sequential[
        O: Copyable & Movable, //, f: async fn (o) -> O
    ]() -> Fn[seq_fn[F, f]]:
        return {}

    # @staticmethod
    # @always_inline("builtin")
    # fn sequential[next: Fn[i=o]]() -> Fn[seq_fn[F, next.F]]:
    #     return {}

    @staticmethod
    @always_inline("builtin")
    fn parallel[
        O: Copyable & Movable, //, f: async fn (i) -> O
    ]() -> Fn[par_fn[F, f]]:
        return {}

    # @staticmethod
    # @always_inline("builtin")
    # fn parallel[alongside: Fn[i=i]]() -> Fn[par_fn[F, alongside.F]]:
    #     return {}

    @always_inline("builtin")
    fn __rshift__(self, other: Fn[i=o, _]) -> Fn[seq_fn[F, other.F]]:
        return {}

    @always_inline("builtin")
    fn __add__(self, other: Fn[i=i, _]) -> Fn[par_fn[F, other.F]]:
        return {}
