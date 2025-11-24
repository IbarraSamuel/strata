from runtime.asyncrt import TaskGroup
from sys.intrinsics import _type_is_eq_parse_time
from builtin.rebind import downcast
from builtin.variadics import (
    Concatenated,
    variadic_size,
    Variadic,
    VariadicOf,
    EmptyVariadic,
    MakeVariadic,
    _ReduceVariadicIdxGeneratorTypeGenerator,
    _IndexToIntWrap,
    # _ReduceVariadicAndIdxToVariadic,
    # _MapVariadicAndIdxToType,
    # _VariadicIdxToTypeGeneratorTypeGenerator,
    # _WrapVariadicIdxToTypeMapperToReducer,
)
import os


comptime _ReduceVariadicAndIdxToVariadic[
    From: type_of(AnyType),
    To: type_of(AnyType), //,
    *,
    BaseVal: VariadicOf[To],
    Variadic: VariadicOf[From],
    Reducer: _ReduceVariadicIdxGeneratorTypeGenerator[VariadicOf[To], From],
] = __mlir_attr[
    `#kgen.variadic.reduce<`,
    BaseVal,
    `,`,
    Variadic,
    `,`,
    _IndexToIntWrap[From, VariadicOf[To], Reducer],
    `> : `,
    type_of(BaseVal),
]

comptime _VariadicIdxToTypeGeneratorTypeGenerator[
    From: type_of(AnyType), To: type_of(AnyType)
] = __mlir_type[
    `!lit.generator<<"From": !kgen.variadic<`,
    From,
    `>, "Idx":`,
    Int,
    `>`,
    To,
    `>`,
]
"""This specifies a generator to generate a generator type for the mapper.
The generated generator type is [Ts: VariadicOf[AnyType], idx: Int] -> AnyType,
which maps the input variadic + index of the current element to another type.
"""

comptime _WrapVariadicIdxToTypeMapperToReducer[
    F: type_of(AnyType),
    T: type_of(AnyType),
    Mapper: _VariadicIdxToTypeGeneratorTypeGenerator[F, T],
    Prev: VariadicOf[T],
    From: VariadicOf[F],
    Idx: Int,
] = Concatenated[Prev, MakeVariadic[Mapper[From, Idx]]]

comptime _MapVariadicAndIdxToType[
    From: type_of(AnyType), //,
    *,
    To: type_of(AnyType),
    Variadic: VariadicOf[From],
    Mapper: _VariadicIdxToTypeGeneratorTypeGenerator[From, To],
] = _ReduceVariadicAndIdxToVariadic[
    BaseVal = EmptyVariadic[To],  # reduce from a empty variadic
    Variadic=Variadic,
    Reducer = _WrapVariadicIdxToTypeMapperToReducer[From, To, Mapper],
]
"""Construct a new variadic of types using a type-to-type mapper.

Parameters:
    To: A common trait bound for the mapped type
    Variadic: The variadic to be mapped
    Mapper: A `[Ts: *From, idx: index] -> To` that does the transform
"""

alias _TaskToResultMapper[*ts: Call, i: Int] = ts[i].O
alias TaskMapResult[*element_types: Call] = _MapVariadicAndIdxToType[
    To = Copyable & Movable, Variadic=element_types, Mapper=_TaskToResultMapper
]

alias _TaskToPtrMapper[*ts: Call, i: Int] = LegacyUnsafePointer[ts[i]]
alias TaskMapPtr[*element_types: Call] = _MapVariadicAndIdxToType[
    To = Copyable & Movable, Variadic=element_types, Mapper=_TaskToPtrMapper
]


trait Call:
    alias I: AnyType
    alias O: Copyable & Movable

    fn __call__(self, arg: Self.I) -> Self.O:
        ...


