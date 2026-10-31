"""Asynchronous function composition and parallel execution."""

from std.runtime._asyncrt import TaskGroup, _run

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
    """Trait representing a callable async function stage."""

    comptime I: TrivialRegisterPassable
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""

    @staticmethod
    __async def run(val: Self.I) -> Self.O:
        """Run the async stage with the provided input.

        Args:
            val: Input value.

        Returns:
            Computed output.
        """
        ...


@always_inline
__async def _run_fn_task[
    ci: Int,
    *fns: FnTrait,
    in_origin: ImmOrigin,
    out_origin: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_origin],
    out_ptr: Pointer[Tuple[*fns.map[FnToOut]()].Ts[ci], out_origin],
):
    var inp = rebind[fns[ci].I](in_ptr[])
    out_ptr[] = rebind_var[Tuple[*fns.map[FnToOut]()].Ts[ci]](
        __await fns[ci].run(inp)
    )


def par_fns[
    *fns: FnTrait
](val: fns[0].I, out o: Tuple[*fns.map[FnToOut]()]):
    """Execute multiple async functions concurrently in a TaskGroup.

    Parameters:
        fns: The list of FnTrait types to execute.

    Args:
        val: The input value broadcast to all functions.

    Returns:
        Tuple containing the results of each function.
    """
    var tg = TaskGroup()
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o))

    var in_ptr = Pointer(to=val)
    comptime for ci in range(fns.length):
        var out_ptr = Pointer(to=o[ci])
        tg.create_task(_run_fn_task[ci, *fns](in_ptr, out_ptr))
    tg.wait()


@always_inline("nodebug")
def par_fn[
    In: TrivialRegisterPassable,
    O1: TrivialRegisterPassable,
    O2: TrivialRegisterPassable,
    //,
    f: __async def(In) thin -> O1,
    l: __async def(In) thin -> O2,
](val: In, out o: Tuple[O1, O2]):
    """Execute two async functions concurrently.

    Parameters:
        In: Input type.
        O1: First function return type.
        O2: Second function return type.
        f: First async function.
        l: Second async function.

    Args:
        val: Input value.

    Returns:
        Tuple of both function outputs.
    """
    o = par_fns[Fn[f], Fn[l]](val)


@always_inline("nodebug")
__async def seq_fn[
    In: TrivialRegisterPassable,
    Om: TrivialRegisterPassable,
    O: Movable & Deinitable,
    //,
    f: __async def(In) thin -> Om,
    l: __async def(Om) thin -> O,
](val: In) -> O:
    """Execute two async functions sequentially.

    Parameters:
        In: Input type.
        Om: Intermediate type.
        O: Final return type.
        f: First async function.
        l: Second async function.

    Args:
        val: Input value.

    Returns:
        Result of the second async function.
    """
    var r1 = __await f(val)
    return __await l(r1)


struct Fn[
    i: TrivialRegisterPassable,
    o: TrivialRegisterPassable,
    //,
    F: __async def(i) thin -> o,
](FnTrait, TrivialRegisterPassable):
    """Async function wrapper.

    Parameters:
        i: Input type.
        o: Output type.
        F: The async thin function.
    """

    comptime I = Self.i
    """Input type."""
    comptime O = Self.o
    """Output type."""

    @always_inline("builtin")
    def __init__(out self):
        """Construct an empty Fn instance."""
        pass

    @staticmethod
    __async def run(val: Self.I) -> Self.O:
        """Run the wrapped async function statically.

        Args:
            val: Input value.

        Returns:
            Result of async function.
        """
        return __await Self.F(val)

    def run(self, val: Self.I) -> Self.O:
        """Run the wrapped async function synchronously using the event loop.

        Args:
            val: Input value.

        Returns:
            Result of async function.
        """
        var result = _run(Self.F(val))
        return result

    @always_inline("builtin")
    def __rshift__(
        self, other: Fn[i=Self.o, _]
    ) -> Fn[seq_fn[Self.F, other.F]]:
        """Sequence two async functions.

        Args:
            other: Next async function.

        Returns:
            A new Fn executing self then other.
        """
        return {}

    @always_inline("builtin")
    def __add__(
        self, other: Fn[i=Self.i, _]
    ) -> Parallel[Self, type_of(other)]:
        """Combine two async functions in parallel.

        Args:
            other: Parallel async function.

        Returns:
            A Parallel stage running both.
        """
        return {}

    @always_inline("builtin")
    def __add__[*other_fns: FnTrait](
        self, other: Parallel[*other_fns]
    ) -> Parallel[*TypeList._concat[TypeList.of[Trait=FnTrait, Self].values, other_fns.values]()]:
        """Combine this function with a parallel group.

        Parameters:
            other_fns: Functions in the parallel group.

        Args:
            other: Parallel stage.

        Returns:
            A new combined Parallel stage.
        """
        return {}


struct Parallel[*fns: FnTrait](TrivialRegisterPassable):
    """Parallel group of async functions.

    Parameters:
        fns: Variadic list of FnTraits to execute in parallel.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    """Tuple output type."""

    @always_inline("builtin")
    def __init__(out self):
        """Initialize an empty Parallel instance."""
        pass

    def run(self, val: Self.I) -> Self.O:
        """Run all parallel functions concurrently on val.

        Args:
            val: Input value.

        Returns:
            Tuple of outputs.
        """
        return par_fns[*Self.fns](val)

    @always_inline("builtin")
    def __add__(
        self, other: Fn[i=Self.I, _]
    ) -> Parallel[*TypeList._concat[Self.fns.values, TypeList.of[Trait=FnTrait, type_of(other)].values]()]:
        """Add an async function to this parallel group.

        Args:
            other: Async function to add.

        Returns:
            New Parallel group.
        """
        return {}

    @always_inline("builtin")
    def __add__[*other_fns: FnTrait](
        self, other: Parallel[*other_fns]
    ) -> Parallel[*TypeList._concat[Self.fns.values, other_fns.values]()]:
        """Merge another parallel group into this one.

        Parameters:
            other_fns: Functions in the other group.

        Args:
            other: Other parallel group.

        Returns:
            Combined Parallel group.
        """
        return {}
