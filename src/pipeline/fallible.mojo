"""Fallible (raising) runtime pipeline stages with error propagation.

Enables Mojo stages that can `raises` to compose cleanly via `|` and `&`:
- Sequential stages (`|`) short-circuit on the first error and propagate it.
- Parallel stages (`&`, flattened into one `TaskGroup`) capture per-branch
  errors and re-raise after `tg.wait()` (combining messages if multiple branches
  fail).
"""

from std.builtin.rebind import downcast

from .._internal.runtime import TaskGroup, uninitialized_storage

comptime FallibleToOut[t: FallibleStage] = t.O
"""Extract the output type of a `FallibleStage`.

Parameters:
    t: The `FallibleStage` type.
"""

comptime FallibleToPtr[
    o: ImmOrigin, t: FallibleStage
]: Movable & Deinitable = Pointer[t, origin=o]
"""Convert a `FallibleStage` type to an immutable `Pointer` with origin `o`.

Parameters:
    o: Origin of the pointer.
    t: The `FallibleStage` type.
"""

comptime FallibleInIs[T: AnyType, S: FallibleStage] = T == S.I
"""Check whether a `FallibleStage`'s input type equals `T`.

Parameters:
    T: Expected input type.
    S: Fallible stage to inspect.
"""

comptime AllSameFallibleInput[
    elems: TypeList[Trait=FallibleStage, _]
] = elems.all[FallibleInIs[elems[0].I, _]]()
"""Check whether all fallible stages in `elems` share the same input type.

Parameters:
    elems: List of fallible stages to check.
"""

comptime _concat_fallible_one[
    v1: TypeList[Trait=FallibleStage, _], v2: FallibleStage
] = TypeList._concat[v1.values, TypeList.of[Trait=FallibleStage, v2].values]

comptime _concat_fallible_many[
    v1: TypeList[Trait=FallibleStage, _], v2: TypeList[Trait=FallibleStage, _]
] = TypeList._concat[v1.values, v2.values]


trait FallibleStage:
    """Base trait for runtime pipeline stages that may raise `Error`."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `RaisingParallel` stages."""

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute this stage on `arg`, raising on failure.

        Args:
            arg: Input argument.

        Returns:
            Computed stage result.

        Raises:
            Error: If the stage fails.
        """
        ...


trait ComposableFallibleStage(FallibleStage):
    """Mixin trait providing `|` and `&` operators for raising stages."""

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: FallibleStage,
    ](ref[so] self, ref[oo] other: Other) -> RaisingSequence[
        O1=so, O2=oo, T1=Self, T2=Other
    ]:
        """Pipe `self` into `other` sequentially, short-circuiting on error.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Next fallible stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A `RaisingSequence` executing `self` then `other`.
        """
        comptime assert Self.O == Other.I
        return {self, other}

    def __and__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: ComposableFallibleStage,
    ](ref[so] self, ref[oo] other: Other) -> RaisingParallel[
        origin=origin_of(so, oo), Self, Other
    ]:
        """Execute `self` and `other` concurrently on the same input.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Parallel fallible stage type.

        Args:
            other: Parallel stage.

        Returns:
            A `RaisingParallel` executing both concurrently.
        """
        comptime assert AllSameFallibleInput[
            TypeList.of[Trait=FallibleStage, Self, Other]()
        ]
        return {self, other}

    def __and__[
        so: ImmOrigin,
        po: ImmOrigin,
        *other_elems: FallibleStage,
    ](
        ref[so] self,
        other: RaisingParallel[origin=po, *other_elems],
        out final: RaisingParallel[
            origin=origin_of(so, po),
            *_concat_fallible_many[
                TypeList.of[Trait=FallibleStage, Self](), other_elems
            ](),
        ],
    ):
        """Combine `self` with a right-hand `RaisingParallel`, flattening associatively.

        Parameters:
            so: Origin of `self`.
            po: Origin of the right-hand `RaisingParallel` stage's referenced tasks.
            other_elems: Stages inside the right-hand `RaisingParallel` stage.

        Args:
            other: Right-hand `RaisingParallel` stage.

        Returns:
            A flat `RaisingParallel` stage containing `self` followed by `other_elems`.
        """
        comptime assert AllSameFallibleInput[
            _concat_fallible_many[
                TypeList.of[Trait=FallibleStage, Self](), other_elems
            ]()
        ]
        final = uninitialized_storage[type_of(final)]()
        comptime t0 = type_of(final.tasks[0])
        final.tasks[0] = rebind_var[t0](Pointer(to=self))
        comptime for i in range(other_elems.length):
            var ptr = rebind[Pointer[other_elems[i], po]](other.tasks[i])
            comptime ti = type_of(final.tasks[i + 1])
            final.tasks[i + 1] = rebind_var[ti](ptr)


struct RaisingSequence[
    O1: ImmOrigin,
    O2: ImmOrigin,
    T1: FallibleStage,
    T2: FallibleStage,
](ComposableFallibleStage):
    """Sequential composition of two raising stages.

    Parameters:
        O1: Origin of first stage.
        O2: Origin of second stage.
        T1: First fallible stage type.
        T2: Second fallible stage type.
    """

    comptime I = Self.T1.I
    """Input type of the first stage."""
    comptime O = Self.T2.O
    """Output type of the second stage."""

    var t1: Pointer[Self.T1, Self.O1]
    """Pointer to the first stage."""
    var t2: Pointer[Self.T2, Self.O2]
    """Pointer to the second stage."""

    def __init__(
        out self, ref[Self.O1] t1: Self.T1, ref[Self.O2] t2: Self.T2
    ) where Self.T1.O == Self.T2.I:
        """Initialize with references to both fallible stages.

        Args:
            t1: Reference to first stage.
            t2: Reference to second stage.
        """
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute both stages sequentially, propagating any raised error.

        Args:
            arg: Input argument.

        Returns:
            Result of `t2`.

        Raises:
            Error: If either `t1` or `t2` fails.
        """
        var mid = self.t1[](arg)
        return self.t2[](rebind[Self.T2.I](mid))


