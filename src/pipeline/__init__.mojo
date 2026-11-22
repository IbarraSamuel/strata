"""Runtime value-passing and unit pipeline abstractions.

Provides zero-allocation borrowed composition (`Stage`, `ComposableStage`, `Fn`,
`UnitFn`, `Sequence`, `Parallel`, `Group`) as well as value-owning composition
(`Owned`, `OwnedSequence`, `OwnedParallel`, `OwnedGroup`) for returning
pipelines from factory functions. All `&` fan-outs flatten associatively into
one flat `TaskGroup` unless wrapped explicitly with `group(...)`.
"""

from std.builtin.rebind import downcast
from std.reflection import reflect
from std.time import perf_counter_ns

from .._internal.runtime import TaskGroup, uninitialized_storage
from ..executors import Executor

comptime StageToOut[t: Stage] = t.O
"""Extract the output type of a `Stage`.

Parameters:
    t: The `Stage` type.
"""

comptime StageToPtr[o: ImmOrigin, t: Stage]: Movable & Deinitable = Pointer[
    t, origin=o
]
"""Convert a `Stage` type to an immutable `Pointer` with origin `o`.

Parameters:
    o: Origin of the pointer.
    t: The `Stage` type.
"""

comptime StageInIs[T: AnyType, S: Stage] = T == S.I
"""Check whether a `Stage`'s input type equals `T`.

Parameters:
    T: Expected input type.
    S: Stage to inspect.
"""

comptime AllSameStageInput[elems: TypeList[Trait=Stage, _]] = elems.all[
    StageInIs[elems[0].I, _]
]()
"""Check whether all stages in `elems` share the same input type.

Parameters:
    elems: List of stages to check.
"""

comptime _concat_stage_one[
    v1: TypeList[Trait=Stage, _], v2: Stage
] = TypeList._concat[v1.values, TypeList.of[Trait=Stage, v2].values]

comptime _concat_stage_many[
    v1: TypeList[Trait=Stage, _], v2: TypeList[Trait=Stage, _]
] = TypeList._concat[v1.values, v2.values]

comptime _MovableStage = Stage & Movable & Deinitable

comptime _OwnedStageInIs[T: AnyType, S: _MovableStage] = T == S.I

comptime _AllSameOwnedInput[
    elems: TypeList[Trait=_MovableStage, _]
] = elems.all[_OwnedStageInIs[elems[0].I, _]]()

comptime _OwnedStageToOut[t: _MovableStage] = t.O

comptime _concat_owned_one[
    v1: TypeList[Trait=_MovableStage, _], v2: _MovableStage
] = TypeList._concat[v1.values, TypeList.of[Trait=_MovableStage, v2].values]

comptime _concat_owned_many[
    v1: TypeList[Trait=_MovableStage, _],
    v2: TypeList[Trait=_MovableStage, _],
] = TypeList._concat[v1.values, v2.values]


trait Stage:
    """Base trait for runtime pipeline stages."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `Parallel` stages for associative `&`."""

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute this stage on `arg`.

        Args:
            arg: Input argument.

        Returns:
            Computed stage result.
        """
        ...

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute this stage using a pluggable `Executor`.

        Default implementation wraps `self(arg)` with `exec`'s start/end hooks.
        Composite stages (`Sequence`, `Parallel`, `Group`, etc.) override this
        to propagate `exec` into child stages.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            arg: Input argument.

        Returns:
            Computed stage result.
        """
        var token = exec.on_stage_start(reflect[Self].name())
        var res = self(arg)
        exec.on_stage_end(reflect[Self].name(), token)
        return res^


