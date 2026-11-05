from std.runtime._asyncrt import Task, TaskGroup
from std.iter import downcast
from std.builtin.variadics import _MLIR

comptime FnToOut[Fn: FnTrait] = Fn.O

comptime FnInputMatch[In: AnyType, Fn: FnTrait] = In == Fn.I

comptime FnsArePipeable[
    fns: TypeList[Trait=FnTrait, _], Prev: Bool, Elem: FnTrait, Idx: Int
] = Prev and (Elem.O == fns[Idx + 1].I)

# Checks adjacent pairs only: reduces over fns[0 : length - 1], so that
# `fns[Idx + 1]` is always in range. Empty/1-element lists yield True.
comptime _PickFn[fns: TypeList[Trait=FnTrait, _], Idx: Int]: FnTrait = fns[Idx]

comptime AllPipeable[fns: TypeList[Trait=FnTrait, _]] = TypeList.tabulate[
    fns.length - 1, _PickFn[fns, _]
].reduce_idx[True, FnsArePipeable[fns, ...]]

comptime AllSameInput[fns: TypeList[Trait=FnTrait, _]] = fns.all[
    FnInputMatch[fns[0].I, _]
]()

comptime concat[
    Tr: type_of(AnyType), //, v1: TypeList[Trait=Tr, _], v2: Tr
] = TypeList._concat[v1.values, TypeList.of[v2].values]


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


struct Pipe:
    comptime parallel[
        I: AnyType, O: Movable & Deinitable, //, func: def(I) thin -> O
    ] = Parallel[Function[func]]
    comptime sequence[
        I: AnyType, O: Movable & Deinitable, //, func: def(I) thin -> O
    ] = Sequence[Function[func]]


struct Parallel[*fns: FnTrait](FnTrait) where AllSameInput[fns]:
    """Parallel execution of multiple functions."""

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    """Tuple output type."""
    comptime F = par_exec[*Self.fns]

    comptime add[
        I: AnyType, O: Movable & Deinitable, //, other: def(I) thin -> O
    ] where AllSameInput[concat[Self.fns, Function[other]]()] = Parallel[
        *concat[Self.fns, Function[other]]()
    ]

    comptime handover: def(Self.I) thin -> Self.O = par_exec[*Self.fns]

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run the parallel group at runtime."""
        return par_exec[*Self.fns](val)


struct Sequence[*fns: FnTrait](FnTrait) where AllPipeable[fns]:
    """Parallel execution of multiple functions."""

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Self.fns[Self.fns.length - 1].O
    """Tuple output type."""
    comptime F = seq_exec[*Self.fns]

    comptime add[
        I: AnyType, O: Movable & Deinitable, //, other: def(I) thin -> O
    ] where AllPipeable[concat[Self.fns, Function[other]]()] = Sequence[
        *concat[Self.fns, Function[other]]()
    ]

    comptime handover: def(Self.I) thin -> Self.O = seq_exec[*Self.fns]

    @staticmethod
    def run(val: Self.I) -> Self.O:
        """Run the parallel group at runtime."""
        return seq_exec[*Self.fns](val)


trait FnTrait:
    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime F: def(Self.I) thin -> Self.O

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the function at runtime.

        Args:
            inp: Input value.

        Returns:
            Result of the function.
        """
        ...


struct Function[
    In: AnyType,
    Out: Movable & Deinitable,
    //,
    Func: def(In) thin -> Out,
](FnTrait):
    comptime I = Self.In
    """Input type."""
    comptime O = Self.Out
    """Output type."""
    comptime F = Self.Func

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the function at runtime.

        Args:
            inp: Input value.

        Returns:
            Result of the function.
        """
        return Self.F(inp)
