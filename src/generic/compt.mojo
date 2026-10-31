"""Compile-time function composition and parallel execution."""

from std.runtime._asyncrt import Task, TaskGroup

comptime FnToOut[f: FnTrait] = f.O
"""Extract output type from an FnTrait.

Parameters:
    f: The FnTrait type.
"""

comptime FnInputMatch[I: AnyType, T: FnTrait] = I == T.I
"""Check if FnTrait input matches type I.

Parameters:
    I: The input type to check.
    T: The FnTrait to inspect.
"""


trait FnTrait(Movable, TrivialRegisterPassable):
    """Trait representing a function with compile-time metadata."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime F: def(Self.I) thin -> Self.O
    """Underlying function pointer."""

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Execute the function.

        Args:
            inp: Function input argument.

        Returns:
            Computed output.
        """
        ...


def seq_fn[
    In: AnyType,
    M: Deinitable,
    O: AnyType,
    //,
    f: def(In) thin -> M,
    l: def(M) thin -> O,
](val: In) -> O:
    """Execute two functions sequentially.

    Parameters:
        In: Input type.
        M: Intermediate type.
        O: Output type.
        f: First function.
        l: Second function.

    Args:
        val: Input value.

    Returns:
        Computed result.
    """
    return l(f(val))


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


def par_fns[
    *fns: FnTrait
](val: fns[0].I, out o: Tuple[*fns.map[FnToOut]()]) where fns.all[
    FnInputMatch[fns[0].I, _]
]():
    """Execute multiple compile-time functions in parallel using a TaskGroup.

    Parameters:
        fns: Functions to execute in parallel.

    Args:
        val: Broadcast input argument.

    Returns:
        Tuple of outputs from all functions.
    """
    var tg = TaskGroup()
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o))

    var in_ptr = Pointer(to=val)
    comptime for ci in range(fns.length):
        var out_ptr = Pointer(to=o[ci])
        tg.create_task(_run_fn_task[ci, *fns](in_ptr, out_ptr))
    tg.wait()


@fieldwise_init
struct F[i: AnyType, o: Movable & Deinitable, //, f: def(i) thin -> o](FnTrait):
    """Compile-time function wrapper.

    Parameters:
        i: Input type.
        o: Output type.
        f: Underlying function.
    """

    comptime I = Self.i
    """Input type."""
    comptime O = Self.o
    """Output type."""
    comptime F = Self.f
    """Function pointer."""

    comptime seq[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.o) thin -> other_o,
    ] = F[seq_fn[Self.f, other_f]]
    """Sequence this function with another function at compile time.

    Parameters:
        other_o: Return type of other function.
        other_f: Function to sequence after this one.
    """

    comptime par[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.i) thin -> other_o,
    ] = FG[Self, F[other_f]]
    """Combine this function in parallel with another function at compile time.

    Parameters:
        other_o: Return type of other function.
        other_f: Function to run in parallel with this one.
    """

    comptime comptime_run[i: Self.i] = Self.f(i)
    """Execute function at compile time.

    Parameters:
        i: Input value known at compile time.
    """

    @staticmethod
    def run(inp: Self.i) -> Self.o:
        """Run the function at runtime.

        Args:
            inp: Input value.

        Returns:
            Result of the function.
        """
        return Self.f(inp)


@fieldwise_init
struct FG[*fns: FnTrait] where fns.all[FnInputMatch[fns[0].I, _]]():
    """Group of compile-time functions executed in parallel.

    Parameters:
        fns: Functions in the group.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    """Tuple of output types."""
    comptime F = par_fns[*Self.fns]
    """Parallel execution function pointer."""

    comptime seq[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.O) thin -> other_o,
    ] = F[seq_fn[Self.F, other_f]]
    """Sequence this group with another function at compile time.

    Parameters:
        other_o: Return type of other function.
        other_f: Function to sequence after this group.
    """

    comptime par[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.I) thin -> other_o,
    ] where TypeList._concat[
        Self.fns.values, TypeList.of[F[other_f]].values
    ]().all[
        FnInputMatch[
            TypeList._concat[Self.fns.values, TypeList.of[F[other_f]].values]()[
                0
            ].I,
            _,
        ]
    ]() = FG[
        *TypeList._concat[Self.fns.values, TypeList.of[F[other_f]].values]()
    ]
    """Add another function to this parallel group at compile time.

    Parameters:
        other_o: Return type of other function.
        other_f: Function to run in parallel.
    """

    comptime comptime_run[i: Self.I] = Self.F(i)
    """Execute parallel group at compile time.

    Parameters:
        i: Input value known at compile time.
    """

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        """Run the parallel group at runtime.

        Args:
            inp: Input value.

        Returns:
            Tuple of results.
        """
        return Self.F(inp)