trait ComposableStage(Stage):
    """Mixin trait providing `|` (pipe) and `&` (parallel fan-out) operators."""

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: Stage,
    ](ref[so] self, ref[oo] other: Other) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=Other
    ]:
        """Pipe the output of `self` into `other` sequentially.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Next stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A `Sequence` executing `self` then `other`.
        """
        comptime assert Self.O == Other.I
        return {self, other}

    def __and__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: ComposableStage,
    ](ref[so] self, ref[oo] other: Other) -> Parallel[
        origin=origin_of(so, oo), Self, Other
    ]:
        """Execute `self` and `other` concurrently on the same input.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Parallel stage type.

        Args:
            other: Parallel stage.

        Returns:
            A `Parallel` stage running both concurrently.
        """
        comptime assert AllSameStageInput[
            TypeList.of[Trait=Stage, Self, Other]()
        ]
        return {self, other}

    def __and__[
        so: ImmOrigin,
        po: ImmOrigin,
        *other_elems: Stage,
    ](
        ref[so] self,
        other: Parallel[origin=po, *other_elems],
        out final: Parallel[
            origin=origin_of(so, po),
            *_concat_stage_many[
                TypeList.of[Trait=Stage, Self](), other_elems
            ](),
        ],
    ):
        """Combine `self` with a right-hand `Parallel` stage, flattening associatively.

        Parameters:
            so: Origin of `self`.
            po: Origin of the right-hand `Parallel` stage's referenced tasks.
            other_elems: Stages inside the right-hand `Parallel` stage.

        Args:
            other: Right-hand `Parallel` stage.

        Returns:
            A flat `Parallel` stage containing `self` followed by `other_elems`.
        """
        comptime assert AllSameStageInput[
            _concat_stage_many[TypeList.of[Trait=Stage, Self](), other_elems]()
        ]
        final = uninitialized_storage[type_of(final)]()
        comptime t0 = type_of(final.tasks[0])
        Pointer(to=final.tasks[0]).unsafe_write(
            rebind_var[t0](Pointer(to=self))
        )
        comptime for i in range(other_elems.length):
            var ptr = rebind[Pointer[other_elems[i], po]](other.tasks[i])
            comptime ti = type_of(final.tasks[i + 1])
            Pointer(to=final.tasks[i + 1]).unsafe_write(rebind_var[ti](ptr))


