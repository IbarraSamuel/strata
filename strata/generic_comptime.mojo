from memory.pointer import Pointer
from runtime.asyncrt import TaskGroup, _run
from strata.custom_tuple import Tuple


# trait Callable:
#     alias I: AnyType
#     alias O: Movable

#     @staticmethod
#     fn call(arg: I) -> O:
#         ...


# @register_passable("trivial")
# struct Task[C: Callable, *, In: InType = C.I, Out: OutType = C.O](Callable):
#     alias I = In
#     alias O = Out

#     @staticmethod
#     @always_inline("nodebug")
#     fn call(value: Self.I) -> Self.O:
#         return rebind[Self.O](C.call(rebind[C.I](value)))

#     @always_inline("builtin")
#     fn __init__(out self):
#         pass

#     @always_inline("builtin")
#     fn __rshift__[
#         c: Callable
#     ](self: Task[C, In=In, Out = c.I], other: c) -> Task[SerPair[C, c]]:
#         return {}

#     @always_inline("builtin")
#     fn __add__[
#         c: Callable
#     ](self: Task[C, In = c.I, Out=Out], other: c) -> Task[ParPair[C, c]]:
#         return {}


# @register_passable("trivial")
# struct SerPair[
#     C1: Callable,
#     C2: Callable,
#     t1: Task[C1, In = C1.I, Out = C2.I] = {},
#     t2: Task[C2, In = C2.I, Out = C2.O] = {},
# ](Callable):
#     alias I = t1.I
#     alias O = t2.O

#     @staticmethod
#     @always_inline("nodebug")
#     fn call(arg: Self.I) -> Self.O:
#         out_1 = t1.call(arg)
#         return t2.call(out_1^)


# @register_passable("trivial")
# struct ParPair[
#     C1: Callable,
#     C2: Callable,
#     t1: Task[C1, In = C2.I, Out = C1.O] = {},
#     t2: Task[C2, In = C2.I, Out = C2.O] = {},
# ](Callable):
#     alias I = t1.I
#     alias O = (t1.Out, t2.Out)

#     @staticmethod
#     @always_inline("nodebug")
#     fn call(arg: Self.I) -> Self.O:
#         tg = TaskGroup()
#         var o1: t1.O
#         var o2: t2.O

#         @parameter
#         async fn task_1():
#             o1 = t1.call(arg)

#         @parameter
#         async fn task_2():
#             o2 = t2.call(arg)

#         # This is safe because the variables will be initialized at the return.
#         __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o1))
#         __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o2))

#         tg.create_task(task_1())
#         tg.create_task(task_2())

#         tg.wait()
#         return (o1^, o2^)


@always_inline("nodebug")
fn seq_fn[
    In: AnyType,
    Om: AnyType,
    O: AnyType, //,
    f: fn (In) -> Om,
    l: fn (Om) -> O,
](val: In) -> O:
    return l(f(val))


@always_inline("nodebug")
fn par_fn[
    In: AnyType,
    O1: Movable,
    O2: Movable, //,
    f: fn (In) -> O1,
    l: fn (In) -> O2,
](val: In) -> Tuple[O1, O2]:
    tg = TaskGroup()

    var r1: O1
    var r2: O2

    @parameter
    async fn task_1():
        r1 = f(val)

    @parameter
    async fn task_2():
        r2 = l(val)

    # This is safe because the variables will be initialized at the return.
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(r1))
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(r2))

    tg.create_task(task_1())
    tg.create_task(task_2())

    tg.wait()
    return (r1^, r2^)


@register_passable("trivial")
struct Fn[i: AnyType, o: Movable, //, F: fn (i) -> o]:
    alias I = i
    alias O = o

    @always_inline("builtin")
    fn __init__(out self):
        pass

    @staticmethod
    @always_inline("builtin")
    fn sequential[O: Movable, //, f: fn (o) -> O]() -> Fn[seq_fn[F, f]]:
        return {}

    # @staticmethod
    # @always_inline("builtin")
    # fn sequential[next: Fn[i=o]]() -> Fn[seq_fn[F, next.F]]:
    #     return {}

    @staticmethod
    @always_inline("builtin")
    fn parallel[O: Movable, //, f: fn (i) -> O]() -> Fn[par_fn[F, f]]:
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
