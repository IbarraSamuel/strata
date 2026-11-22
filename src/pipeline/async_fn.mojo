"""Asynchronous compile-time function composition and parallel execution."""

from .._internal.runtime import TaskGroup, run_coro, uninitialized_storage

comptime AsyncFnToOut[f: AsyncFnTrait] = f.O
"""Extract the output type declared by an `AsyncFnTrait`.

Parameters:
    f: Async stage type.
"""

comptime AsyncFnInputMatch[In: AnyType, T: AsyncFnTrait] = In == T.I
"""Check whether a type matches an `AsyncFnTrait` input type.

Parameters:
    In: Input type to check against.
    T: Async stage type to inspect.
"""

comptime AllSameAsyncInput[fns: TypeList[Trait=AsyncFnTrait, _]] = fns.all[
    AsyncFnInputMatch[fns[0].I, _]
]()
"""Check whether every async stage in a list accepts the same input type.

Parameters:
    fns: Async stages whose input types are compared.
"""

comptime _concat_async_one[
    v1: TypeList[Trait=AsyncFnTrait, _], v2: AsyncFnTrait
] = TypeList._concat[v1.values, TypeList.of[Trait=AsyncFnTrait, v2].values]

comptime _concat_async_many[
    v1: TypeList[Trait=AsyncFnTrait, _], v2: TypeList[Trait=AsyncFnTrait, _]
] = TypeList._concat[v1.values, v2.values]


trait AsyncFnTrait(Movable, TrivialRegisterPassable):
    """Trait representing a stateless compile-time asynchronous pipeline stage."""

    comptime I: AnyType
    """Input type."""
    comptime O: Movable & Deinitable
    """Output type."""
    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `AsyncParallel` stages."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Asynchronously execute this stage on `in_ptr[]` and write output into `out_ptr`.

        Uses pointer arguments so non-trivial input/output types (`String`, `List`,
        `Tuple`) can compose cleanly across coroutine suspension points without
        blocking worker threads in nested `run_coro` calls.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value.
            out_ptr: Pointer to uninitialized output slot initialized via `unsafe_write`.
        """
        ...

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute this stage on `val` using the async runtime.

        Args:
            val: Input value.

        Returns:
            Computed stage output.
        """
        ...


__async def _run_async_fn_task[
    ci: Int,
    *fns: AsyncFnTrait,
    in_origin: ImmOrigin,
    out_origin: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_origin],
    out_ptr: Pointer[Tuple[*fns.map[AsyncFnToOut]()].Ts[ci], out_origin],
):
    var rebound_in = Pointer(to=rebind[fns[ci].I](in_ptr[]))
    var rebound_out = out_ptr.unsafe_bitcast[fns[ci].O]()
    __await fns[ci].exec_async(rebound_in, rebound_out)


__async def _par_fns_into[
    *fns: AsyncFnTrait,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_orig],
    out_ptr: Pointer[Tuple[*fns.map[AsyncFnToOut]()], out_orig],
) where AllSameAsyncInput[fns]:
    comptime N = fns.length
    comptime if N == 1:
        var rebound_in = Pointer(to=rebind[fns[0].I](in_ptr[]))
        var rebound_out = Pointer(to=out_ptr[][0]).unsafe_bitcast[fns[0].O]()
        __await fns[0].exec_async(rebound_in, rebound_out)
        return

    comptime last = N - 1
    var tg = TaskGroup()
    comptime for ci in range(last):
        var slot_ptr = Pointer(to=out_ptr[][ci])
        tg.create_task(_run_async_fn_task[ci, *fns](in_ptr, slot_ptr))

    var rebound_in_last = Pointer(to=rebind[fns[last].I](in_ptr[]))
    var rebound_out_last = Pointer(to=out_ptr[][last]).unsafe_bitcast[
        fns[last].O
    ]()
    __await fns[last].exec_async(rebound_in_last, rebound_out_last)
    __await tg