trait Callable(Call):
    fn __rshift__[
        so: ImmutOrigin, oo: ImmutOrigin, o: Call, s: Call = Self
    ](ref [so]self, ref [oo]other: o) -> Sequence[
        O1=so, O2=oo, T1=s, T2=o, s.I, o.O
    ] where _type_is_eq_parse_time[s.O, o.I]():
        # TODO: Fix rebind when this is properly handled by compiler.
        ref _self = rebind[s](self)
        return {_self, other}

    # fn __add__[
    #     so: ImmutOrigin, oo: ImmutOrigin, o: Call, s: Call = Self
    # ](ref [so]self, ref [oo]other: o) -> Parallel[
    #     O1=so, O2=oo, T1=s, T2=o, s.I, s.O, o.O, size=2
    # ] where _type_is_eq_parse_time[s.I, o.I]():
    #     # TODO: Fix rebind when this is properly handled by compiler.
    #     ref _self = rebind[s](self)
    #     return {_self, other}


@fieldwise_init
struct Sequence[
    O1: ImmutOrigin,
    O2: ImmutOrigin,
    T1: Call,
    T2: Call, //,
    In: AnyType,
    Out: Movable & Copyable,
](Callable, Movable):
    alias I = Self.T1.I
    alias O = Self.T2.O

    var t1: Pointer[Self.T1, Self.O1]
    var t2: Pointer[Self.T2, Self.O2]

    fn __init__(
        out self, ref [Self.O1]t1: Self.T1, ref [Self.O2]t2: Self.T2
    ) where _type_is_eq_parse_time[Self.T1.O, Self.T2.I]():
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self, arg: Self.I) -> Self.O:
        ref r1 = self.t1[](arg)
        ref r1r = rebind[Self.T2.I](r1)
        return self.t2[](r1r)