struct Sequence[
    O1: ImmOrigin,
    O2: ImmOrigin,
    T1: Stage,
    T2: Stage,
](ComposableStage):
    """Sequential composition of two borrowed stages (`t1 | t2`).

    Parameters:
        O1: Origin of first stage.
        O2: Origin of second stage.
        T1: Type of first stage.
        T2: Type of second stage.
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
        """Initialize the sequential pair with references to both stages.

        Args:
            t1: Reference to first stage.
            t2: Reference to second stage.
        """
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute both stages in sequence.

        Args:
            arg: Input argument for `t1`.

        Returns:
            Output produced by `t2`.
        """
        return self.t2[](rebind[Self.T2.I](self.t1[](arg)))

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute both stages in sequence using `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            arg: Input argument for `t1`.

        Returns:
            Output produced by `t2`.
        """
        var mid = self.t1[].run_with(exec, arg)
        return self.t2[].run_with(exec, rebind[Self.T2.I](mid))


struct Group[origin: ImmOrigin, //, Inner: Stage](ComposableStage):
    """Opaque wrapper preventing `&` from flattening an inner `Parallel` stage.

    Parameters:
        origin: Origin of the wrapped stage reference.
        Inner: Wrapped stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the wrapped stage."""

    def __init__(out self, ref[Self.origin] inner: Self.Inner):
        """Initialize the opaque group wrapper around `inner`.

        Args:
            inner: Reference to the stage to keep grouped.
        """
        self.inner = Pointer(to=inner)

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute the wrapped stage.

        Args:
            arg: Input argument.

        Returns:
            Output of the wrapped stage.
        """
        return self.inner[](arg)

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute the wrapped stage using `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            arg: Input argument.

        Returns:
            Output of the wrapped stage.
        """
        return self.inner[].run_with(exec, arg)


def group[
    origin: ImmOrigin, //, Inner: Stage
](ref[origin] inner: Inner) -> Group[origin=origin, Inner]:
    """Wrap a stage as an opaque `Group` so `&` preserves nested tuple output.

    Parameters:
        origin: Origin of `inner`.
        Inner: Wrapped stage type.

    Args:
        inner: Stage to wrap.

    Returns:
        Opaque `Group` stage referencing `inner`.
    """
    return {inner}


struct Parallel[
    origin: ImmOrigin,
    //,
    *elements: Stage,
](Stage):
    """Flat parallel execution of multiple borrowed stages in one `TaskGroup`.

    Supports full associative flattening on both `Parallel & Stage` and
    `Parallel & Parallel` without consuming `self` or `other`.

    Parameters:
        origin: Combined origin of all referenced stages.
        elements: Stage types to execute concurrently.
    """

    comptime I = Self.elements[0].I
    """Common input type shared by all branches."""
    comptime _IS_PARALLEL: Bool = True
    """Marks `Parallel` for associative flattening."""
    comptime ResElems = Self.elements.map[StageToOut]()
    """Result types of all branches."""
    comptime PtrElems = Self.elements.map[StageToPtr[Self.origin, _]]()
    """Pointer types to all branch stages."""
    comptime O = Tuple[*Self.ResElems]
    """Flat tuple output type containing each branch's result."""
    comptime Tasks = Tuple[*Self.PtrElems]
    """Tuple storing stage pointers."""

    var tasks: Self.Tasks
    """Pointers to all parallel stages."""

    def __init__(
        out self: Parallel[origin=callables.origin, *Self.elements],
        *callables: *Self.elements,
    ) where AllSameStageInput[Self.elements]:
        """Initialize the `Parallel` stage from variadic stage references.

        Args:
            callables: Variadic references to stages to run concurrently.
        """
        self.tasks = uninitialized_storage[type_of(self.tasks)]()
        comptime for i in range(Self.elements.length):
            comptime ti = type_of(self.tasks[i])
            Pointer(to=self.tasks[i]).unsafe_write(
                rebind_var[ti](Pointer(to=callables[i]))
            )

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
        out_ptr.unsafe_bitcast[to]().unsafe_write(
            rebind_var[to](task_ptr[](in_value))
        )

    @staticmethod
    __async def _run_elem_traced[
        i: Int,
        in_orig: ImmOrigin,
        out_orig: MutOrigin,
        t_orig: MutOrigin,
    ](
        task_ptr: Pointer[Self.elements[i], Self.origin],
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O.Ts[i], out_orig],
        start_ptr: Pointer[Int, t_orig],
        end_ptr: Pointer[Int, t_orig],
    ):
        comptime to = downcast[Self.O.Ts[i], Movable]
        ref in_value = rebind[Self.elements[i].I](in_ptr[])
        start_ptr[] = perf_counter_ns()
        out_ptr.unsafe_bitcast[to]().unsafe_write(
            rebind_var[to](task_ptr[](in_value))
        )
        end_ptr[] = perf_counter_ns()

    def __call__(self, v: Self.I) -> Self.O:
        """Execute all branches concurrently on `v` in a single `TaskGroup`.

        Args:
            v: Input value broadcast to all branches.

        Returns:
            Flat tuple of branch outputs.
        """
        var tg = TaskGroup()
        var _out_tp = uninitialized_storage[Self.O]()

        var in_ptr = Pointer(to=v)
        comptime for i in range(Self.elements.length):
            ref task_i = rebind[Pointer[Self.elements[i], origin=Self.origin]](
                self.tasks[i]
            )
            var out_ptr = Pointer(to=_out_tp[i])
            tg.create_task(Self._run_elem[i](task_i, in_ptr, out_ptr))

        tg.wait()
        return _out_tp^

    def run_with[E: Executor](self, mut exec: E, v: Self.I) -> Self.O:
        """Execute all branches according to executor `exec`.

        Respects `SequentialExecutor` (zero asyncrt calls), `BoundedExecutor`
        (wave-limited `TaskGroup` batches), and `TracingExecutor` (lock-free
        per-branch span capture).

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            v: Input value broadcast to all branches.

        Returns:
            Flat tuple of branch outputs.
        """
        var _out_tp = uninitialized_storage[Self.O]()
        comptime if not E.IS_PARALLEL:
            comptime for i in range(Self.elements.length):
                comptime to = downcast[Self.O.Ts[i], Movable]
                ref task_i = rebind[
                    Pointer[Self.elements[i], origin=Self.origin]
                ](self.tasks[i])
                ref in_value = rebind[Self.elements[i].I](v)
                Pointer(to=_out_tp[i]).unsafe_bitcast[to]().unsafe_write(
                    rebind_var[to](task_i[].run_with(exec, in_value))
                )
            return _out_tp^
        else:
            var limit = exec.concurrency_limit()
            if limit == 1:
                comptime for i in range(Self.elements.length):
                    comptime to = downcast[Self.O.Ts[i], Movable]
                    ref task_i = rebind[
                        Pointer[Self.elements[i], origin=Self.origin]
                    ](self.tasks[i])
                    ref in_value = rebind[Self.elements[i].I](v)
                    Pointer(to=_out_tp[i]).unsafe_bitcast[to]().unsafe_write(
                        rebind_var[to](task_i[].run_with(exec, in_value))
                    )
                return _out_tp^

            var in_ptr = Pointer(to=v)
            var tracing = exec.is_tracing()
            var starts = List[Int](length=Self.elements.length, fill=0)
            var ends = List[Int](length=Self.elements.length, fill=0)
            var wave_size = limit if limit > 0 else Self.elements.length
            var wave_start = 0
            while wave_start < Self.elements.length:
                var wave_end = min(wave_start + wave_size, Self.elements.length)
                var tg = TaskGroup()
                comptime for i in range(Self.elements.length):
                    if i >= wave_start and i < wave_end:
                        ref task_i = rebind[
                            Pointer[Self.elements[i], origin=Self.origin]
                        ](self.tasks[i])
                        var out_ptr = Pointer(to=_out_tp[i])
                        if tracing:
                            var s_ptr = Pointer(
                                to=starts[i]
                            ).unsafe_origin_cast[MutUntrackedOrigin]()
                            var e_ptr = Pointer(
                                to=ends[i]
                            ).unsafe_origin_cast[MutUntrackedOrigin]()
                            tg.create_task(
                                Self._run_elem_traced[i](
                                    task_i, in_ptr, out_ptr, s_ptr, e_ptr
                                )
                            )
                        else:
                            tg.create_task(
                                Self._run_elem[i](task_i, in_ptr, out_ptr)
                            )
                tg.wait()
                wave_start = wave_end

            if tracing:
                comptime for i in range(Self.elements.length):
                    exec.record_span(
                        reflect[Self.elements[i]].name(), starts[i], ends[i]
                    )
            return _out_tp^

    def __or__[
        so: ImmOrigin,
        oo: ImmOrigin,
        Other: Stage,
    ](ref[so] self, ref[oo] other: Other) -> Sequence[
        O1=so, O2=oo, T1=Self, T2=Other
    ] where Self.O == Other.I:
        """Pipe this parallel stage's flat tuple output into `other`.

        Parameters:
            so: Origin of `self`.
            oo: Origin of `other`.
            Other: Next stage type.

        Args:
            other: Next stage accepting `Self.O`.

        Returns:
            A `Sequence` combining `self` and `other`.
        """
        return {self, other}

    def __and__[
        oo: ImmOrigin, Other: Stage
    ](
        self,
        ref[oo] other: Other,
        out final: Parallel[
            origin=origin_of(Self.origin, oo),
            *_concat_stage_one[Self.elements, Other](),
        ],
    ) where (not Other._IS_PARALLEL) and AllSameStageInput[
        _concat_stage_one[Self.elements, Other]()
    ]:
        """Append another stage to this parallel group without consuming `self`.

        Parameters:
            oo: Origin of `other`.
            Other: Stage type to append.

        Args:
            other: Stage to run concurrently with existing branches.

        Returns:
            A flat `Parallel` stage with `other` appended.
        """
        final = uninitialized_storage[type_of(final)]()
        comptime for i in range(Self.elements.length):
            var ptr = rebind[Pointer[Self.elements[i], Self.origin]](
                self.tasks[i]
            )
            comptime ti = type_of(final.tasks[i])
            Pointer(to=final.tasks[i]).unsafe_write(rebind_var[ti](ptr))
        comptime last_t = type_of(final.tasks[Self.elements.length])
        Pointer(to=final.tasks[Self.elements.length]).unsafe_write(
            rebind_var[last_t](Pointer(to=other))
        )

    def __and__[
        po: ImmOrigin, *other_elems: Stage
    ](
        self,
        other: Parallel[origin=po, *other_elems],
        out final: Parallel[
            origin=origin_of(Self.origin, po),
            *_concat_stage_many[Self.elements, other_elems](),
        ],
    ) where AllSameStageInput[_concat_stage_many[Self.elements, other_elems]()]:
        """Merge another `Parallel` group into this one associatively.

        Parameters:
            po: Origin of the right-hand `Parallel` stage's referenced tasks.
            other_elems: Stages inside the right-hand `Parallel` stage.

        Args:
            other: Right-hand `Parallel` stage to merge with.

        Returns:
            A flat `Parallel` stage containing all branches from both groups.
        """
        final = uninitialized_storage[type_of(final)]()
        comptime for i in range(Self.elements.length):
            var ptr = rebind[Pointer[Self.elements[i], Self.origin]](
                self.tasks[i]
            )
            comptime ti = type_of(final.tasks[i])
            Pointer(to=final.tasks[i]).unsafe_write(rebind_var[ti](ptr))
        comptime for j in range(other_elems.length):
            var ptr = rebind[Pointer[other_elems[j], po]](other.tasks[j])
            comptime tj = type_of(final.tasks[Self.elements.length + j])
            Pointer(to=final.tasks[Self.elements.length + j]).unsafe_write(
                rebind_var[tj](ptr)
            )