def par_fns[
    *fns: AsyncFnTrait
](val: fns[0].I) -> Tuple[*fns.map[AsyncFnToOut]()] where AllSameAsyncInput[
    fns
]:
    """Execute multiple async stages concurrently in a single `TaskGroup`.

    Parameters:
        fns: Async stage types to run concurrently.

    Args:
        val: Input value broadcast to all stages.

    Returns:
        Flat tuple containing each stage's result in stage order.
    """
    var o = uninitialized_storage[Tuple[*fns.map[AsyncFnToOut]()]]()
    run_coro(_par_fns_into[*fns](Pointer(to=val), Pointer(to=o)))
    return o^


@always_inline("nodebug")
def par_fn[
    In: TrivialRegisterPassable,
    O1: Movable & Deinitable,
    O2: Movable & Deinitable,
    //,
    f: __async def(In) thin -> O1,
    l: __async def(In) thin -> O2,
](val: In) -> Tuple[O1, O2]:
    """Execute two async functions concurrently.

    Parameters:
        In: Input type.
        O1: First function return type.
        O2: Second function return type.
        f: First async thin function.
        l: Second async thin function.

    Args:
        val: Input value.

    Returns:
        Tuple containing both function outputs.
    """
    return par_fns[AsyncFn[f], AsyncFn[l]](val)


comptime AF[
    In: TrivialRegisterPassable,
    Out: Movable & Deinitable,
    //,
    Func: __async def(In) thin -> Out,
] = AsyncFn[Func]()
"""Shorthand alias to instantiate a compile-time `AsyncFn` stage.

Parameters:
    In: Input type.
    Out: Output type.
    Func: Async thin function to wrap.
"""

comptime Sync[
    In: AnyType,
    Out: Movable & Deinitable,
    //,
    Func: def(In) thin -> Out,
] = SyncAdapter[Func]()
"""Lift a synchronous thin function (such as a tuple reducer) into an async pipeline.

Parameters:
    In: Input type.
    Out: Output type.
    Func: Synchronous thin function to wrap.
"""


def group[Inner: AsyncFnTrait](inner: Inner) -> AsyncGroup[Inner]:
    """Wrap an async stage as an opaque group so `&` preserves nested tuples.

    Parameters:
        Inner: Wrapped async stage type.

    Args:
        inner: Async stage to wrap.

    Returns:
        Opaque `AsyncGroup` stage.
    """
    return {}


