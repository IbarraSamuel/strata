from runtime.asyncrt import _run, TaskGroup
from sys.intrinsics import _type_is_eq_parse_time
from builtin.rebind import downcast
import os

trait Call:
    alias I: AnyType
    alias O: Copyable & Movable

    fn __call__(self, arg: Self.I) -> Self.O:
        ...

trait Callable(Call):
    fn __rshift__[so: ImmutableOrigin, oo: ImmutableOrigin, ds: Call = downcast[Call, Self]](
        ref[so] self,
        ref[oo] other: Some[Call],
        out o: _Seq[O1=so, O2=oo, T1=ds, T2=type_of(other), In=ds.I, Out=type_of(other).O]
    )
        where _type_is_eq_parse_time[o.T1.O, o.T2.I]():
        # TODO: Fix rebind when this is properly handled by compiler.
        ref _self = rebind[ds](self)
        o = _Seq(_self, other)

    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin, ds: Call = downcast[Call, Self]](
        ref[so] self,
        ref[oo] other: Some[Call],
        out o: _ParGroup[O1=so, O2=oo, T1=ds, T2=type_of(other), ds.I, ds.O, type_of(other).O, size=2]
    )
        where _type_is_eq_parse_time[o.T1.I, o.T2.I]():
        # TODO: Fix rebind when this is properly handled by compiler.
        ref _self = rebind[ds](self)
        o = _ParGroup(_self, other)
    
@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Copyable & Movable](Callable, Movable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)

struct _Seq[
    O1: ImmutableOrigin,
    O2: ImmutableOrigin,
    T1: Call,
    T2: Call, //,
    In: AnyType,
    Out: Copyable & Movable
](Call, Movable):
    alias I = T1.I
    alias O = T2.O

    var t1: Pointer[T1, O1]
    var t2: Pointer[T2, O2]

    fn __init__(
        out self: _Seq[O1=O1, O2=O2, T1=type_of(t1), T2=type_of(t2), In=T1.I, Out=T2.O],
        ref[O1] t1: Some[Call],
        ref[O2] t2: Some[Call],
    )
        where _type_is_eq_parse_time[self.T1.O, self.T2.I]():
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self, arg: Self.I) -> Self.O:
        ref r1 = self.t1[].__call__(arg)
        # SAFETY: This is enforce by the where clause on initialization
        ref r1r = rebind[T2.I](r1)
        return self.t2[].__call__(r1r)
    

    # Do not conform to callable, just to be able to ignore the default in certain situations
    # Currently I'm just using the defaults, but in the future could be possible.
    fn __rshift__[so: ImmutableOrigin, oo: ImmutableOrigin](
        ref[so] self,
        ref[oo] other: Some[Call],
        out o: _Seq[O1=so, O2=oo, T1=Self, T2=type_of(other), In=Self.I, Out=type_of(other).O]
    )
        where _type_is_eq_parse_time[o.T1.O, o.T2.I]():
        o = _Seq(self, other)        

    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](
        ref[so] self,
        ref[oo] other: Some[Call],
        out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), Self.I, Self.O, type_of(other).O, size=2]
    )
        where _type_is_eq_parse_time[o.T1.I, o.T2.I]():
        o = _ParGroup(self, other)


