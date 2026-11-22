"""Zero-sized compile-time function composition and parallel execution."""

from .._internal.runtime import TaskGroup, uninitialized_storage

comptime FnToOut[Fn: FnTrait] = Fn.O
"""Extract the output type declared by an `FnTrait`.

Parameters:
    Fn: Function trait whose output type is extracted.
"""

comptime FnInputMatch[In: AnyType, Fn: FnTrait] = In == Fn.I
"""Check whether a type matches an `FnTrait` input type.

Parameters:
    In: Type to compare against the stage input.
    Fn: Function trait whose input type is checked.
"""

comptime FnsArePipeable[
    fns: TypeList[Trait=FnTrait, _], Prev: Bool, Elem: FnTrait, Idx: Int
] = Prev and (Elem.O == fns[Idx + 1].I)
"""Check whether adjacent stages in a sequence have matching output/input types.

Parameters:
    fns: Sequence of stages being checked.
    Prev: Accumulated predicate result for earlier pairs.
    Elem: Stage at the current index.
    Idx: Current index in `fns`.
"""

comptime _PickFn[fns: TypeList[Trait=FnTrait, _], Idx: Int]: FnTrait = fns[Idx]

comptime AllPipeable[fns: TypeList[Trait=FnTrait, _]] = TypeList.tabulate[
    fns.length - 1, _PickFn[fns, _]
].reduce_idx[True, FnsArePipeable[fns, ...]]
"""Check whether every adjacent pair in a stage list can be piped.

Parameters:
    fns: Stages to validate in sequential order.
"""

comptime AllSameInput[fns: TypeList[Trait=FnTrait, _]] = fns.all[
    FnInputMatch[fns[0].I, _]
]()
"""Check whether every stage in a list accepts the same input type.

Parameters:
    fns: Stages whose input types are compared.
"""

comptime _concat_one[
    v1: TypeList[Trait=FnTrait, _], v2: FnTrait
] = TypeList._concat[v1.values, TypeList.of[Trait=FnTrait, v2].values]

comptime _concat_many[
    v1: TypeList[Trait=FnTrait, _], v2: TypeList[Trait=FnTrait, _]
] = TypeList._concat[v1.values, v2.values]