@fieldwise_init
struct AsyncFn[
    i: TrivialRegisterPassable,
    o: Movable & Deinitable,
    //,
    F: __async def(i) thin -> o,
](AsyncFnTrait, TrivialRegisterPassable):
    """Zero-sized wrapper turning an `__async def` function into an `AsyncFnTrait`.

    Parameters:
        i: Input type.
        o: Output type.
        F: Async thin function to wrap.
    """

    comptime I = Self.i
    """Input type."""
    comptime O = Self.o
    """Output type."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Asynchronously execute the wrapped coroutine directly into `out_ptr`.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value.
            out_ptr: Pointer to uninitialized output slot.
        """
        comptime if conforms_to(Self.O, TrivialRegisterPassable):
            var r = __await Self.F(in_ptr[])
            out_ptr.unsafe_write(rebind_var[Self.O](r))
        else:
            out_ptr.unsafe_write(run_coro(Self.F(in_ptr[])))

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute the wrapped async function on the async runtime.

        Args:
            val: Input value.

        Returns:
            Result of the async function.
        """
        return run_coro(Self.F(val))

    def run(self, val: Self.I) -> Self.O:
        """Execute the wrapped async function synchronously on the event loop.

        Args:
            val: Input value.

        Returns:
            Result of the async function.
        """
        return Self.exec(val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke this async stage.

        Args:
            val: Input value.

        Returns:
            Result of the async function.
        """
        return Self.exec(val)

    @always_inline("nodebug")
    def __or__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncSequence[Self, Other] where Self.O == Other.I:
        """Pipe output of this async function into another async stage.

        Parameters:
            Other: Next async stage type.

        Args:
            other: Next async stage.

        Returns:
            An `AsyncSequence` executing `self` then `other`.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncParallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this async function with another async stage in parallel.

        Parameters:
            Other: Parallel async stage type.

        Args:
            other: Parallel async stage.

        Returns:
            An `AsyncParallel` stage executing both concurrently.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        *other_fns: AsyncFnTrait
    ](self, other: AsyncParallel[*other_fns]) -> AsyncParallel[
        *_concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ] where AllSameAsyncInput[other_fns] and AllSameAsyncInput[
        _concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ]:
        """Combine this function with a parallel group, flattening associatively.

        Parameters:
            other_fns: Stages inside the right-hand `AsyncParallel` group.

        Args:
            other: Parallel async stage.

        Returns:
            A flat `AsyncParallel` stage.
        """
        return {}


@fieldwise_init
struct SyncAdapter[
    i: AnyType,
    o: Movable & Deinitable,
    //,
    F: def(i) thin -> o,
](AsyncFnTrait, TrivialRegisterPassable):
    """Zero-sized adapter lifting a synchronous thin function into `AsyncFnTrait`.

    Ideal for pure reducers or transforms after `AsyncParallel` stages (e.g.,
    `(AF[fetch_a] & AF[fetch_b]) | Sync[merge_tuple]`).

    Parameters:
        i: Input type.
        o: Output type.
        F: Synchronous thin function to wrap.
    """

    comptime I = Self.i
    """Input type."""
    comptime O = Self.o
    """Output type."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Execute the synchronous function directly inside a coroutine into `out_ptr`.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value.
            out_ptr: Pointer to uninitialized output slot.
        """
        out_ptr.unsafe_write(Self.F(in_ptr[]))

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute the synchronous function.

        Args:
            val: Input value.

        Returns:
            Result of calling `Self.F`.
        """
        return Self.F(val)

    def run(self, val: Self.I) -> Self.O:
        """Execute the wrapped synchronous function directly.

        Args:
            val: Input value.

        Returns:
            Result of calling `Self.F`.
        """
        return Self.F(val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke the wrapped synchronous function directly.

        Args:
            val: Input value.

        Returns:
            Result of calling `Self.F`.
        """
        return Self.F(val)

    @always_inline("nodebug")
    def __or__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncSequence[Self, Other] where Self.O == Other.I:
        """Pipe this stage into another async stage.

        Parameters:
            Other: Next async stage type.

        Args:
            other: Next async stage.

        Returns:
            An `AsyncSequence` executing `self` then `other`.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncParallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this stage with another stage in parallel.

        Parameters:
            Other: Parallel async stage type.

        Args:
            other: Parallel async stage.

        Returns:
            An `AsyncParallel` stage executing both concurrently.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        *other_fns: AsyncFnTrait
    ](self, other: AsyncParallel[*other_fns]) -> AsyncParallel[
        *_concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ] where AllSameAsyncInput[other_fns] and AllSameAsyncInput[
        _concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ]:
        """Combine this stage with a parallel group, flattening associatively.

        Parameters:
            other_fns: Stages inside the right-hand `AsyncParallel` group.

        Args:
            other: Parallel async stage.

        Returns:
            A flat `AsyncParallel` stage.
        """
        return {}


