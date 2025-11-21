from runtime.asyncrt import TaskGroup
from sys.intrinsics import _type_is_eq_parse_time
from builtin.rebind import downcast
from builtin.variadics import Concatenated, MakeVariadic, variadic_size
import os


trait Call:
    alias I: AnyType
    alias O: Movable & Copyable

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

    fn __add__[
        so: ImmutOrigin, oo: ImmutOrigin, o: Call, s: Call = Self
    ](ref [so]self, ref [oo]other: o) -> Parallel[
        O1=so, O2=oo, T1=s, T2=o, s.I, s.O, o.O, size=2
    ] where _type_is_eq_parse_time[s.I, o.I]():
        # TODO: Fix rebind when this is properly handled by compiler.
        ref _self = rebind[s](self)
        return {_self, other}


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
    O1: ImmutOrigin,
    O2: ImmutOrigin,
    T1: Call,
    T2: Call, //,  # Enforce conformance here once type_of() works for this one
    In: AnyType,
    *Out: Copyable & Movable,
    size: Int,
](Call, Movable):
    alias I = Self.T1.I
    alias O = Tuple[*Self.Out]

    alias NewPar[
        o1: ImmutOrigin,
        o2: ImmutOrigin,
        other: Call,
        *out_types: Copyable & Movable,
    ] = Parallel[
        O1 = ImmutOrigin.cast_from[o1],
        O2 = ImmutOrigin.cast_from[o2],
        T1=Self,
        T2=other,
        Self.T1.I,
        *out_types,
        size = Self.size + 1,
    ]

    var t1: Pointer[Self.T1, Self.O1]
    var t2: Pointer[Self.T2, Self.O2]

    fn __init__(
        out self, ref [Self.O1]t1: Self.T1, ref [Self.O2]t2: Self.T2
    ) where _type_is_eq_parse_time[Self.T1.I, Self.T2.I]():
        """You need to provide the parameters to use this initializer."""
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __add__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        t: Call where _type_is_eq_parse_time[Self.I, t.I](),
    ](ref [so]self, ref [oo]other: t) -> Parallel[
        O1=so,
        O2=oo,
        T1=Self,
        T2=t,
        Self.In,
        *Concatenated[Self.Out, MakeVariadic[t.O]],
        size = Self.size + 1,
    ]:
        return {self, other}

    fn __rshift__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Call where _type_is_eq_parse_time[Self.O, o.I](),
    ](ref [so]self, ref [oo]other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, In = Self.I, Out = o.O
    ]:
        return {self, other}

    fn __call__(self, arg: Self.I, out o: Self.O):
        alias tasks_len: Int = variadic_size(Self.Out)
        var tg = TaskGroup()
        var _out_tp: Self.O

        @parameter
        async fn task_1():
            t1_result = self.t1[](arg)

            @parameter
            if Self.size == 2:
                # The Out[0] value is the only type that matters
                _out_tp[0] = rebind_var[Self.Out[0]](t1_result^)
                return

            # from builtin.variadics import _ReduceVariadicAndIdxToVariadic, _ReduceVariadicIdxGeneratorTypeGenerator
            # _ReduceVariadicAndIdxToVariadic[BaseVal=Self.Out, Variadic=MakeVariadic[Self.Out[tasks_len - 1]]]
            # Tuple[*Self.Out]

            # fmt: off
            @parameter
            for i in range(Self.size - 1):
                @parameter
                if   Self.size == 3 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1]]](t1_result)[i]).copy()
                elif Self.size == 4 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2]]](t1_result)[i]).copy()
                elif Self.size == 5 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3]]](t1_result)[i]).copy()
                elif Self.size == 6 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4]]](t1_result)[i]).copy()
                elif Self.size == 7 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5]]](t1_result)[i]).copy()
                elif Self.size == 8 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6]]](t1_result)[i]).copy()
                elif Self.size == 9 : _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7]]](t1_result)[i]).copy()
                elif Self.size == 10: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8]]](t1_result)[i]).copy()
                elif Self.size == 11: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9]]](t1_result)[i]).copy()
                elif Self.size == 12: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10]]](t1_result)[i]).copy()
                elif Self.size == 13: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11]]](t1_result)[i]).copy()
                elif Self.size == 14: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12]]](t1_result)[i]).copy()
                elif Self.size == 15: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12], Self.Out[13]]](t1_result)[i]).copy()
                elif Self.size == 16: _out_tp[i] = rebind[Self.Out[i]](rebind[Tuple[Self.Out[0], Self.Out[1], Self.Out[2], Self.Out[3], Self.Out[4], Self.Out[5], Self.Out[6], Self.Out[7], Self.Out[8], Self.Out[9], Self.Out[10], Self.Out[11], Self.Out[12], Self.Out[13], Self.Out[14]]](t1_result)[i]).copy()
                else:
                    os.abort(String("Tuple Size ", Self.size, " not implemented yet."))
                # fmt: on

        @parameter
        async fn task_2():
            _out_tp[Self.size - 1] = rebind_var[Self.Out[Self.size - 1]](
                self.t2[](rebind[Self.T2.I](arg))
            )

        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(_out_tp)
        )
        tg.create_task(task_1())
        tg.create_task(task_2())

        tg.wait()
        return _out_tp^


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


fn test_variadic():
    from builtin.variadics import (
        MakeVariadic,
        _ReduceVariadicIdxGeneratorTypeGenerator,
        _ReduceVariadicAndIdxToVariadic,
        _IndexToIntWrap,
        VariadicOf,
        Variadic,
    )

    var my_val = (1, "a", 3.0)
    alias tp = type_of(my_val)

    alias _Reductor[
        Prev: VariadicOf[Copyable & Movable],
        From: VariadicOf[Copyable & Movable],
        Idx: Int,
    ] = Prev[Idx]
    alias r = _ReduceVariadicAndIdxToVariadic[
        BaseVal = MakeVariadic[tp.element_types[0]],
        Variadic = tp.element_types,
        Reducer=_Reductor,
    ]
    alias v = r[0]


alias fou = '!lit.generator<<"Prev": variadic<trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>, "From": variadic<trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>, "Idx": @stdlib::@builtin::@int::@Int>trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>'
alias exp = '!lit.generator<<"Prev": variadic<trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>, "From": variadic<trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>, "Idx": @stdlib::@builtin::@int::@Int>variadic<trait<@stdlib::@builtin::@value::@Copyable, @stdlib::@builtin::@value::@Movable>>>'