trait FnTrait:
    """Trait describing a stateless compile-time pipeline stage."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime F: def(Self.I) thin -> Self.O
    """Runtime entry function pointer for this stage."""
    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `Parallel` stages."""

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the stage at runtime (using parallel TaskGroups where applicable).

        Args:
            inp: Input value.

        Returns:
            Computed stage result.
        """
        ...

    @staticmethod
    def run_sequential(inp: Self.I) -> Self.O:
        """Run the stage purely sequentially without async runtime calls.

        Used for deterministic execution and compile-time evaluation
        (`comptime_run`), including graphs containing `Parallel` stages.

        Args:
            inp: Input value.

        Returns:
            Computed stage result.
        """
        ...


@always_inline
__async def _run_fn_task[
    ci: Int,
    *fns: FnTrait,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_orig],
    out_ptr: Pointer[Tuple[*fns.map[FnToOut]()].Ts[ci], out_orig],
):
    ref inp = rebind[fns[ci].I](in_ptr[])
    out_ptr[] = rebind_var[Tuple[*fns.map[FnToOut]()].Ts[ci]](fns[ci].run(inp))


def par_exec[
    *fns: FnTrait
](val: fns[0].I) -> Tuple[*fns.map[FnToOut]()] where AllSameInput[fns]:
    """Execute multiple compile-time stages concurrently using a `TaskGroup`.

    Parameters:
        fns: Stages to execute concurrently.

    Args:
        val: Input value broadcast to every stage.

    Returns:
        Flat tuple containing each stage's result in stage order.
    """
    var tg = TaskGroup()
    var o = uninitialized_storage[Tuple[*fns.map[FnToOut]()]]()

    var in_ptr = Pointer(to=val)
    comptime for ci in range(fns.length):
        var out_ptr = Pointer(to=o[ci])
        tg.create_task(_run_fn_task[ci, *fns](in_ptr, out_ptr))
    tg.wait()
    return o^


def par_exec_sequential[
    *fns: FnTrait
](val: fns[0].I) -> Tuple[*fns.map[FnToOut]()] where AllSameInput[fns]:
    """Execute multiple compile-time stages sequentially into a flat tuple.

    Safe to call during compile-time evaluation (`comptime_run`) because it
    makes no external async runtime calls.

    Parameters:
        fns: Stages to execute.

    Args:
        val: Input value passed to each stage.

    Returns:
        Flat tuple containing each stage's result in stage order.
    """
    var o = uninitialized_storage[Tuple[*fns.map[FnToOut]()]]()
    comptime for ci in range(fns.length):
        ref inp = rebind[fns[ci].I](val)
        o[ci] = rebind_var[Tuple[*fns.map[FnToOut]()].Ts[ci]](
            fns[ci].run_sequential(inp)
        )
    return o^


def _seq_exec_tail[
    ci: Int,
    *fns: FnTrait,
](var inp: fns[ci - 1].O) -> fns[fns.length - 1].O where AllPipeable[fns]:
    var out = fns[ci].run(rebind[fns[ci].I](inp))
    deinit(inp^)
    comptime if ci + 1 == fns.length:
        return rebind_var[fns[fns.length - 1].O](out^)
    else:
        return _seq_exec_tail[ci + 1, *fns](out^)


def seq_exec[
    *fns: FnTrait
](val: fns[0].I) -> fns[fns.length - 1].O where AllPipeable[fns]:
    """Execute multiple compile-time stages sequentially at runtime.

    Parameters:
        fns: Stages to execute in order.

    Args:
        val: Input value passed to the first stage.

    Returns:
        Result returned by the final stage.
    """
    var first = fns[0].run(val)
    comptime if fns.length == 1:
        return rebind_var[fns[fns.length - 1].O](first^)
    else:
        return _seq_exec_tail[1, *fns](first^)


def _seq_exec_sequential_tail[
    ci: Int,
    *fns: FnTrait,
](var inp: fns[ci - 1].O) -> fns[fns.length - 1].O where AllPipeable[fns]:
    var out = fns[ci].run_sequential(rebind[fns[ci].I](inp))
    deinit(inp^)
    comptime if ci + 1 == fns.length:
        return rebind_var[fns[fns.length - 1].O](out^)
    else:
        return _seq_exec_sequential_tail[ci + 1, *fns](out^)


def seq_exec_sequential[
    *fns: FnTrait
](val: fns[0].I) -> fns[fns.length - 1].O where AllPipeable[fns]:
    """Execute multiple compile-time stages sequentially without async runtime.

    Parameters:
        fns: Stages to execute in order.

    Args:
        val: Input value passed to the first stage.

    Returns:
        Result returned by the final stage.
    """
    var first = fns[0].run_sequential(val)
    comptime if fns.length == 1:
        return rebind_var[fns[fns.length - 1].O](first^)
    else:
        return _seq_exec_sequential_tail[1, *fns](first^)


def _call_unit[Func: def() thin](val: NoneType) -> NoneType:
    Func()
    return None


comptime F[
    In: AnyType, Out: Movable & Deinitable, //, Func: def(In) thin -> Out
] = Function[Func]()
"""Shorthand alias to instantiate a compile-time `Function` stage.

Parameters:
    In: Function input type.
    Out: Function output type.
    Func: Thin function to wrap.
"""

comptime Unit[Func: def() thin] = Function[_call_unit[Func]]()
"""Shorthand alias to wrap a zero-argument void function as a compile-time stage.

Replaces legacy `strata.void.type` with the unified `|` / `&` pipeline algebra.

Parameters:
    Func: Zero-argument thin function to wrap.
