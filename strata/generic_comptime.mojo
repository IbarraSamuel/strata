from runtime.asyncrt import TaskGroup, create_task
from strata.custom_tuple import Tuple as _Tuple


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
    O1: Copyable & Movable,
    O2: Copyable & Movable, //,
    f: fn (In) -> O1,
    l: fn (In) -> O2,
](val: In) -> Tuple[O1, O2]:
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

    return Tuple(r1, r2)  # The tuple will make a copy of the values


# struct ParFn[
#     In: AnyType,
#     O1: AnyType,
#     O2: AnyType,
#     o: Origin,
#     //,
#     f: fn (ref[o] In) -> O1,
#     l: fn (ref[o] In) -> O2,
# ]:
#     var c1: Coroutine[O1, OriginSet(o)]
#     var c2: Coroutine[O2, __origin_of()]
#     var _r1: O1
#     var _r2: O2

#     fn __init__(out self, ref[o] _i: In):
#         __mlir_op.`lit.ownership.mark_initialized`(
#             __get_mvalue_as_litref(self._r1)
#         )
#         __mlir_op.`lit.ownership.mark_initialized`(
#             __get_mvalue_as_litref(self._r2)
#         )

#         @parameter
#         async fn task_1() -> O1:
#             return f(_i)

#         @parameter
#         async fn task_2() -> O2:
#             return l(_i)

#         self.c1 = task_1()
#         c1._set_result_slot(UnsafePointer(to=self._r1))
#         self.c2 = task_2()
#         c2._set_result_slot(UnsafePointer(to=self._r2))

#     fn run(
#         mut self, val: In
#     ) -> _Tuple[
#         mut=False,
#         origin = __origin_of(self._r1, self._r2),
#         is_owned=False,
#         O1,
#         O2,
#     ]:
#         t1 = create_task(task_1())
#         t2 = create_task(task_2())

#         t1.wait()
#         t2.wait()

#         return _Tuple(
#             self._r1, self._r2
#         )  # The tuple will make a copy of the values


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
