from runtime.asyncrt import create_task
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
](val: In) -> (O1, O2):
    @parameter
    async fn task_1() -> O1:
        return f(val)

    @parameter
    async fn task_2() -> O2:
        return l(val)

    t1 = create_task(task_1())
    t2 = create_task(task_2())

    ref r1 = t1.wait()
    ref r2 = t2.wait()

    return (r1.copy(), r2.copy())  # The tuple will make a copy of the values


@register_passable("trivial")
struct Fn[i: AnyType, o: Copyable & Movable, //, F: fn (i) -> o]:
    @always_inline("builtin")
    fn __init__(out self):
        pass

    @staticmethod
    @always_inline("builtin")
    fn sequential[
        O: Copyable & Movable, //, f: fn (o) -> O
    ]() -> Fn[seq_fn[F, f]]:
        return Fn[seq_fn[F, f]]()

    @staticmethod
    @always_inline("builtin")
    fn parallel[
        O: Copyable & Movable, //, f: fn (i) -> O
    ]() -> Fn[par_fn[F, f]]:
        return Fn[par_fn[F, f]]()

    @always_inline("builtin")
    fn __rshift__(self, other: Fn[i=o, _]) -> Fn[seq_fn[F, other.F]]:
        return Fn[seq_fn[F, other.F]]()

    @always_inline("builtin")
    fn __add__(self, other: Fn[i=i, _]) -> Fn[par_fn[F, other.F]]:
        return Fn[par_fn[F, other.F]]()