"""


def group[Inner: FnTrait](inner: Inner) -> Group[Inner]:
    """Wrap a stage as an opaque group so `&` preserves nested tuple structure.

    For example, `group(a & b) & group(c & d)` produces
    `Tuple[Tuple[O1, O2], Tuple[O3, O4]]` instead of flattening to a 4-tuple.

    Parameters:
        Inner: Type of the wrapped stage.

    Args:
        inner: Stage to wrap.

    Returns:
        Opaque `Group` stage.
    """
    return {}


@fieldwise_init
struct Function[
    In: AnyType, Out: Movable & Deinitable, //, Func: def(In) thin -> Out
](FnTrait, TrivialRegisterPassable):
    """Wrap a thin function as a zero-sized compile-time pipeline stage.

    Parameters:
        In: Function input type.
        Out: Function output type.
        Func: Thin function to wrap.
    """

    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""
    comptime F = Self.Func
    """Underlying function pointer."""

    comptime comptime_run[value: Self.I]: Self.O = Self.run_sequential(value)
    """Evaluate this stage at compile time.

    Parameters:
        value: Compile-time input value.
    """

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the wrapped function at runtime.

        Args:
            inp: Input value.

        Returns:
            Function output.
        """
        return Self.Func(inp)

    @staticmethod
    def run_sequential(inp: Self.I) -> Self.O:
        """Run the wrapped function sequentially.

        Args:
            inp: Input value.

        Returns:
            Function output.
        """
        return Self.Func(inp)

    def __call__(self, inp: Self.I) -> Self.O:
        """Invoke this stage at runtime.

        Args:
            inp: Input value.

        Returns:
            Function output.
        """
        return Self.run(inp)

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.In == Other.I):
        """Combine this function with another stage in parallel.

        Parameters:
            Other: Parallel stage type.

        Args:
            other: Stage to execute concurrently.

        Returns:
            A `Parallel` pipeline combining `self` and `other`.
        """
        return {}

    def __and__[
        *other_fns: FnTrait
    ](self, other: Parallel[*other_fns]) -> Parallel[
        *_concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ] where AllSameInput[other_fns] and AllSameInput[
        _concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ]:
        """Combine this function with a `Parallel` stage, flattening associatively.

        Parameters:
            other_fns: Stages inside the right-hand `Parallel` pipeline.

        Args:
            other: Parallel pipeline to merge with.

        Returns:
            A flat `Parallel` pipeline containing `self` followed by `other_fns`.
        """
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[Self, Other] where Self.Out == Other.I:
        """Pipe this function into another stage sequentially.

        Parameters:
            Other: Next stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A `Sequence` pipeline combining `self` and `other`.
        """
        return {}


@fieldwise_init
struct Group[Inner: FnTrait](FnTrait, TrivialRegisterPassable):
    """Opaque wrapper preventing `&` from flattening an inner `Parallel` stage.

    Parameters:
        Inner: Wrapped stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""
    comptime F = Self.run
    """Underlying runtime entry function pointer."""

    comptime comptime_run[value: Self.I]: Self.O = Self.run_sequential(value)
    """Evaluate this grouped stage at compile time.

    Parameters:
        value: Compile-time input value.
    """

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the wrapped stage at runtime.

        Args:
            inp: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.Inner.run(inp)

    @staticmethod
    def run_sequential(inp: Self.I) -> Self.O:
        """Run the wrapped stage sequentially.

        Args:
            inp: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.Inner.run_sequential(inp)

    def __call__(self, inp: Self.I) -> Self.O:
        """Invoke this grouped stage at runtime.

        Args:
            inp: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.run(inp)

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this opaque group with another stage in parallel.

        Parameters:
            Other: Parallel stage type.

        Args:
            other: Stage to execute concurrently.

        Returns:
            A `Parallel` pipeline keeping `self` as a single grouped branch.
        """
        return {}

    def __and__[
        *other_fns: FnTrait
    ](self, other: Parallel[*other_fns]) -> Parallel[
        *_concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ] where AllSameInput[other_fns] and AllSameInput[
        _concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ]:
        """Combine this opaque group with a right-hand `Parallel` stage.

        Parameters:
            other_fns: Stages inside the right-hand `Parallel` pipeline.

        Args:
            other: Parallel pipeline to merge with.

        Returns:
            A `Parallel` pipeline with `self` as one grouped branch plus `other_fns`.
        """
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[Self, Other] where Self.O == Other.I:
        """Pipe this grouped stage into the next stage sequentially.

        Parameters:
            Other: Next stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A `Sequence` pipeline combining `self` and `other`.
        """
        return {}


