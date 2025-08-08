from runtime.asyncrt import (
    create_task,
    _AsyncContext,
    _init_asyncrt_chain,
    _async_wait,
    _del_asyncrt_chain,
    _async_execute,
)
from strata.custom_tuple import Tuple as _Tuple


@always_inline("nodebug")
fn seq_fn[
    In: AnyType, Om: AnyType, O: AnyType, //, f: fn (In) -> Om, l: fn (Om) -> O
](val: In) -> O:
    return l(f(val))


# struct SeqFn[
#     In: AnyType,
#     Om: AnyType,
#     O: AnyType, //,
#     f: fn (ref In) -> Om,
#     l: fn (ref Om) -> O,
# ]:
#     var _r: O

#     fn __init__(out self):
#         __mlir_op.`lit.ownership.mark_initialized`(
#             __get_mvalue_as_litref(self._r)
#         )
#         pass

#     fn run(mut self, ref val: In) -> ref[self._r] O:
#         self._r = l(f(val))
#         return self._r


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
#     o: ImmutableOrigin,
# ]:
#     # var c1: Coroutine[O1, __origin_of(o,)]
#     # var c2: Coroutine[O2, __origin_of(o,)]
#     var f1: fn(ref[o] In) -> O1
#     var f2: fn(ref[o] In) -> O2
#     var _r1: O1
#     var _r2: O2

#     fn __init__(out self, f1: fn(ref[o] In) -> O1, f2: fn(ref[o] In) -> O2):
#         self.f1 = f1
#         self.f2 = f2

#         __mlir_op.`lit.ownership.mark_initialized`(
#             __get_mvalue_as_litref(self._r1)
#         )
#         __mlir_op.`lit.ownership.mark_initialized`(
#             __get_mvalue_as_litref(self._r2)
#         )

#         # @parameter
#         # async fn task_1() -> O1:
#         #     return f1(i)

#         # @parameter
#         # async fn task_2() -> O2:
#         #     return f2(i)

#         # self.c1 = task_1()
#         # self.c1._set_result_slot(UnsafePointer(to=self._r1))
#         # self.c2 = task_2()
#         # self.c2._set_result_slot(UnsafePointer(to=self._r2))

#     fn run(
#         mut self, ref[o] val: In
#     ) -> _Tuple[
#         mut=False,
#         origin = __origin_of(self._r1, self._r2),
#         is_owned=False,
#         O1,
#         O2,
#     ]:
#         @parameter
#         async fn task_1() -> O1:
#             return self.f1(val)

#         @parameter
#         async fn task_2() -> O2:
#             return self.f2(val)

#         c1 = task_1()
#         c1._set_result_slot(UnsafePointer(to=self._r1))
#         c2 = task_2()
#         c2._set_result_slot(UnsafePointer(to=self._r2))

#         ctx1 = c1._get_ctx[_AsyncContext]()
#         _init_asyncrt_chain(_AsyncContext.get_chain(ctx1))
#         ctx1[].callback = _AsyncContext.complete

#         ctx2 = c2._get_ctx[_AsyncContext]()
#         _init_asyncrt_chain(_AsyncContext.get_chain(ctx2))
#         ctx2[].callback = _AsyncContext.complete

#         # This triggers the thing
#         _async_execute[O1](c1._handle, -1)
#         _async_execute[O2](c2._handle, -1)

#         _async_wait(_AsyncContext.get_chain(ctx1))
#         _async_wait(_AsyncContext.get_chain(ctx2))


#         # t1.wait()
#         # t2.wait()

#         return _Tuple(
#             self._r1, self._r2
#         )  # The tuple will make a copy of the values

#     fn __del__(owned self):
#         ctx1 = self.c1._get_ctx[_AsyncContext]()
#         ctx2 = self.c2._get_ctx[_AsyncContext]()

#         _del_asyncrt_chain(_AsyncContext.get_chain(ctx1))
#         _del_asyncrt_chain(_AsyncContext.get_chain(ctx2))

#     #     self.c1^.force_destroy()
#     #     self.c2^.force_destroy()


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


# @register_passable("trivial")
# struct RefFn[i: AnyType, o: AnyType, //, F: fn (ref i) -> o]:
#     fn __init__(out self):
#         pass

#     @staticmethod
#     fn sequential[
#         O: Copyable & Movable, //, f: fn (ref o) -> O
#     ]() -> SeqFn[F, f]:
#         return SeqFn[F, f]()

#     @staticmethod
#     fn parallel[
#         O: Copyable & Movable, //, f: fn (ref i) -> O
#     ]() -> ParFn[F, f]:
#         return ParFn[F, f]()

#     # fn __rshift__(self, other: Fn[i=o, _]) -> Fn[seq_fn[F, other.F]]:
#     #     return Fn[seq_fn[F, other.F]]()

#     # fn __add__(self, other: Fn[i=i, _]) -> Fn[par_fn[F, other.F]]:
#     #     return Fn[par_fn[F, other.F]]()
