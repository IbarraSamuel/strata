from runtime.asyncrt import TaskGroup
from sys.intrinsics import _type_is_eq_parse_time
from builtin.rebind import downcast

comptime TaskToRes[t: Call] = t.O
comptime TaskToPtr[o: Origin, t: Call] = downcast[
    Pointer[t, origin=o], Movable & ImplicitlyDestructible
]


trait Call:
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDestructible

    fn __call__(self, arg: Self.I) -> Self.O:
        ...


trait Callable(Call):
    fn __rshift__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Call where _type_is_eq_parse_time[downcast[Self, Call].O, o.I](),
    ](ref [so]self, ref [oo]other: o) -> Sequence[
        O1=so,
        O2=oo,
        T1 = downcast[Self, Call],
        T2=o,
        Variadic.types[downcast[Self, Call], o],
    ]:
        return {trait_downcast[Call](self), other}

    fn __add__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Call where _type_is_eq_parse_time[downcast[Self, Call].I, o.I](),
    ](ref [so]self, ref [oo]other: o) -> Parallel[
        origin = origin_of(so, oo), downcast[Self, Call], o
    ]:
        return Parallel(trait_downcast[Call](self), other)


struct Sequence[
    O1: ImmutOrigin,
    O2: ImmutOrigin,
    T1: Call,
    T2: Call where _type_is_eq_parse_time[T1.O, T2.I](),
    //,
    elements: Variadic.TypesOfTrait[Call],
](Call):
    comptime I = Self.T1.I
    comptime O = Self.T2.O

    var t1: Pointer[Self.T1, Self.O1]
    var t2: Pointer[Self.T2, Self.O2]

    fn __init__(out self, ref [Self.O1]t1: Self.T1, ref [Self.O2]t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    fn __call__(self, arg: Self.I) -> Self.O:
        ref r1 = self.t1[](arg)
        ref r1r = rebind[Self.T2.I](r1)  # This should be redundant
        return self.t2[](r1r)

    fn __rshift__[
        oo: ImmutOrigin, o: Call where _type_is_eq_parse_time[Self.O, o.I]()
    ](self, ref [oo]other: o) -> Sequence[
        O1 = origin_of(self),
        O2=oo,
        T1=Self,
        T2=o,
        Variadic.concat_types[Self.elements, Variadic.types[o]],
    ]:
        return {self, other}

    fn __add__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Call where _type_is_eq_parse_time[Self.I, o.I](),
    ](ref [so]self, ref [oo]other: o) -> Parallel[
        origin = origin_of(so, oo), Self, o
    ]:
        return Parallel(self, other)


struct Parallel[origin: ImmutOrigin, //, *elements: Call](Call):
    comptime I = Self.elements[0].I
    comptime ResElems = Variadic.map_types_to_types[Self.elements, TaskToRes]
    comptime PtrElems = Variadic.map_types_to_types[
        Self.elements, TaskToPtr[Self.origin]
    ]
    comptime O = Tuple[*Self.ResElems]
    comptime Tasks = Tuple[*Self.PtrElems]

    var tasks: Self.Tasks

    fn __init__(
        out self: Parallel[origin = callables.origin, *Self.elements],
        *callables: * Self.elements,
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.tasks)
        )

        # TODO: Add hints before if possible.
        # Check that all in types should be the same
        @parameter
        for i in range(Variadic.size(Self.elements) - 1):
            comptime t1 = Self.elements[i].I
            comptime t2 = Self.elements[i + 1].I
            __comptime_assert _type_is_eq_parse_time[
                t1, t2
            ](), "all input types should be equal"

        @parameter
        for i in range(Variadic.size(Self.elements)):
            # comptime ti = Self.PtrElems[i]
            comptime ti = type_of(self.tasks[i])
            self.tasks[i] = rebind_var[ti](Pointer(to=callables[i]))

    fn __call__(self, v: Self.I) -> Self.O:
        # Assume all tasks has the same input type.
        var tg = TaskGroup()
        var _out_tp: Self.O

        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(_out_tp)
        )

        @parameter
        for i in range(Variadic.size(Self.elements)):

            @parameter
            async fn task():
                comptime to = Self.O.element_types[i]
                ref task_i = rebind[
                    Pointer[
                        Self.elements[i],
                        origin = Self.origin,
                    ]
                ](self.tasks[i])
                ref in_value = rebind[Self.elements[i].I](v)
                _out_tp[i] = rebind_var[to](task_i[](in_value))

            tg.create_task(task())

        tg.wait()
        return _out_tp^

    fn __rshift__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Call where _type_is_eq_parse_time[Self.O, o.I](),
    ](ref [so]self, ref [oo]other: o) -> Sequence[
        O1=so,
        O2=oo,
        T1=Self,
        T2=o,
        elements = Variadic.types[T=Call, Self, o],
    ]:
        return {self, other}

    fn __add__[
        oo: ImmutOrigin, o: Call where _type_is_eq_parse_time[Self.I, o.I]()
    ](
        ref self,
        ref [oo]other: o,
        out final: Parallel[
            origin = origin_of(Self.origin, oo),
            *Variadic.concat_types[Self.elements, Variadic.types[o]],
        ],
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(final)
        )
        # TODO: Fix rebind when this is properly handled by compiler.
        final.tasks = rebind_var[final.Tasks](
            self.tasks.concat((Pointer(to=other),))
        )


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Movable & ImplicitlyDestructible](
    Callable, Movable
):
    comptime I = Self.In
    comptime O = Self.Out

    var func: fn (Self.In) -> Self.Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
