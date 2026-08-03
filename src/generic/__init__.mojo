from std.runtime.asyncrt import TaskGroup
from std.builtin.rebind import downcast

comptime TaskToRes[t: Call] = t.O
comptime TaskToPtr[o: Origin, t: Call] = downcast[
    Pointer[t, origin=o], Movable & ImplicitlyDeletable
]


trait Call:
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDeletable

    def __call__(self, arg: Self.I) -> Self.O:
        ...


comptime CallableInIs[T: AnyType, C: Call] = T == C.I


trait Callable(Call):
    def __rshift__[
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ]:
        comptime assert Self.O == o.I
        return {self, other}

    def __add__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), *TypeList.of[Trait=Call, Self, o]()
    ]:
        comptime assert TypeList.of[Trait=Call, Self, o]().all_satisfies[
            CallableInIs[TypeList.of[Trait=Call, Self, o]()[0].I, _]
        ]()
        return {self, other}


struct Sequence[
    O1: ImmOrigin,
    O2: ImmOrigin,
    T1: Call,
    T2: Call,
    //,
    *elements: Call,
](Call):
    comptime I = Self.T1.I
    comptime O = Self.T2.O

    var t1: Pointer[Self.T1, Self.O1]
    var t2: Pointer[Self.T2, Self.O2]

    def __init__(
        out self, ref[Self.O1] t1: Self.T1, ref[Self.O2] t2: Self.T2
    ) where Self.T1.O == Self.T2.I:
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self, arg: Self.I) -> Self.O:
        return self.t2[](rebind[Self.T2.I](self.t1[](arg)))

    def __rshift__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so,
        O2=oo,
        T1=Self,
        T2=o,
        *TypeList._concat[
            Self.elements.values, TypeList.of[Trait=Call, o].values
        ](),
    ] where (Self.O == o.I):
        return {self, other}

    def __add__[
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), Self, o
    ] where TypeList.of[Trait=Call, Self, o].all_satisfies[
        CallableInIs[Self.I, _]
    ]():
        return Parallel(self, other)


struct Parallel[
    origin: ImmOrigin,
    //,
    *elements: Call,
](Call):
    comptime I = Self.elements[0].I
    comptime ResElems = Self.elements.map[TaskToRes]()
    comptime PtrElems = Self.elements.map[TaskToPtr[Self.origin, _]]()
    comptime O = Tuple[*Self.ResElems]
    comptime Tasks = Tuple[*Self.PtrElems]

    var tasks: Self.Tasks

    def __init__(
        out self: Parallel[origin=callables.origin, *Self.elements],
        *callables: *Self.elements,
    ) where Self.elements.all_satisfies[CallableInIs[Self.elements[0].I, _]]():
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.tasks)
        )

        comptime for i in range(Self.elements.length):
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

        comptime for i in range(Self.elements.length):

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
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ] where (Self.O == o.I):
        return {self, other}

    def __add__[
        oo: ImmOrigin, o: Call
    ](
        deinit self,
        ref[oo] other: o,
        out final: Parallel[
            origin=origin_of(Self.origin, oo),
            *TypeList._concat[Self.elements.values, TypeList.of[o].values](),
        ],
    ) where TypeList._concat[
        Self.elements.values, TypeList.of[o].values
    ]().all_satisfies[
        CallableInIs[
            TypeList._concat[Self.elements.values, TypeList.of[o].values]()[
                0
            ].I,
            _,
        ]
    ]():
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(final)
        )
        # TODO: Fix rebind when this is properly handled by compiler.
        final.tasks = rebind_var[final.Tasks](
            self.tasks^.concat((Pointer(to=other),))
        )


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Movable & ImplicitlyDeletable](Call, Movable):
    comptime I = Self.In
    comptime O = Self.Out

    var func: def(Self.In) thin -> Self.Out

    def __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)

    def __rshift__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ] where (Self.O == o.I):
        return {self, other}

    def __add__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), *TypeList.of[Trait=Call, Self, o]()
    ] where TypeList.of[Trait=Call, Self, o]().all_satisfies[
        CallableInIs[TypeList.of[Trait=Call, Self, o]()[0].I, _]
    ]():
        return {self, other}
