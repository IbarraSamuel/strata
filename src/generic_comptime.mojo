from runtime.asyncrt import Task, TaskGroup
from strata.custom_tuple import Tuple as _Tuple


@always_inline("nodebug")
fn seq_fn[
    In: AnyType, Om: AnyType, O: AnyType, //, f: fn (In) -> Om, l: fn (Om) -> O
](val: In) -> O:
    return l(f(val))


@always_inline("nodebug")
fn par_fn[
    In: AnyType,
    O1: Copyable & Movable,
    O2: Copyable & Movable, //,
    f: fn (In) -> O1,
    l: fn (In) -> O2,
](val: In) -> Tuple[O1, O2]:
    tg = TaskGroup()

    var v1: O1
    var v2: O2

    @parameter
    async fn task_1():
        v1 = f(val)

    @parameter
    async fn task_2():
        v2 = l(val)

    # This is safe because the variables will be initialized at the return.
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v1))
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v2))

    tg.create_task(task_1())
    tg.create_task(task_2())

    tg.wait()

    return (v1^, v2^)


@register_passable("trivial")
struct Fn[i: AnyType, o: Copyable & Movable, //, F: fn (i) -> o]:
    @always_inline("builtin")
    fn __init__(out self):
        pass

    @staticmethod
    @always_inline("builtin")
    fn sequential[
        O: Copyable & Movable, //, f: fn (Self.o) -> O
    ]() -> Fn[seq_fn[Self.F, f]]:
        return Fn[seq_fn[Self.F, f]]()

    @staticmethod
    @always_inline("builtin")
    fn parallel[
        O: Copyable & Movable, //, f: fn (Self.i) -> O
    ]() -> Fn[par_fn[Self.F, f]]:
        return Fn[par_fn[Self.F, f]]()

    @always_inline("builtin")
    fn __rshift__(
        self, other: Fn[i = Self.o, _]
    ) -> Fn[seq_fn[Self.F, other.F]]:
        return Fn[seq_fn[Self.F, other.F]]()

    @always_inline("builtin")
    fn __add__(self, other: Fn[i = Self.i, _]) -> Fn[par_fn[Self.F, other.F]]:
        return Fn[par_fn[Self.F, other.F]]()