@fieldwise_init("implicit")
struct Fn[In: AnyType, Out: Movable & Deinitable](
    ComposableStage, Movable, Copyable
):
    """Wrapper turning a thin function pointer into a `ComposableStage`.

    Parameters:
        In: Function input type.
        Out: Function return type.
    """

    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.In) thin -> Self.Out
    """Wrapped function pointer."""

    def __call__(self, arg: Self.I) -> Self.O:
        """Call the wrapped function with `arg`.

        Args:
            arg: Input argument.

        Returns:
            Result of calling `self.func(arg)`.
        """
        return self.func(arg)


@fieldwise_init("implicit")
struct UnitFn(ComposableStage, Movable, Copyable):
    """Wrapper turning a zero-argument void function into a `ComposableStage`.

    Replaces legacy `strata.void.immutable.Fn` under the unified `|` / `&` API.
    """

    comptime I = NoneType
    """Unit input type."""
    comptime O = NoneType
    """Unit output type."""

    var func: def() thin
    """Wrapped zero-argument function pointer."""

    def __call__(self, arg: Self.I) -> Self.O:
        """Invoke the wrapped zero-argument function.

        Args:
            arg: Unused unit input (`None`).

        Returns:
            `None`.
        """
        self.func()
        return None


# ===----------------------------------------------------------------------=== #
# Value-Owning Pipelines (Factory-Returnable, Zero Dangling Origins)
# ===----------------------------------------------------------------------=== #