struct Parallel[
    Ts: VariadicOf[Call], //,
    *,
    In: AnyType,
    Out: VariadicOf[Copyable & Movable] = TaskMapResult[*Ts],
](Movable):
    alias I = Self.Ts[0].I
    alias O = Tuple[*Self.Out]

    var tasks: Tuple[*TaskMapPtr[*Self.Ts]]

    fn __init__[
        o1: ImmutOrigin,
        o2: ImmutOrigin,
        a1: AddressSpace,
        a2: AddressSpace,
        T1: Call,
        T2: Call where _type_is_eq_parse_time[T1.I, T2.I](),
    ](
        out self: Parallel[Ts = MakeVariadic[T1, T2], In = T1.I],
        ref [o1, a1]t1: T1,
        ref [o2, a2]t2: T2,
    ):
        """You need to provide the parameters to use this initializer."""
        var ptr1 = (
            UnsafePointer(to=t1)
            .as_any_origin()
            .unsafe_mut_cast[True]()
            .address_space_cast[AddressSpace.GENERIC]()
            .as_legacy_pointer()
        )
        var ptr2 = (
            UnsafePointer(to=t2)
            .as_any_origin()
            .unsafe_mut_cast[True]()
            .address_space_cast[AddressSpace.GENERIC]()
            .as_legacy_pointer()
        )
        var v1 = rebind_var[type_of(self.tasks).element_types[0]](ptr1)
        var v2 = rebind_var[type_of(self.tasks).element_types[1]](ptr2)
        self.tasks = Tuple(v1^, v2^)
        # self.tasks = rebind[type_of(Parallel[Ts=MakeVariadic[T1, T2], T1.I].tasks)](ptr1, ptr2)

    # fn __add__[
    #     so: ImmutOrigin,
    #     oo: ImmutOrigin,
    #     t: Call where _type_is_eq_parse_time[Self.I, t.I](),
    # ](ref [so]self, ref [oo]other: t) -> Parallel[
    #     O1=so,
    #     O2=oo,
    #     T1=Self,
    #     T2=t,
    #     Self.In,
    #     *Concatenated[Self.Out, MakeVariadic[t.O]],
    # ]:
    #     return {self, other}

    # fn __rshift__[
    #     so: ImmutOrigin,
    #     oo: ImmutOrigin,
    #     o: Call where _type_is_eq_parse_time[Self.O, o.I](),
    # ](ref [so]self, ref [oo]other: o) -> Sequence[
    #     O1=so, O2=oo, T1=Self, T2=o, In = Self.I, Out = o.O
    # ]:
    #     return {self, other}

    # fn __call__(self, arg: Self.I, out o: Self.O):
    #     alias tasks_len: Int = variadic_size(Self.Out)
    #     var tg = TaskGroup()
    #     var _out_tp: Self.O

    #     @parameter
    #     async fn task_1():
    #         t1_result = self.t1[](arg)

    #         @parameter
    #         if Self.size == 2:
    #             # The Out[0] value is the only type that matters
    #             _out_tp[0] = rebind_var[Self.Out[0]](t1_result^)
    #             return

    #         # from builtin.variadics import _ReduceVariadicAndIdxToVariadic, _ReduceVariadicIdxGeneratorTypeGenerator
    #         # _ReduceVariadicAndIdxToVariadic[BaseVal=Self.Out, Variadic=MakeVariadic[Self.Out[tasks_len - 1]]]
    #         # Tuple[*Self.Out]

    #         # fmt: off
    #         @parameter
    #         for i in range(Self.size - 1):
    #             @parameter
    #             if   Self.size == 3 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1]]](t1_result)[i]).copy()
    #             elif Self.size == 4 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2]]](t1_result)[i]).copy()
    #             elif Self.size == 5 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3]]](t1_result)[i]).copy()
    #             elif Self.size == 6 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4]]](t1_result)[i]).copy()
    #             elif Self.size == 7 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5]]](t1_result)[i]).copy()
    #             elif Self.size == 8 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6]]](t1_result)[i]).copy()
    #             elif Self.size == 9 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7]]](t1_result)[i]).copy()
    #             elif Self.size == 10: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8]]](t1_result)[i]).copy()
    #             elif Self.size == 11: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9]]](t1_result)[i]).copy()
    #             elif Self.size == 12: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10]]](t1_result)[i]).copy()
    #             elif Self.size == 13: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11]]](t1_result)[i]).copy()
    #             elif Self.size == 14: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12]]](t1_result)[i]).copy()
    #             elif Self.size == 15: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12], Self.Out[13]]](t1_result)[i]).copy()
    #             elif Self.size == 16: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12], Self.Out[13], Self.Out[14]]](t1_result)[i]).copy()
    #             else:
    #                 os.abort(String("Tuple Size ", Self.size, " not implemented yet."))
    #             # fmt: on

    #     @parameter
    #     async fn task_2():
    #         _out_tp[Self.size - 1] = rebind_var[Self.Out[Self.size - 1]](
    #             self.t2[](rebind[Self.T2.I](arg))
    #         )

    #     __mlir_op.`lit.ownership.mark_initialized`(
    #         __get_mvalue_as_litref(_out_tp)
    #     )
    #     tg.create_task(task_1())
    #     tg.create_task(task_2())

    #     tg.wait()
    #     return _out_tp^


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Copyable & Movable](Callable, Movable):
    alias I = Self.In
    alias O = Self.Out

    var func: fn (Self.In) -> Self.Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)


@fieldwise_init
struct T(Callable):
    alias I = Int
    alias O = Int

    fn __call__(self, arg: Self.I) -> Self.O:
        return arg


# fmt: off
fn tp_to_int(v: Tuple[Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int,Int]) -> Int:
    return v[0]
# fmt: on


fn run():
    t1 = T()
    t2 = T()
    t3 = T()
    t4 = T()
    f = Fn(tp_to_int)

    var last = (
        t1
        + t2
        + t3
        + t4
        + t1
        + t2
        + t3
        + t4
        + t1
        + t2
        + t3
        + t4
        + t1
        + t2
        + t3
        + t4
    )
    var final = last >> f
    res = final(3)
    print(res)