@fieldwise_init
struct AsyncGroup[Inner: AsyncFnTrait](AsyncFnTrait, TrivialRegisterPassable):
    """Opaque async stage wrapper preventing `&` from flattening its inner stage.

    Parameters:
        Inner: Wrapped async stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Asynchronously execute the wrapped stage into `out_ptr`.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value.
            out_ptr: Pointer to uninitialized output slot.
        """
        __await Self.Inner.exec_async(in_ptr, out_ptr)

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute the wrapped stage.

        Args:
            val: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.Inner.exec(val)

    def run(self, val: Self.I) -> Self.O:
        """Execute the wrapped stage.

        Args:
            val: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.exec(val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke this grouped async stage.

        Args:
            val: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.exec(val)

    @always_inline("nodebug")
    def __or__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncSequence[Self, Other] where Self.O == Other.I:
        """Pipe this grouped async stage into another async stage.

        Parameters:
            Other: Next async stage type.

        Args:
            other: Next async stage.

        Returns:
            An `AsyncSequence` executing `self` then `other`.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncParallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this opaque group with another stage in parallel.

        Parameters:
            Other: Parallel async stage type.

        Args:
            other: Parallel async stage.

        Returns:
            An `AsyncParallel` stage keeping `self` grouped.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        *other_fns: AsyncFnTrait
    ](self, other: AsyncParallel[*other_fns]) -> AsyncParallel[
        *_concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ] where AllSameAsyncInput[other_fns] and AllSameAsyncInput[
        _concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ]:
        """Combine this opaque group with a right-hand `AsyncParallel` group.

        Parameters:
            other_fns: Stages inside the right-hand `AsyncParallel` group.

        Args:
            other: Parallel async stage.

        Returns:
            An `AsyncParallel` stage keeping `self` grouped.
        """
        return {}


@fieldwise_init
struct AsyncSequence[T1: AsyncFnTrait, T2: AsyncFnTrait](
    AsyncFnTrait, TrivialRegisterPassable
) where T1.O == T2.I:
    """Sequential composition of two async pipeline stages.

    Parameters:
        T1: First async stage type.
        T2: Second async stage type.
    """

    comptime I = Self.T1.I
    """Input type of the first stage."""
    comptime O = Self.T2.O
    """Output type of the second stage."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Asynchronously execute `T1` followed by `T2` into `out_ptr`.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value.
            out_ptr: Pointer to uninitialized output slot.
        """
        var mid = uninitialized_storage[Self.T1.O]()
        __await Self.T1.exec_async(in_ptr, Pointer(to=mid))
        var mid_in = Pointer(to=rebind[Self.T2.I](mid))
        __await Self.T2.exec_async(mid_in, out_ptr)

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute `T1` followed by `T2`.

        Args:
            val: Input value.

        Returns:
            Output of `T2`.
        """
        var mid = Self.T1.exec(val)
        return Self.T2.exec(rebind[Self.T2.I](mid))

    def run(self, val: Self.I) -> Self.O:
        """Execute this async sequence.

        Args:
            val: Input value.

        Returns:
            Output of `T2`.
        """
        return Self.exec(val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke this async sequence.

        Args:
            val: Input value.

        Returns:
            Output of `T2`.
        """
        return Self.exec(val)

    @always_inline("nodebug")
    def __or__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncSequence[Self, Other] where Self.O == Other.I:
        """Pipe this sequence into another async stage.

        Parameters:
            Other: Next async stage type.

        Args:
            other: Next async stage.

        Returns:
            Chained `AsyncSequence`.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncParallel[Self, Other] where (
        not Other._IS_PARALLEL
    ) and (Self.I == Other.I):
        """Combine this sequence with another stage in parallel.

        Parameters:
            Other: Parallel async stage type.

        Args:
            other: Parallel async stage.

        Returns:
            An `AsyncParallel` stage executing both concurrently.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        *other_fns: AsyncFnTrait
    ](self, other: AsyncParallel[*other_fns]) -> AsyncParallel[
        *_concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ] where AllSameAsyncInput[other_fns] and AllSameAsyncInput[
        _concat_async_many[
            TypeList.of[Trait=AsyncFnTrait, Self](), other_fns
        ]()
    ]:
        """Combine this sequence with a parallel group, flattening associatively.

        Parameters:
            other_fns: Stages inside the right-hand `AsyncParallel` group.

        Args:
            other: Parallel async stage.

        Returns:
            A flat `AsyncParallel` stage.
        """
        return {}