struct OwnedSequence[T1: _MovableStage, T2: _MovableStage](Stage, Movable):
    """Value-owning sequential composition of two stages.

    Unlike borrowed `Sequence`, `OwnedSequence` owns its child stages by value
    and can be safely returned from pipeline factory functions.

    Parameters:
        T1: First owned stage type.
        T2: Second owned stage type.
    """

    comptime I = Self.T1.I
    """Input type of the first stage."""
    comptime O = Self.T2.O
    """Output type of the second stage."""

    var t1: Self.T1
    """First owned stage."""
    var t2: Self.T2
    """Second owned stage."""

    def __init__(
        out self, var t1: Self.T1, var t2: Self.T2
    ) where Self.T1.O == Self.T2.I:
        """Initialize with two owned stages.

        Args:
            t1: Owned first stage.
            t2: Owned second stage.
        """
        self.t1 = t1^
        self.t2 = t2^

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute both owned stages sequentially.

        Args:
            arg: Input argument for `t1`.

        Returns:
            Output of `t2`.
        """
        return self.t2(rebind[Self.T2.I](self.t1(arg)))

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute both owned stages sequentially using `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: Input argument for `t1`.

        Returns:
            Output of `t2`.
        """
        var mid = self.t1.run_with(exec, arg)
        return self.t2.run_with(exec, rebind[Self.T2.I](mid))

    def __or__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedSequence[
        Self, Other
    ] where Self.O == Other.I:
        """Pipe this owned sequence into another owned stage.

        Parameters:
            Other: Next owned stage type.

        Args:
            other: Owned next stage.

        Returns:
            An `OwnedSequence` owning both stages.
        """
        return OwnedSequence(self^, other^)

    def __and__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedParallel[
        Self, Other
    ] where (not Other._IS_PARALLEL) and (Self.I == Other.I):
        """Combine this owned sequence with another owned stage in parallel.

        Parameters:
            Other: Parallel owned stage type.

        Args:
            other: Parallel owned stage.

        Returns:
            An `OwnedParallel` owning both stages.
        """
        return OwnedParallel[Self, Other]((self^, other^))

    def __and__[
        *other_elems: _MovableStage
    ](deinit self, var other: OwnedParallel[*other_elems]) -> OwnedParallel[
        *_concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self](), other_elems
        ]()
    ] where _AllSameOwnedInput[
        _concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self](), other_elems
        ]()
    ]:
        """Combine this owned sequence with a right-hand `OwnedParallel`, flattening associatively.

        Parameters:
            other_elems: Owned stages inside the right-hand parallel stage.

        Args:
            other: Right-hand `OwnedParallel` stage.

        Returns:
            Flat `OwnedParallel` containing `self` followed by `other_elems`.
        """
        comptime Res = OwnedParallel[
            *_concat_owned_many[
                TypeList.of[Trait=_MovableStage, Self](), other_elems
            ]()
        ]
        return Res(
            rebind_var[Res.Tasks](Tuple(self^).concat(other^._into_tasks()))
        )