@fieldwise_init
struct Parallel[*fns: FnTrait](FnTrait, TrivialRegisterPassable) where AllSameInput[
    fns
]:
    """Execute multiple compile-time stages concurrently in one flat `TaskGroup`.

    Parameters:
        fns: Stages to execute concurrently; all must accept the same input type.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime _IS_PARALLEL: Bool = True
    """Marks `Parallel` for associative flattening."""
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    """Flat tuple output type."""
    comptime F = par_exec[*Self.fns]
    """Runtime entry function pointer executing all stages concurrently."""

    comptime comptime_run[value: Self.I]: Self.O = Self.run_sequential(value)
    """Evaluate all parallel branches sequentially at compile time.

    Parameters:
        value: Compile-time input value.
    """

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run all branches concurrently at runtime.

        Args:
            val: Input value passed to every branch.

        Returns:
            Flat tuple containing each branch's result in order.
        """
        return par_exec[*Self.fns](val)

    @staticmethod
    def run_sequential(val: Self.I) -> Self.O:
        """Run all branches sequentially without async runtime calls.

        Args:
            val: Input value passed to every branch.

        Returns:
            Flat tuple containing each branch's result in order.
        """
        return par_exec_sequential[*Self.fns](val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke all branches concurrently at runtime.

        Args:
            val: Input value passed to every branch.

        Returns:
            Flat tuple containing each branch's result in order.
        """
        return Self.run(val)

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[
        *_concat_one[Self.fns, Other]()
    ] where (not Other._IS_PARALLEL) and AllSameInput[
        _concat_one[Self.fns, Other]()
    ]:
        """Append another stage to this parallel group.

        Parameters:
            Other: Stage type to append.

        Args:
            other: Stage to execute concurrently.

        Returns:
            A flat `Parallel` pipeline with `other` appended.
        """
        return {}

    def __and__[
        *other_fns: FnTrait
    ](self, other: Parallel[*other_fns]) -> Parallel[
        *_concat_many[Self.fns, other_fns]()
    ] where AllSameInput[other_fns] and AllSameInput[
        _concat_many[Self.fns, other_fns]()
    ]:
        """Merge another `Parallel` group into this one associatively.

        Parameters:
            other_fns: Stages inside the right-hand `Parallel` pipeline.

        Args:
            other: Parallel pipeline to merge with.

        Returns:
            A single flat `Parallel` pipeline containing all branches from both.
        """
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[Self, Other] where Self.O == Other.I:
        """Pipe this parallel stage's tuple output into the next stage.

        Parameters:
            Other: Next stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A `Sequence` pipeline combining `self` and `other`.
        """
        return {}


@fieldwise_init
struct Sequence[*fns: FnTrait](FnTrait, TrivialRegisterPassable) where AllPipeable[
    fns
]:
    """Execute multiple compile-time stages sequentially.

    Parameters:
        fns: Stages to execute in order; each output must match the next input.
    """

    comptime I = Self.fns[0].I
    """Input type of the first stage."""
    comptime O = Self.fns[Self.fns.length - 1].O
    """Output type of the final stage."""
    comptime F = seq_exec[*Self.fns]
    """Runtime entry function pointer executing all stages in sequence."""

    comptime comptime_run[value: Self.I]: Self.O = Self.run_sequential(value)
    """Evaluate this entire sequential pipeline at compile time.

    Parameters:
        value: Compile-time input value.
    """

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run the sequential pipeline at runtime.

        Args:
            val: Input value passed to the first stage.

        Returns:
            Result returned by the final stage.
        """
        return seq_exec[*Self.fns](val)

    @staticmethod
    def run_sequential(val: Self.I) -> Self.O:
        """Run the sequential pipeline without async runtime calls.

        Args:
            val: Input value passed to the first stage.

        Returns:
            Result returned by the final stage.
        """
        return seq_exec_sequential[*Self.fns](val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke the sequential pipeline at runtime.

        Args:
            val: Input value passed to the first stage.

        Returns:
            Result returned by the final stage.
        """
        return Self.run(val)

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this sequence in parallel with another stage.

        Parameters:
            Other: Parallel stage type.

        Args:
            other: Stage to execute concurrently.

        Returns:
            A `Parallel` pipeline combining `self` and `other`.
        """
        return {}

    def __and__[
        *other_fns: FnTrait
    ](self, other: Parallel[*other_fns]) -> Parallel[
        *_concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ] where AllSameInput[other_fns] and AllSameInput[
        _concat_many[TypeList.of[Trait=FnTrait, Self](), other_fns]()
    ]:
        """Combine this sequence with a `Parallel` pipeline, flattening associatively.

        Parameters:
            other_fns: Stages inside the right-hand `Parallel` pipeline.

        Args:
            other: Parallel pipeline to merge with.

        Returns:
            A flat `Parallel` pipeline containing `self` followed by `other_fns`.
        """
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[
        *_concat_one[Self.fns, Other]()
    ] where AllPipeable[_concat_one[Self.fns, Other]()]:
        """Pipe this sequential pipeline into another stage.

        Parameters:
            Other: Next stage type.

        Args:
            other: Next stage to execute.

        Returns:
            A flat `Sequence` pipeline with `other` appended.
        """
        return {}