@fieldwise_init
struct AsyncParallel[*fns: AsyncFnTrait](
    AsyncFnTrait, TrivialRegisterPassable
) where AllSameAsyncInput[fns]:
    """Flat parallel group of async stages conforming to `AsyncFnTrait`.

    Can be piped directly into downstream stages via `|` (`(a & b) | merge`)
    and merged associatively with other stages or `AsyncParallel` groups via `&`.

    Parameters:
        fns: Variadic list of `AsyncFnTrait` stages to execute concurrently.
    """

    comptime I = Self.fns[0].I
    """Common input type."""
    comptime O = Tuple[*Self.fns.map[AsyncFnToOut]()]
    """Flat tuple output type."""
    comptime _IS_PARALLEL: Bool = True
    """Marks `AsyncParallel` for associative flattening."""

    @staticmethod
    __async def exec_async[
        in_orig: ImmOrigin, out_orig: MutOrigin
    ](
        in_ptr: Pointer[Self.I, in_orig],
        out_ptr: Pointer[Self.O, out_orig],
    ):
        """Asynchronously execute all parallel branches concurrently into `out_ptr`.

        Parameters:
            in_orig: Origin of the input pointer.
            out_orig: Origin of the output storage pointer.

        Args:
            in_ptr: Pointer to input value broadcast to every branch.
            out_ptr: Pointer to uninitialized output tuple slot.
        """
        __await _par_fns_into[*Self.fns](in_ptr, out_ptr)

    @staticmethod
    def exec(val: Self.I) -> Self.O:
        """Execute all parallel branches concurrently in one `TaskGroup`.

        Args:
            val: Input value broadcast to every branch.

        Returns:
            Flat tuple of branch outputs.
        """
        return par_fns[*Self.fns](val)

    def run(self, val: Self.I) -> Self.O:
        """Execute all parallel branches concurrently on the async runtime.

        Args:
            val: Input value broadcast to every branch.

        Returns:
            Flat tuple of branch outputs.
        """
        return Self.exec(val)

    def __call__(self, val: Self.I) -> Self.O:
        """Invoke all parallel branches concurrently.

        Args:
            val: Input value broadcast to every branch.

        Returns:
            Flat tuple of branch outputs.
        """
        return Self.exec(val)

    @always_inline("nodebug")
    def __or__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncSequence[Self, Other] where Self.O == Other.I:
        """Pipe this parallel group's tuple output into another async stage.

        Parameters:
            Other: Next async stage type.

        Args:
            other: Next async stage accepting `Self.O`.

        Returns:
            An `AsyncSequence` executing `self` then `other`.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        Other: AsyncFnTrait, //
    ](self, other: Other) -> AsyncParallel[
        *_concat_async_one[Self.fns, Other]()
    ] where (not Other._IS_PARALLEL) and AllSameAsyncInput[
        _concat_async_one[Self.fns, Other]()
    ]:
        """Append an async stage to this parallel group.

        Parameters:
            Other: Stage type to append.

        Args:
            other: Async stage to add.

        Returns:
            A flat `AsyncParallel` group with `other` appended.
        """
        return {}

    @always_inline("nodebug")
    def __and__[
        *other_fns: AsyncFnTrait
    ](self, other: AsyncParallel[*other_fns]) -> AsyncParallel[
        *_concat_async_many[Self.fns, other_fns]()
    ] where AllSameAsyncInput[other_fns] and AllSameAsyncInput[
        _concat_async_many[Self.fns, other_fns]()
    ]:
        """Merge another parallel group into this one associatively.

        Parameters:
            other_fns: Stages inside the right-hand `AsyncParallel` group.

        Args:
            other: Other parallel group.

        Returns:
            A single flat `AsyncParallel` group containing all branches.
        """
        return {}
