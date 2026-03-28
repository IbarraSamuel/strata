from std.runtime.asyncrt import TaskGroup
from std.sys.intrinsics import _type_is_eq_parse_time
from std.builtin.rebind import downcast

comptime TaskToRes[t: Callable] = t.O
comptime TaskToPtr[o: Origin, t: Callable] = downcast[
    Pointer[t, origin=o], Movable & ImplicitlyDestructible
]


# trait Call:
#     comptime I: AnyType
#     comptime O: Movable & ImplicitlyDestructible

#     def __call__(self, arg: Self.I) -> Self.O:
#         ...


trait Callable:
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDestructible

    def __call__(self, arg: Self.I) -> Self.O:
        ...

    def __rshift__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Callable where _type_is_eq_parse_time[Self.O, o.I](),
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so,
        O2=oo,
        T1=Self,
        T2=o,
        Variadic.types[Self, o],
    ]:
        return {self, other}

    def __add__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Callable where InputIsEq[Variadic.types[Self, o]],
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), Self, o
    ]:
        return {self, other}


struct Sequence[
    O1: ImmutOrigin,
    O2: ImmutOrigin,
    T1: Callable,
    T2: Callable where _type_is_eq_parse_time[T1.O, T2.I](),
    //,
    elements: Variadic.TypesOfTrait[Callable],
](Callable):
    comptime I = Self.T1.I
    comptime O = Self.T2.O

    var t1: Pointer[Self.T1, Self.O1]
    var t2: Pointer[Self.T2, Self.O2]

    def __init__(out self, ref[Self.O1] t1: Self.T1, ref[Self.O2] t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self, arg: Self.I) -> Self.O:
        return self.t2[](rebind[Self.T2.I](self.t1[](arg)))

    def __rshift__[
        oo: ImmutOrigin, o: Callable where _type_is_eq_parse_time[Self.O, o.I]()
    ](self, ref[oo] other: o) -> Sequence[
        O1=origin_of(self),
        O2=oo,
        T1=Self,
        T2=o,
        Variadic.concat_types[Self.elements, Variadic.types[o]],
    ]:
        return {self, other}

    def __add__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Callable where InputIsEq[Variadic.types[T=Callable, Self, o]],
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), Self, o
    ]:
        return Parallel(self, other)


comptime _InputIsEq[CompareTo: AnyType, V: Callable] = _type_is_eq_parse_time[
    CompareTo, V.I
]()

comptime InputIsEq[CompareTo: Variadic.TypesOfTrait[Callable]] = Variadic.size(
    Variadic.filter_types[*CompareTo, predicate=_InputIsEq[CompareTo[0].I, _]]
) == Variadic.size(CompareTo)


struct Parallel[
    origin: ImmutOrigin, //, *elements: Callable where InputIsEq[elements]
](Callable):
    comptime I = Self.elements[0].I
    comptime ResElems = Variadic.map_types_to_types[Self.elements, TaskToRes]
    comptime PtrElems = Variadic.map_types_to_types[
        Self.elements, TaskToPtr[Self.origin, _]
    ]
    comptime O = Tuple[*Self.ResElems]
    comptime Tasks = Tuple[*Self.PtrElems]

    var tasks: Self.Tasks

    def __init__(
        out self: Parallel[origin=callables.origin, *Self.elements],
        *callables: * Self.elements,
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.tasks)
        )

        comptime for i in range(Variadic.size(Self.elements)):
            # comptime ti = Self.PtrElems[i]
            comptime ti = type_of(self.tasks[i])
            self.tasks[i] = rebind_var[ti](Pointer(to=callables[i]))

    def __call__(self, v: Self.I) -> Self.O:
        # Assume all tasks has the same input type.
        var tg = TaskGroup()
        var _out_tp: Self.O

        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(_out_tp)
        )

        comptime for i in range(Variadic.size(Self.elements)):

            @parameter
            async def task():
                comptime to = Self.O.element_types[i]
                ref task_i = rebind[
                    Pointer[
                        Self.elements[i],
                        origin=Self.origin,
                    ]
                ](self.tasks[i])
                ref in_value = rebind[Self.elements[i].I](v)
                _out_tp[i] = rebind_var[to](task_i[](in_value))

            tg.create_task(task())

        tg.wait()
        return _out_tp^

    def __rshift__[
        so: ImmutOrigin,
        oo: ImmutOrigin,
        o: Callable where _type_is_eq_parse_time[Self.O, o.I](),
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so,
        O2=oo,
        T1=Self,
        T2=o,
        elements=Variadic.types[T=Callable, Self, o],
    ]:
        return {self, other}

    def __add__[
        oo: ImmutOrigin,
        o: Callable where InputIsEq[
            Variadic.concat_types[Self.elements, Variadic.types[o]]
        ],
    ](
        deinit self,
        ref[oo] other: o,
        out final: Parallel[
            origin=origin_of(Self.origin, oo),
            *Variadic.concat_types[Self.elements, Variadic.types[o]],
        ],
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(final)
        )
        # TODO: Fix rebind when this is properly handled by compiler.
        final.tasks = rebind_var[final.Tasks](
            self.tasks^.concat((Pointer(to=other),))
        )


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Movable & ImplicitlyDestructible](
    Callable, Movable
):
    comptime I = Self.In
    comptime O = Self.Out

    var func: def(Self.In) -> Self.Out

    def __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