struct OwnedParallel[*elements: _MovableStage](Stage, Movable):
    """Value-owning flat parallel stage executing all branches in one `TaskGroup`.

    Supports full associative flattening on `&` and can be safely returned from
    factory functions.

    Parameters:
        elements: Owned stage types to execute concurrently.
    """

    comptime I = Self.elements[0].I
    """Common input type."""
    comptime _IS_PARALLEL: Bool = True
    """Marks `OwnedParallel` for associative flattening."""
    comptime ResElems = Self.elements.map[_OwnedStageToOut]()
    """Result types of all branches."""
    comptime O = Tuple[*Self.ResElems]
    """Flat tuple output type."""
    comptime Tasks = Tuple[*Self.elements]
    """Tuple of owned stage instances."""

    var tasks: Self.Tasks
    """Tuple storing owned stage instances."""

    def __init__(
        out self, var tasks: Self.Tasks
    ) where _AllSameOwnedInput[Self.elements]:
        """Initialize with a tuple of owned stages.

        Args:
            tasks: Tuple of owned stages.
        """
        self.tasks = tasks^

    def _into_tasks(deinit self) -> Self.Tasks:
        return self.tasks^

    @staticmethod
    __async def _run_elem[
        i: Int,
        task_orig: ImmOrigin,
        in_orig: ImmOrigin,
        out_orig: MutOrigin,
    ](
        task_ptr: Pointer[Self.elements[i], task_orig],
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O.Ts[i], out_orig],
    ):
        comptime to = downcast[Self.O.Ts[i], Movable]
        ref in_value = rebind[Self.elements[i].I](in_ptr[])
        out_ptr.unsafe_bitcast[to]().unsafe_write(
            rebind_var[to](task_ptr[](in_value))
        )

    @staticmethod
    __async def _run_elem_traced[
        i: Int,
        task_orig: ImmOrigin,
        in_orig: ImmOrigin,
        out_orig: MutOrigin,
        t_orig: MutOrigin,
    ](
        task_ptr: Pointer[Self.elements[i], task_orig],
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O.Ts[i], out_orig],
        start_ptr: Pointer[Int, t_orig],
        end_ptr: Pointer[Int, t_orig],
    ):
        comptime to = downcast[Self.O.Ts[i], Movable]
        ref in_value = rebind[Self.elements[i].I](in_ptr[])
        start_ptr[] = perf_counter_ns()
        out_ptr.unsafe_bitcast[to]().unsafe_write(
            rebind_var[to](task_ptr[](in_value))
        )
        end_ptr[] = perf_counter_ns()

    def __call__(self, v: Self.I) -> Self.O:
        """Execute all owned stages concurrently on `v`.

        Args:
            v: Input argument broadcast to all branches.

        Returns:
            Flat tuple of branch outputs.
        """
        var tg = TaskGroup()
        var _out_tp = uninitialized_storage[Self.O]()

        var in_ptr = Pointer(to=v)
        comptime for i in range(Self.elements.length):
            var task_ptr = Pointer(to=self.tasks[i])
            var out_ptr = Pointer(to=_out_tp[i])
            tg.create_task(Self._run_elem[i](task_ptr, in_ptr, out_ptr))

        tg.wait()
        return _out_tp^

    def run_with[E: Executor](self, mut exec: E, v: Self.I) -> Self.O:
        """Execute all owned stages according to executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            v: Input argument broadcast to all branches.

        Returns:
            Flat tuple of branch outputs.
        """
        var _out_tp = uninitialized_storage[Self.O]()
        comptime if not E.IS_PARALLEL:
            comptime for i in range(Self.elements.length):
                comptime to = downcast[Self.O.Ts[i], Movable]
                ref in_value = rebind[Self.elements[i].I](v)
                Pointer(to=_out_tp[i]).unsafe_bitcast[to]().unsafe_write(
                    rebind_var[to](self.tasks[i].run_with(exec, in_value))
                )
            return _out_tp^
        else:
            var limit = exec.concurrency_limit()
            if limit == 1:
                comptime for i in range(Self.elements.length):
                    comptime to = downcast[Self.O.Ts[i], Movable]
                    ref in_value = rebind[Self.elements[i].I](v)
                    Pointer(to=_out_tp[i]).unsafe_bitcast[to]().unsafe_write(
                        rebind_var[to](self.tasks[i].run_with(exec, in_value))
                    )
                return _out_tp^

            var in_ptr = Pointer(to=v)
            var tracing = exec.is_tracing()
            var starts = List[Int](length=Self.elements.length, fill=0)
            var ends = List[Int](length=Self.elements.length, fill=0)
            var wave_size = limit if limit > 0 else Self.elements.length
            var wave_start = 0
            while wave_start < Self.elements.length:
                var wave_end = min(wave_start + wave_size, Self.elements.length)
                var tg = TaskGroup()
                comptime for i in range(Self.elements.length):
                    if i >= wave_start and i < wave_end:
                        var task_ptr = Pointer(to=self.tasks[i])
                        var out_ptr = Pointer(to=_out_tp[i])
                        if tracing:
                            var s_ptr = Pointer(
                                to=starts[i]
                            ).unsafe_origin_cast[MutUntrackedOrigin]()
                            var e_ptr = Pointer(
                                to=ends[i]
                            ).unsafe_origin_cast[MutUntrackedOrigin]()
                            tg.create_task(
                                Self._run_elem_traced[i](
                                    task_ptr, in_ptr, out_ptr, s_ptr, e_ptr
                                )
                            )
                        else:
                            tg.create_task(
                                Self._run_elem[i](task_ptr, in_ptr, out_ptr)
                            )
                tg.wait()
                wave_start = wave_end

            if tracing:
                comptime for i in range(Self.elements.length):
                    exec.record_span(
                        reflect[Self.elements[i]].name(), starts[i], ends[i]
                    )
            return _out_tp^

    def __or__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedSequence[
        Self, Other
    ] where Self.O == Other.I:
        """Pipe this owned parallel stage into another owned stage.

        Parameters:
            Other: Next owned stage type.

        Args:
            other: Owned next stage accepting `Self.O`.

        Returns:
            An `OwnedSequence` owning both stages.
        """
        return OwnedSequence(self^, other^)

    def __and__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedParallel[
        *_concat_owned_one[Self.elements, Other]()
    ] where (not Other._IS_PARALLEL) and _AllSameOwnedInput[
        _concat_owned_one[Self.elements, Other]()
    ]:
        """Append an owned stage to this flat `OwnedParallel` group.

        Parameters:
            Other: Owned stage type to append.

        Args:
            other: Owned stage to execute concurrently.

        Returns:
            Flat `OwnedParallel` with `other` appended.
        """
        comptime Res = OwnedParallel[*_concat_owned_one[Self.elements, Other]()]
        return Res(rebind_var[Res.Tasks](self.tasks^.concat(Tuple(other^))))

    def __and__[
        *other_elems: _MovableStage
    ](deinit self, var other: OwnedParallel[*other_elems]) -> OwnedParallel[
        *_concat_owned_many[Self.elements, other_elems]()
    ] where _AllSameOwnedInput[
        _concat_owned_many[Self.elements, other_elems]()
    ]:
        """Merge another `OwnedParallel` into this one associatively.

        Parameters:
            other_elems: Owned stages inside the right-hand parallel stage.

        Args:
            other: Right-hand `OwnedParallel` stage.

        Returns:
            Single flat `OwnedParallel` containing all branches.
        """
        comptime Res = OwnedParallel[
            *_concat_owned_many[Self.elements, other_elems]()
        ]
        return Res(
            rebind_var[Res.Tasks](self.tasks^.concat(other^._into_tasks()))
        )


