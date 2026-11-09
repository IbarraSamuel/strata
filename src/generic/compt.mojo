"""Compile-time function composition and parallel execution."""

from std.runtime._asyncrt import Task, TaskGroup
from std.iter import downcast
from std.builtin.variadics import _MLIR

comptime FnToOut[Fn: FnTrait] = Fn.O
"""Get the output type declared by an FnTrait.

Parameters:
    Fn: Function trait whose output type is returned.
"""

comptime FnInputMatch[In: AnyType, Fn: FnTrait] = In == Fn.I
"""Check whether a type matches an FnTrait input type.

Parameters:
    In: Type to compare with the function input.
    Fn: Function trait whose input type is checked.
"""

comptime FnsArePipeable[
    fns: TypeList[Trait=FnTrait, _], Prev: Bool, Elem: FnTrait, Idx: Int
] = Prev and (Elem.O == fns[Idx + 1].I)
"""Check whether adjacent functions in a sequence can be composed.

Parameters:
    fns: Sequence of functions being checked.
    Prev: Whether all earlier adjacent functions were pipeable.
    Elem: Function at the current position.
    Idx: Index of the current function.
"""

# Checks adjacent pairs only: reduces over fns[0 : length - 1], so that
# `fns[Idx + 1]` is always in range. Empty/1-element lists yield True.
comptime _PickFn[fns: TypeList[Trait=FnTrait, _], Idx: Int]: FnTrait = fns[Idx]

comptime AllPipeable[fns: TypeList[Trait=FnTrait, _]] = TypeList.tabulate[
    fns.length - 1, _PickFn[fns, _]
].reduce_idx[True, FnsArePipeable[fns, ...]]
"""Check whether every adjacent pair in a function list is pipeable.

Parameters:
    fns: Functions to check in sequence.
"""

comptime AllSameInput[fns: TypeList[Trait=FnTrait, _]] = fns.all[
    FnInputMatch[fns[0].I, _]
]()
"""Check whether every function in a list accepts the same input type.

Parameters:
    fns: Functions whose input types are compared.
"""

comptime concat[
    Tr: type_of(AnyType), //, v1: TypeList[Trait=Tr, _], v2: Tr
] = TypeList._concat[v1.values, TypeList.of[v2].values]
"""Append one value to a TypeList's values.

Parameters:
    Tr: Trait of the values being concatenated.
    v1: TypeList whose values form the first part of the result.
    v2: Value appended to the TypeList.
"""


# __enum Mode(Equatable):
#     case Parallel
#     case Sequential


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
    """Execute multiple compile-time functions in parallel using a TaskGroup.

    Parameters:
        fns: Functions to execute in parallel.

    Args:
        val: Input value passed to every function.

    Returns:
        Tuple containing each function's result, in function order.
    """
    var tg = TaskGroup()

    var o: Tuple[*fns.map[FnToOut]()]
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o))

    var in_ptr = Pointer(to=val)
    comptime for ci in range(fns.length):
        var out_ptr = Pointer(to=o[ci])
        tg.create_task(_run_fn_task[ci, *fns](in_ptr, out_ptr))
    tg.wait()
    return o^