struct RaisingGroup[origin: ImmOrigin, //, Inner: FallibleStage](
    ComposableFallibleStage
):
    """Opaque wrapper preventing `&` from flattening an inner `RaisingParallel`.

    Parameters:
        origin: Origin of the wrapped stage reference.
        Inner: Wrapped fallible stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the wrapped stage."""

    def __init__(out self, ref[Self.origin] inner: Self.Inner):
        """Initialize around `inner`.

        Args:
            inner: Fallible stage to keep grouped.
        """
        self.inner = Pointer(to=inner)

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute the wrapped fallible stage.

        Args:
            arg: Input argument.

        Returns:
            Output of the wrapped stage.

        Raises:
            Error: If the wrapped stage fails.
        """
        return self.inner[](arg)


def raising_group[
    origin: ImmOrigin, //, Inner: FallibleStage
](ref[origin] inner: Inner) -> RaisingGroup[origin=origin, Inner]:
    """Wrap a fallible stage as an opaque group to preserve nested tuples.

    Parameters:
        origin: Origin of `inner`.
        Inner: Wrapped fallible stage type.

    Args:
        inner: Stage to wrap.

    Returns:
        Opaque `RaisingGroup` stage.
    """
    return {inner}


struct RaisingParallel[
    origin: ImmOrigin,
    //,
    *elements: FallibleStage,
](FallibleStage):
    """Flat parallel execution of raising stages with error propagation.

    Executes all branches concurrently in one `TaskGroup`, captures any branch
    errors into per-branch slots, and raises after `tg.wait()` if any branch
    failed.

    Parameters:
        origin: Combined origin of all referenced stages.
        elements: Fallible stage types to execute concurrently.
    """

    comptime I = Self.elements[0].I
    """Common input type."""
    comptime _IS_PARALLEL: Bool = True
    """Marks `RaisingParallel` for associative flattening."""
    comptime ResElems = Self.elements.map[FallibleToOut]()
    """Result types of all branches."""
    comptime PtrElems = Self.elements.map[FallibleToPtr[Self.origin, _]]()
    """Pointer types to all branch stages."""
    comptime O = Tuple[*Self.ResElems]
    """Flat tuple output type."""
    comptime Tasks = Tuple[*Self.PtrElems]
    """Tuple storing stage pointers."""

    var tasks: Self.Tasks
    """Pointers to all parallel fallible stages."""

    def __init__(
        out self: RaisingParallel[origin=callables.origin, *Self.elements],
        *callables: *Self.elements,
    ) where AllSameFallibleInput[Self.elements]:
        """Initialize from variadic fallible stage references.

        Args:
            callables: Variadic references to fallible stages.
        """
        self.tasks = uninitialized_storage[type_of(self.tasks)]()
        comptime for i in range(Self.elements.length):
            comptime ti = type_of(self.tasks[i])
            self.tasks[i] = rebind_var[ti](Pointer(to=callables[i]))

    @staticmethod
    __async def _run_elem[
        i: Int,
        in_orig: ImmOrigin,
        out_orig: MutOrigin,
        err_orig: MutOrigin,
    ](
        task_ptr: Pointer[Self.elements[i], Self.origin],
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O.Ts[i], out_orig],
        err_ptr: Pointer[Optional[String], err_orig],
    ):
        comptime to = downcast[Self.O.Ts[i], Movable]
        ref in_value = rebind[Self.elements[i].I](in_ptr[])
        try:
            out_ptr[] = rebind_var[to](task_ptr[](in_value))
        except e:
            err_ptr[] = String(e)

    def __call__(self, v: Self.I) raises -> Self.O:
        """Execute all branches concurrently and propagate any branch failures.

        Args:
            v: Input value broadcast to all branches.

        Returns:
            Flat tuple of branch outputs if every branch succeeds.

        Raises:
            Error: The error from a single failed branch, or a combined summary
                if multiple branches fail.
        """
        var tg = TaskGroup()
        var _out_tp = uninitialized_storage[Self.O]()
        var errors = List[Optional[String]](
            length=Self.elements.length, fill=None
        )

        var in_ptr = Pointer(to=v)
        comptime for i in range(Self.elements.length):
            ref task_i = rebind[Pointer[Self.elements[i], origin=Self.origin]](
                self.tasks[i]
            )
            var out_ptr = Pointer(to=_out_tp[i])
            var err_ptr = Pointer(to=errors[i]).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            tg.create_task(Self._run_elem[i](task_i, in_ptr, out_ptr, err_ptr))

        tg.wait()

        var messages = List[String]()
        for i in range(Self.elements.length):
            if case .Some(msg) = errors[i]:
                messages.append(msg)

        if len(messages) == 1:
            # Avoid running destructors on uninitialized tuple slots from failed branches.
            __mlir_op.`lit.ownership.mark_destroyed`(
                __get_mvalue_as_litref(_out_tp)
            )
            raise Error(messages[0])
        if len(messages) > 1:
            __mlir_op.`lit.ownership.mark_destroyed`(
                __get_mvalue_as_litref(_out_tp)
            )
            raise Error(
                String(
                    "Parallel stage failures (",
                    len(messages),
                    "): ",
                    "; ".join(messages),
                )
            )

        return _out_tp^

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: FallibleStage,
    ](ref[so] self, ref[oo] other: Other) -> RaisingSequence[
        O1=so, O2=oo, T1=Self, T2=Other
    ] where Self.O == Other.I:
        """Pipe this parallel stage's tuple output into `other`.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Next fallible stage type.

        Args:
            other: Next stage accepting `Self.O`.

        Returns:
            A `RaisingSequence` combining `self` and `other`.
        """
        return {self, other}

    def __and__[
        oo: ImmOrigin, Other: FallibleStage
    ](
        self,
        ref[oo] other: Other,
        out final: RaisingParallel[
            origin=origin_of(Self.origin, oo),
            *_concat_fallible_one[Self.elements, Other](),
        ],
    ) where (not Other._IS_PARALLEL) and AllSameFallibleInput[
        _concat_fallible_one[Self.elements, Other]()
    ]:
        """Append another fallible stage to this parallel group.

        Parameters:
            oo: Origin of `other`.
            Other: Stage type to append.

        Args:
            other: Stage to execute concurrently.

        Returns:
            A flat `RaisingParallel` stage with `other` appended.
        """
        final = uninitialized_storage[type_of(final)]()
        comptime for i in range(Self.elements.length):
            var ptr = rebind[Pointer[Self.elements[i], Self.origin]](
                self.tasks[i]
            )
            comptime ti = type_of(final.tasks[i])
            final.tasks[i] = rebind_var[ti](ptr)
        comptime last_t = type_of(final.tasks[Self.elements.length])
        final.tasks[Self.elements.length] = rebind_var[last_t](
            Pointer(to=other)
        )

    def __and__[
        po: ImmOrigin, *other_elems: FallibleStage
    ](
        self,
        other: RaisingParallel[origin=po, *other_elems],
        out final: RaisingParallel[
            origin=origin_of(Self.origin, po),
            *_concat_fallible_many[Self.elements, other_elems](),
        ],
    ) where AllSameFallibleInput[
        _concat_fallible_many[Self.elements, other_elems]()
    ]:
        """Merge another `RaisingParallel` group into this one associatively.

        Parameters:
            po: Origin of the right-hand `RaisingParallel` stage's referenced tasks.
            other_elems: Stages inside the right-hand `RaisingParallel` stage.

        Args:
            other: Right-hand `RaisingParallel` stage to merge with.

        Returns:
            A flat `RaisingParallel` stage containing all branches from both groups.
        """
        final = uninitialized_storage[type_of(final)]()
        comptime for i in range(Self.elements.length):
            var ptr = rebind[Pointer[Self.elements[i], Self.origin]](
                self.tasks[i]
            )
            comptime ti = type_of(final.tasks[i])
            final.tasks[i] = rebind_var[ti](ptr)
        comptime for j in range(other_elems.length):
            var ptr = rebind[Pointer[other_elems[j], po]](other.tasks[j])
            comptime tj = type_of(final.tasks[Self.elements.length + j])
            final.tasks[Self.elements.length + j] = rebind_var[tj](ptr)


@fieldwise_init("implicit")
struct RaisingFn[In: AnyType, Out: Movable & Deinitable](
    ComposableFallibleStage, Movable, Copyable
):
    """Wrapper turning a raising thin function into a `ComposableFallibleStage`.

    Parameters:
        In: Function input type.
        Out: Function return type.
    """

    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.In) raises thin -> Self.Out
    """Wrapped raising function pointer."""

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Invoke the wrapped raising function with `arg`.

        Args:
            arg: Input argument.

        Returns:
            Result of `self.func(arg)`.

        Raises:
            Error: Any error raised by `self.func`.
        """
        return self.func(arg)