struct OwnedGroup[Inner: _MovableStage](Stage, Movable):
    """Value-owning opaque group preventing `&` from flattening `Inner`.

    Parameters:
        Inner: Wrapped owned stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Self.Inner
    """Wrapped owned stage."""

    def __init__(out self, var inner: Self.Inner):
        """Initialize with an owned stage.

        Args:
            inner: Stage to keep grouped.
        """
        self.inner = inner^

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute the wrapped owned stage.

        Args:
            arg: Input argument.

        Returns:
            Wrapped stage output.
        """
        return self.inner(arg)

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute the wrapped owned stage using `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: Input argument.

        Returns:
            Wrapped stage output.
        """
        return self.inner.run_with(exec, arg)

    def __or__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedSequence[
        Self, Other
    ] where Self.O == Other.I:
        """Pipe this opaque owned group into another owned stage.

        Parameters:
            Other: Next owned stage type.

        Args:
            other: Next owned stage.

        Returns:
            An `OwnedSequence` owning both stages.
        """
        return OwnedSequence(self^, other^)

    def __and__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedParallel[
        Self, Other
    ] where (not Other._IS_PARALLEL) and (Self.I == Other.I):
        """Combine this opaque owned group with another owned stage in parallel.

        Parameters:
            Other: Parallel owned stage type.

        Args:
            other: Parallel owned stage.

        Returns:
            An `OwnedParallel` keeping `self` grouped.
        """
        return OwnedParallel[Self, Other]((self^, other^))

    def __and__[
        *other_elems: _MovableStage
    ](deinit self, var other: OwnedParallel[*other_elems]) -> OwnedParallel[
        *_concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self](), other_elems
        ]()
    ] where _AllSameOwnedInput[
        _concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self](), other_elems
        ]()
    ]:
        """Combine this opaque owned group with a right-hand `OwnedParallel`.

        Parameters:
            other_elems: Owned stages inside the right-hand parallel stage.

        Args:
            other: Right-hand `OwnedParallel` stage.

        Returns:
            An `OwnedParallel` keeping `self` grouped plus `other_elems`.
        """
        comptime Res = OwnedParallel[
            *_concat_owned_many[
                TypeList.of[Trait=_MovableStage, Self](), other_elems
            ]()
        ]
        return Res(
            rebind_var[Res.Tasks](Tuple(self^).concat(other^._into_tasks()))
        )


struct Owned[Inner: _MovableStage](Stage, Movable):
    """Value-owning pipeline handle whose `|` and `&` move stages by value.

    Use `owned(stage)` to start a factory-returnable owned pipeline.

    Parameters:
        Inner: Owned stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Self.Inner
    """Owned inner stage."""

    def __init__(out self, var inner: Self.Inner):
        """Initialize an owned pipeline handle.

        Args:
            inner: Stage to own.
        """
        self.inner = inner^

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute the owned pipeline.

        Args:
            arg: Input argument.

        Returns:
            Pipeline output.
        """
        return self.inner(arg)

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute the owned pipeline using `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: Input argument.

        Returns:
            Pipeline output.
        """
        return self.inner.run_with(exec, arg)

    def __or__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedSequence[
        Self.Inner, Other
    ] where Self.O == Other.I:
        """Pipe this owned stage into another owned stage by value.

        Parameters:
            Other: Next owned stage type.

        Args:
            other: Next owned stage.

        Returns:
            An `OwnedSequence` owning both stages.
        """
        return OwnedSequence(self.inner^, other^)

    def __and__[
        Other: _MovableStage
    ](deinit self, var other: Other) -> OwnedParallel[
        Self.Inner, Other
    ] where (not Other._IS_PARALLEL) and (Self.I == Other.I):
        """Combine this owned stage with another owned stage in parallel.

        Parameters:
            Other: Parallel owned stage type.

        Args:
            other: Parallel owned stage.

        Returns:
            An `OwnedParallel` owning both stages.
        """
        return OwnedParallel[Self.Inner, Other]((self.inner^, other^))

    def __and__[
        *other_elems: _MovableStage
    ](deinit self, var other: OwnedParallel[*other_elems]) -> OwnedParallel[
        *_concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self.Inner](), other_elems
        ]()
    ] where _AllSameOwnedInput[
        _concat_owned_many[
            TypeList.of[Trait=_MovableStage, Self.Inner](), other_elems
        ]()
    ]:
        """Combine this owned stage with a right-hand `OwnedParallel`, flattening associatively.

        Parameters:
            other_elems: Owned stages inside the right-hand parallel pipeline.

        Args:
            other: Right-hand `OwnedParallel` pipeline.

        Returns:
            Flat `OwnedParallel` containing `self` followed by `other_elems`.
        """
        comptime Res = OwnedParallel[
            *_concat_owned_many[
                TypeList.of[Trait=_MovableStage, Self.Inner](), other_elems
            ]()
        ]
        return Res(
            rebind_var[Res.Tasks](
                Tuple(self.inner^).concat(other^._into_tasks())
            )
        )


def owned[T: _MovableStage](var stage: T) -> Owned[T]:
    """Lift a movable stage into a value-owning `Owned` pipeline handle.

    Parameters:
        T: Movable stage type.

    Args:
        stage: Stage instance to move into the handle.

    Returns:
        An `Owned[T]` pipeline handle supporting by-value `|` and `&`.
    """
    return Owned(stage^)


def owned_group[T: _MovableStage](var stage: T) -> OwnedGroup[T]:
    """Wrap an owned stage as an opaque `OwnedGroup` to preserve nested tuples.

    Parameters:
        T: Wrapped owned stage type.

    Args:
        stage: Owned stage to keep grouped.

    Returns:
        Opaque `OwnedGroup[T]` handle.
    """
    return OwnedGroup(stage^)


def run_with[
    E: Executor, S: Stage
](mut exec: E, stage: S, arg: S.I) -> S.O:
    """Execute any `Stage` pipeline using a pluggable `Executor`.

    Parameters:
        E: Executor strategy type.
        S: Pipeline stage type.

    Args:
        exec: Executor controlling concurrency and tracing.
        stage: Stage or composite pipeline to execute.
        arg: Input argument.

    Returns:
        Computed pipeline result.
    """
    return stage.run_with(exec, arg)