def seq_exec[
    *fns: FnTrait
](val: fns[0].I) -> fns[fns.length - 1].O where AllPipeable[fns]:
    """Execute multiple compile-time functions sequentially.

    Parameters:
        fns: Functions to execute sequentially.

    Args:
        val: Input value passed to the first function.

    Returns:
        Result returned by the final function.
    """
    var _fr = fns[0].run(val)
    var res = (
        Pointer(to=_fr)
        .unsafe_bitcast[NoneType]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )

    comptime for ci in range(1, fns.length):
        var inp = res.unsafe_bitcast[
            downcast[fns[ci].I, Deinitable & Movable]
        ]().unsafe_take_pointee()
        var r = fns[ci].run(inp)
        deinit(inp^)
        res = (
            Pointer(to=r)
            .unsafe_bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
    return res.unsafe_bitcast[fns[fns.length - 1].O]().unsafe_take_pointee()


# struct Graph[]:
#     comptime add[
#         In: AnyType, Out: Movable & Deinitable, //, v: def(In) thin -> Out
#     ] = F[In, Out](v)
#     comptime add[
#         In: AnyType, Out: Movable & Deinitable, //, v: def(In) thin -> Out
#     ] where  = F[In, Out](v)


# comptime mapper[
#     In: TypeList[...],
#     Out: TypeList[...],
#     Idx: Int,
# ]: AnyType = def(In[Idx]) thin -> Out[Idx]

# comptime fn_types[In: TypeList[...], Out: TypeList[...]] = (
#     In.tabulate[In.length, mapper[In, Out, _]]
# )


# struct AcceptFns[
#     _in: TypeList[...],
#     _out: TypeList[...],
#     *fns: fn_types[_in, _out],
# ]:
#     pass

comptime F[
    In: AnyType, Out: Movable & Deinitable, //, Func: def(In) thin -> Out
] = Function[Func]()


@fieldwise_init
struct Function[
    In: AnyType, Out: Movable & Deinitable, //, Func: def(In) thin -> Out
](FnTrait):
    """Wrap a function with compile-time input and output type metadata.

    Parameters:
        In: Function input type.
        Out: Function output type.
        Func: Function to wrap.
    """

    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""
    comptime F = Self.Func
    """Underlying function pointer."""

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the function at runtime.

        Args:
            inp: Input value.

        Returns:
            Result of the function.
        """
        return Self.F(inp)

    comptime pipe[
        O: Movable & Deinitable, //, other: def(Self.Out) thin -> O
    ] = Sequence[Self, Function[other]]
    """Create a sequential pipeline containing one function.

    Parameters:
        O: Output type returned by the function.
        other: Function to include.
    """

    comptime `and`[
        O: Movable & Deinitable, //, other: def(Self.In) thin -> O
    ] = Parallel[Self, Function[other]]
    """Create a parallel pipeline containing one function.

    Parameters:
        O: Output type returned by the function.
        other: Function to include.
    """

    comptime take: def(Self.In) thin -> Self.Out = Self.Func
    """Function pointer for handing this pipeline to another pipeline."""

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[Self, Other] where Self.In == Other.I:
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[Self, Other] where Self.Out == Other.I:
        return {}


@fieldwise_init
struct Parallel[*fns: FnTrait](FnTrait) where AllSameInput[fns]:
    """Execute multiple functions concurrently.

    Parameters:
        fns: Functions to execute concurrently; each must accept the same input type.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    """Tuple output type."""
    comptime F = par_exec[*Self.fns]
    """Function that executes all stages concurrently."""

    comptime `and`[
        I: AnyType, O: Movable & Deinitable, //, other: def(I) thin -> O
    ] where AllSameInput[concat[Self.fns, Function[other]]()] = Parallel[
        *concat[Self.fns, Function[other]]()
    ]
    """Return a parallel pipeline with another function appended concurrently.

    Parameters:
        I: Input type accepted by the added function.
        O: Output type returned by the added function.
        other: Function to execute in parallel with the existing functions.
    """

    comptime take: def(Self.I) thin -> Self.O = par_exec[*Self.fns]
    """Function pointer for handing this pipeline to another pipeline."""

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[
        *concat[Self.fns, Other]()
    ] where AllSameInput[concat[Self.fns, Other]()]:
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[Self, Other] where Self.O == Other.I:
        return {}

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run the parallel group at runtime.

        Args:
            val: Input value passed to every function.

        Returns:
            Tuple containing each function's result, in function order.
        """
        return par_exec[*Self.fns](val)


@fieldwise_init
struct Sequence[*fns: FnTrait](FnTrait) where AllPipeable[fns]:
    """Execute multiple functions sequentially.

    Parameters:
        fns: Functions to execute in order; each output must match the next input.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Self.fns[Self.fns.length - 1].O
    """Output type of the final function."""
    comptime F = seq_exec[*Self.fns]
    """Function that executes all stages in sequence."""

    comptime pipe[
        I: AnyType, O: Movable & Deinitable, //, other: def(I) thin -> O
    ] where AllPipeable[concat[Self.fns, Function[other]]()] = Sequence[
        *concat[Self.fns, Function[other]]()
    ]
    """Return a sequential pipeline with another function piped.

    Parameters:
        I: Input type accepted by the added function.
        O: Output type returned by the added function.
        other: Function to execute after the existing functions.
    """

    comptime take: def(Self.I) thin -> Self.O = seq_exec[*Self.fns]
    """Function pointer for handing this pipeline to another pipeline."""

    def __and__[
        Other: FnTrait, //
    ](self, other: Other) -> Parallel[Self, Other] where Self.I == Other.I:
        return {}

    def __or__[
        Other: FnTrait, //
    ](self, other: Other) -> Sequence[
        *concat[Self.fns, Other]()
    ] where AllPipeable[concat[Self.fns, Other]()]:
        return {}

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run the sequential pipeline at runtime.

        Args:
            val: Input value passed to the first function.

        Returns:
            Result returned by the final function.
        """
        return seq_exec[*Self.fns](val)


trait FnTrait:
    """Trait describing a function using compile-time input and output types."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime F: def(Self.I) thin -> Self.O
    """Underlying function pointer."""

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the function at runtime.

        Args:
            inp: Input value.

        Returns:
            Result of the function.
        """
        ...