struct _ParGroup[
    O1: ImmutableOrigin,
    O2: ImmutableOrigin,
    T1: Call,
    T2: Call,
    //,  # Enforce conformance here once type_of() works for this one
    In: AnyType,
    *Out: Copyable & Movable,
    size: Int
](Call, Movable):
    alias I = T1.I
    alias O = Tuple[*Out]

    var t1: Pointer[T1, O1]
    var t2: Pointer[T2, O2]

    fn __init__(out self, ref[O1] t1: T1, ref[O2] t2: T2, unsafe: type_of(True))
        where _type_is_eq_parse_time[T1.I, T2.I]()
        :
        """You need to provide the parameters to use this initializer"""
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __init__(
        out self: _ParGroup[O1=O1, O2=O2, T1=T1, T2=T2, T1.I, T1.O, T2.O, size=2],
        ref [O1]t1: T1,
        ref [O2]t2: T2
    )
        where _type_is_eq_parse_time[self.T1.I, self.T2.I]():
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __rshift__[so: ImmutableOrigin, oo: ImmutableOrigin](
        ref[so] self,
        ref[oo] other: Some[Call],
        out o: _Seq[O1=so, O2=oo, T1=Self, T2=type_of(other), In=Self.I, Out=type_of(other).O]
    )
        where _type_is_eq_parse_time[o.T1.O, o.T2.I]():
        o = _Seq(self, other)

    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 2:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 3:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 4:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 5:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 6:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 7:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 8:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 9:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 10:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 11:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 12:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 13:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12], Out[13], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 14:
        return {self, other, unsafe=True}
    fn __add__[so: ImmutableOrigin, oo: ImmutableOrigin](ref[so] self, ref[oo] other: Some[Call], out o: _ParGroup[O1=so, O2=oo, T1=Self, T2=type_of(other), T1.I, Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12], Out[13], Out[14], type_of(other).O, size=Self.size + 1]) where _type_is_eq_parse_time[o.T1.I, o.T2.I]() where Self.size == 15:
        return {self, other, unsafe=True}


    # fn simple_call(self, arg: Self.I) -> Self.O
    #     where _type_is_eq_parse_time[self.O, Tuple[T1.O, T2.O]]()
    #     where self.size == 2
    #     :
    #     var tg = TaskGroup()
    #     # var o: Tuple[T1.O, T2.O]
    #     var t1: T1.O
    #     var t2: T2.O

    #     @parameter
    #     async fn task_1():
    #         t1 = self.t1[].__call__(arg)

    #     @parameter
    #     async fn task_2():
    #         t2 = self.t2[].__call__(rebind[T2.I](arg))

    #     __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(t1))
    #     __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(t2))

    #     tg.create_task(task_1())
    #     tg.create_task(task_2())

    #     tg.wait()
    #     return rebind_var[Self.O]((t1^, t2^))

    fn __call__(self, arg: Self.I, out o: Self.O):
        # @parameter
        # if size == 2:
        #     ref self = rebind[_Par[O1=O1, O2=O2, T1=T1, T2=T2, T1.I, T1.O, T2.O, size=2]](
        #         self
        #     )
        #     return rebind[Self.O](self.simple_call(arg))

        var tg = TaskGroup()
        var _out_tp: Self.O


        @parameter
        async fn task_1():
            # We know for sure is a tuple
            t1_result = self.t1[].__call__(arg)
            @parameter
            if size == 2:
                _out_tp[0] = rebind_var[Out[0]](t1_result^)
                return

            @parameter
            for i in range(size - 1):
                @parameter
                if size == 3:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1]]](t1_result)[i]).copy()
                elif size == 4:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2]]](t1_result)[i]).copy()
                elif size == 5:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3]]](t1_result)[i]).copy()
                elif size == 6:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4]]](t1_result)[i]).copy()
                elif size == 7:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5]]](t1_result)[i]).copy()
                elif size == 8:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6]]](t1_result)[i]).copy()
                elif size == 9:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7]]](t1_result)[i]).copy()
                elif size == 10:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8]]](t1_result)[i]).copy()
                elif size == 11:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9]]](t1_result)[i]).copy()
                elif size == 12:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10]]](t1_result)[i]).copy()
                elif size == 13:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11]]](t1_result)[i]).copy()
                elif size == 14:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12]]](t1_result)[i]).copy()
                elif size == 15:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12], Out[13]]](t1_result)[i]).copy()
                elif size == 16:
                    _out_tp[i] = rebind[Out[i]](rebind[Tuple[Out[0], Out[1], Out[2], Out[3], Out[4], Out[5], Out[6], Out[7], Out[8], Out[9], Out[10], Out[11], Out[12], Out[13], Out[14]]](t1_result)[i]).copy()
                else:
                    os.abort(String("Tuple Size ", size, " not implemented yet."))

        @parameter
        async fn task_2():
            _out_tp[size - 1] = rebind_var[Out[size - 1]](
                self.t2[].__call__(rebind[T2.I](arg))
            )

        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(_out_tp)
        )
        tg.create_task(task_1())
        tg.create_task(task_2())

        tg.wait()
        return _out_tp^

@fieldwise_init
struct T(Callable):
    alias I = Int
    alias O = Int

    fn __call__(self, arg: Self.I) -> Self.O:
        return arg

fn tp_to_int(v: Tuple[Int, Int, Int, Int,Int, Int, Int, Int,Int, Int, Int, Int,Int, Int, Int, Int,]) -> Int:
    return v[0]

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

