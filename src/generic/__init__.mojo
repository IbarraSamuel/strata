"""Generic pipeline abstractions for sequential and parallel task execution."""

from std.runtime._asyncrt import TaskGroup
from std.builtin.rebind import downcast

comptime TaskToRes[t: Call] = t.O
"""Extract the result type of a Call type.

Parameters:
    t: The Call type.
"""

comptime TaskToPtr[o: Origin, t: Call]: Movable & Deinitable = Pointer[
    t, origin=o
]
"""Convert a Call type to a downcasted Pointer type with origin.

Parameters:
    o: The origin of the pointer.
    t: The Call type.
"""


trait Call:
    """Base trait for callable pipeline stages."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute the callable with the given input.

        Args:
            arg: The input argument.

        Returns:
            The computed result.
        """
        ...


comptime CallableInIs[T: AnyType, C: Call] = T == C.I
"""Check if a Callable input type matches T.

Parameters:
    T: Expected input type.
    C: Callable to check.
"""


trait Callable(Call):
    """Trait enabling pipelining operators `|` and `&`."""

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ]:
        """Sequence two callables together via pipe.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of next stage.

        Args:
            other: The next callable stage.

        Returns:
            A Sequence combining self and other.
        """
        comptime assert Self.O == o.I
        return {self, other}

    def __and__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), *TypeList.of[Trait=Call, Self, o]()
    ]:
        """Combine two callables to execute in parallel.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of parallel stage.

        Args:
            other: The parallel callable stage.

        Returns:
            A Parallel stage combining self and other.
        """
        comptime assert TypeList.of[Trait=Call, Self, o]().all[
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
    """Represents sequential execution of two callable stages.

    Parameters:
        O1: Origin of first stage.
        O2: Origin of second stage.
        T1: Type of first callable stage.
        T2: Type of second callable stage.
        elements: Variadic list of element callables.
    """

    comptime I = Self.T1.I
    """Input type."""
    comptime O = Self.T2.O
    """Output type."""

    var t1: Pointer[Self.T1, Self.O1]
    """Pointer to the first callable stage."""
    var t2: Pointer[Self.T2, Self.O2]
    """Pointer to the second callable stage."""

    def __init__(
        out self, ref[Self.O1] t1: Self.T1, ref[Self.O2] t2: Self.T2
    ) where Self.T1.O == Self.T2.I:
        """Initialize the Sequence.

        Args:
            t1: Reference to first stage.
            t2: Reference to second stage.
        """
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute the two stages sequentially.

        Args:
            arg: Input argument for first stage.

        Returns:
            Result of second stage.
        """
        return self.t2[](rebind[Self.T2.I](self.t1[](arg)))

    def __or__[
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
        """Chain another callable stage via pipe.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of next stage.

        Args:
            other: Next callable stage.

        Returns:
            Chained sequence.
        """
        return {self, other}

    def __and__[
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), Self, o
    ] where TypeList.of[Trait=Call, Self, o].all[CallableInIs[Self.I, _]]():
        """Run this sequence in parallel with another callable.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of parallel stage.

        Args:
            other: Parallel callable.

        Returns:
            Parallel execution of self and other.
        """
        return Parallel(self, other)


struct Parallel[
    origin: ImmOrigin,
    //,
    *elements: Call,
](Call):
    """Represents parallel execution of multiple callable stages.

    Parameters:
        origin: Lifetime origin of referenced callables.
        elements: Call types of stages.
    """

    comptime I = Self.elements[0].I
    """Common input type for all parallel stages."""
    comptime ResElems = Self.elements.map[TaskToRes]()
    """Result types of parallel stages."""
    comptime PtrElems = Self.elements.map[TaskToPtr[Self.origin, _]]()
    """Pointer types to parallel stages."""
    comptime O = Tuple[*Self.ResElems]
    """Tuple output type containing results of each stage."""
    comptime Tasks = Tuple[*Self.PtrElems]
    """Tuple of pointers to stage tasks."""

    var tasks: Self.Tasks
    """Tuple storing pointers to parallel tasks."""

    def __init__(
        out self: Parallel[origin=callables.origin, *Self.elements],
        *callables: *Self.elements,
    ) where Self.elements.all[CallableInIs[Self.elements[0].I, _]]():
        """Initialize the Parallel executor with references to callables.

        Args:
            callables: Variadic references to callable stages.
        """
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.tasks)
        )

        comptime for i in range(Self.elements.length):
            comptime ti = type_of(self.tasks[i])
            self.tasks[i] = rebind_var[ti](Pointer(to=callables[i]))

    @staticmethod
    __async def _run_elem[
        i: Int,
        in_orig: ImmOrigin,
        out_orig: MutOrigin,
    ](
        task_ptr: Pointer[Self.elements[i], Self.origin],
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O.Ts[i], out_orig],
    ):
        comptime to = downcast[Self.O.Ts[i], Movable]
        ref in_value = rebind[Self.elements[i].I](in_ptr[])
        out_ptr[] = rebind_var[to](task_ptr[](in_value))

    def __call__(self, v: Self.I) -> Self.O:
        """Execute all stages concurrently on the provided input.

        Args:
            v: Input argument passed to all parallel stages.

        Returns:
            Tuple of outputs from all stages.
        """
        var tg = TaskGroup()
        var _out_tp: Self.O

        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(_out_tp)
        )

        var in_ptr = Pointer(to=v)
        comptime for i in range(Self.elements.length):
            ref task_i = rebind[
                Pointer[
                    Self.elements[i],
                    origin=Self.origin,
                ]
            ](self.tasks[i])
            var out_ptr = Pointer(to=_out_tp[i])
            tg.create_task(Self._run_elem[i](task_i, in_ptr, out_ptr))

        tg.wait()
        return _out_tp^

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        o: Call,
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ] where (Self.O == o.I):
        """Pipe output of parallel execution into the next callable.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of next stage.

        Args:
            other: Next callable stage.

        Returns:
            A Sequence combining self and other.
        """
        return {self, other}

    def __and__[
        oo: ImmOrigin, o: Call
    ](
        deinit self,
        ref[oo] other: o,
        out final: Parallel[
            origin=origin_of(Self.origin, oo),
            *TypeList._concat[Self.elements.values, TypeList.of[o].values](),
        ],
    ) where TypeList._concat[Self.elements.values, TypeList.of[o].values]().all[
        CallableInIs[
            TypeList._concat[Self.elements.values, TypeList.of[o].values]()[
                0
            ].I,
            _,
        ]
    ]():
        """Combine this Parallel stage with an additional callable stage.

        Parameters:
            oo: Origin of other.
            o: Call type of added stage.

        Args:
            other: Callable stage to add to parallel execution.

        Returns:
            Combined Parallel stage.
        """
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(final)
        )
        final.tasks = rebind_var[final.Tasks](
            self.tasks^.concat((Pointer(to=other),))
        )


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Movable & Deinitable](Call, Movable):
    """Wrapper turning a function into a Call stage.

    Parameters:
        In: Function input argument type.
        Out: Function return type.
    """

    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.In) thin -> Self.Out
    """Underlying function."""

    def __call__(self, arg: Self.I) -> Self.O:
        """Call the wrapped function with arg.

        Args:
            arg: Input argument.

        Returns:
            Result of wrapped function.
        """
        return self.func(arg)

    def __or__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=o, Self, o
    ] where (Self.O == o.I):
        """Pipe this Fn output into another callable.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of next stage.

        Args:
            other: Next callable.

        Returns:
            A Sequence combining self and other.
        """
        return {self, other}

    def __and__[
        so: ImmOrigin, oo: ImmOrigin, o: Call
    ](ref[so] self, ref[oo] other: o) -> Parallel[
        origin=origin_of(so, oo), *TypeList.of[Trait=Call, Self, o]()
    ] where TypeList.of[Trait=Call, Self, o]().all[
        CallableInIs[TypeList.of[Trait=Call, Self, o]()[0].I, _]
    ]():
        """Combine this Fn in parallel with another callable.

        Parameters:
            so: Origin of self.
            oo: Origin of other.
            o: Call type of parallel stage.

        Args:
            other: Parallel callable.

        Returns:
            A Parallel stage combining self and other.
        """
        return {self, other}
