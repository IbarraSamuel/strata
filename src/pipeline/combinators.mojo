"""Dataflow combinators for runtime Mojo pipelines.

Provides composable building blocks that plug directly into `|` and `&`:

- `Id` / `identity`: Pass-through identity stage (`T -> T`).
- `Select` / `select`: Extract element `Idx` from a `Tuple` (`Tuple[*Ts] -> Ts[Idx]`).
- `Spread2` / `Spread3` / `Spread4` / `spread`: Unpack a `Tuple` into multi-argument functions.
- `Zip2` / `Zip3` / `zip_stages`: Parallel product (`(I1, I2, ...) -> (O1, O2, ...)`).
- `Map` / `map_stage`: Dynamic parallel map over `List[I] -> List[O]`.
- `Branch` / `branch`: Predicate-driven conditional routing (`on_true` vs `on_false`).
"""

from std.atomic import Atomic
from std.benchmark import keep
from std.builtin.rebind import downcast
from std.reflection import reflect
from std.sys.info import num_logical_cores
from std.time import perf_counter_ns

from .._internal.runtime import TaskGroup, uninitialized_storage
from ..executors import Executor
from . import ComposableStage, Stage

comptime _CopyMovStageVal = Copyable & Deinitable


# ===----------------------------------------------------------------------=== #
# Id (Identity Stage)
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct Id[T: _CopyMovStageVal](ComposableStage, Copyable, Movable):
    """Identity stage returning a copy of its input unchanged.

    Parameters:
        T: Value type passed through unchanged.
    """

    comptime I = Self.T
    """Input type."""
    comptime O = Self.T
    """Output type."""

    @always_inline
    def __call__(self, arg: Self.I) -> Self.O:
        """Return a copy of `arg`.

        Args:
            arg: Input value.

        Returns:
            Copy of `arg`.
        """
        return arg.copy()


def identity[T: _CopyMovStageVal]() -> Id[T]:
    """Create an identity stage for type `T`.

    Parameters:
        T: Value type passed through unchanged.

    Returns:
        An `Id[T]` stage conforming to `ComposableStage`.
    """
    return Id[T]()


# ===----------------------------------------------------------------------=== #
# Select (Tuple Element Projection)
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct Select[Idx: Int, *Ts: _CopyMovStageVal](
    ComposableStage, Copyable, Movable
) where (Idx >= 0 and Idx < Ts.length):
    """Extract element `Idx` from a `Tuple[*Ts]`.

    Parameters:
        Idx: Zero-based tuple element index.
        Ts: Tuple element types.
    """

    comptime I = Tuple[*Self.Ts]
    """Tuple input type."""
    comptime O = Self.Ts[Self.Idx]
    """Projected element type."""

    @always_inline
    def __call__(self, arg: Self.I) -> Self.O:
        """Return a copy of `arg[Idx]`.

        Args:
            arg: Input tuple.

        Returns:
            Projected element `arg[Idx]`.
        """
        return arg[Self.Idx].copy()


def select[Idx: Int, *Ts: _CopyMovStageVal]() -> Select[
    Idx, *Ts
] where (Idx >= 0 and Idx < Ts.length):
    """Create a tuple projection stage extracting element `Idx`.

    Parameters:
        Idx: Zero-based tuple element index.
        Ts: Tuple element types.

    Returns:
        A `Select[Idx, *Ts]` stage conforming to `ComposableStage`.
    """
    return Select[Idx, *Ts]()


# ===----------------------------------------------------------------------=== #
# Spread (Tuple Unpacking Adapters)
# ===----------------------------------------------------------------------=== #


@fieldwise_init("implicit")
struct Spread2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    Out: Movable & Deinitable,
](ComposableStage, Copyable, Movable):
    """Unpack a 2-tuple into a two-argument function.

    Parameters:
        A: First tuple element type.
        B: Second tuple element type.
        Out: Output type.
    """

    comptime I = Tuple[Self.A, Self.B]
    """2-tuple input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.A, Self.B) thin -> Self.Out
    """Wrapped two-argument function."""

    @always_inline
    def __call__(self, arg: Self.I) -> Self.O:
        """Call `self.func(arg[0], arg[1])`.

        Args:
            arg: 2-tuple input.

        Returns:
            Result of `self.func`.
        """
        return self.func(arg[0], arg[1])


@fieldwise_init("implicit")
struct Spread3[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    Out: Movable & Deinitable,
](ComposableStage, Copyable, Movable):
    """Unpack a 3-tuple into a three-argument function.

    Parameters:
        A: First tuple element type.
        B: Second tuple element type.
        C: Third tuple element type.
        Out: Output type.
    """

    comptime I = Tuple[Self.A, Self.B, Self.C]
    """3-tuple input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.A, Self.B, Self.C) thin -> Self.Out
    """Wrapped three-argument function."""

    @always_inline
    def __call__(self, arg: Self.I) -> Self.O:
        """Call `self.func(arg[0], arg[1], arg[2])`.

        Args:
            arg: 3-tuple input.

        Returns:
            Result of `self.func`.
        """
        return self.func(arg[0], arg[1], arg[2])


@fieldwise_init("implicit")
struct Spread4[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    D: Movable & Deinitable,
    Out: Movable & Deinitable,
](ComposableStage, Copyable, Movable):
    """Unpack a 4-tuple into a four-argument function.

    Parameters:
        A: First tuple element type.
        B: Second tuple element type.
        C: Third tuple element type.
        D: Fourth tuple element type.
        Out: Output type.
    """

    comptime I = Tuple[Self.A, Self.B, Self.C, Self.D]
    """4-tuple input type."""
    comptime O = Self.Out
    """Output type."""

    var func: def(Self.A, Self.B, Self.C, Self.D) thin -> Self.Out
    """Wrapped four-argument function."""

    @always_inline
    def __call__(self, arg: Self.I) -> Self.O:
        """Call `self.func(arg[0], arg[1], arg[2], arg[3])`.

        Args:
            arg: 4-tuple input.

        Returns:
            Result of `self.func`.
        """
        return self.func(arg[0], arg[1], arg[2], arg[3])


def spread[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    Out: Movable & Deinitable,
](func: def(A, B) thin -> Out) -> Spread2[A, B, Out]:
    """Lift a 2-argument function into a `ComposableStage` taking `Tuple[A, B]`.

    Parameters:
        A: First argument type.
        B: Second argument type.
        Out: Return type.

    Args:
        func: Two-argument function pointer.

    Returns:
        A `Spread2` stage unpacking `Tuple[A, B]`.
    """
    return Spread2(func)


def spread[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    Out: Movable & Deinitable,
](func: def(A, B, C) thin -> Out) -> Spread3[A, B, C, Out]:
    """Lift a 3-argument function into a `ComposableStage` taking `Tuple[A, B, C]`.

    Parameters:
        A: First argument type.
        B: Second argument type.
        C: Third argument type.
        Out: Return type.

    Args:
        func: Three-argument function pointer.

    Returns:
        A `Spread3` stage unpacking `Tuple[A, B, C]`.
    """
    return Spread3(func)


def spread[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    D: Movable & Deinitable,
    Out: Movable & Deinitable,
](func: def(A, B, C, D) thin -> Out) -> Spread4[A, B, C, D, Out]:
    """Lift a 4-argument function into a `ComposableStage` taking `Tuple[A, B, C, D]`.

    Parameters:
        A: First argument type.
        B: Second argument type.
        C: Third argument type.
        D: Fourth argument type.
        Out: Return type.

    Args:
        func: Four-argument function pointer.

    Returns:
        A `Spread4` stage unpacking `Tuple[A, B, C, D]`.
    """
    return Spread4(func)


# ===----------------------------------------------------------------------=== #
# Zip (Parallel Product: (I1, I2, ...) -> (O1, O2, ...))
# ===----------------------------------------------------------------------=== #


@always_inline
__async def _run_zip_branch[
    S: Stage,
    InT: AnyType,
    s_orig: ImmOrigin,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
](
    stage_ptr: Pointer[S, s_orig],
    in_ptr: Pointer[InT, in_orig],
    out_ptr: Pointer[S.O, out_orig],
):
    out_ptr.unsafe_write(stage_ptr[](rebind[S.I](in_ptr[])))


@always_inline
__async def _run_zip_branch_traced[
    S: Stage,
    InT: AnyType,
    s_orig: ImmOrigin,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
    t_orig: MutOrigin,
](
    stage_ptr: Pointer[S, s_orig],
    in_ptr: Pointer[InT, in_orig],
    out_ptr: Pointer[S.O, out_orig],
    start_ptr: Pointer[Int, t_orig],
    end_ptr: Pointer[Int, t_orig],
):
    start_ptr[] = perf_counter_ns()
    out_ptr.unsafe_write(stage_ptr[](rebind[S.I](in_ptr[])))
    end_ptr[] = perf_counter_ns()


struct Zip2[
    O1: ImmOrigin,
    O2: ImmOrigin,
    //,
    S1: Stage,
    S2: Stage,
](ComposableStage) where (
    conforms_to(S1.I, Movable)
    and conforms_to(S1.I, Deinitable)
    and conforms_to(S2.I, Movable)
    and conforms_to(S2.I, Deinitable)
):
    """Parallel product executing `s1(inp[0])` and `s2(inp[1])` concurrently.

    Parameters:
        O1: Origin of `s1`.
        O2: Origin of `s2`.
        S1: First stage type.
        S2: Second stage type.
    """

    comptime _I1 = downcast[Self.S1.I, Movable & Deinitable]
    comptime _I2 = downcast[Self.S2.I, Movable & Deinitable]
    comptime I = Tuple[Self._I1, Self._I2]
    """2-tuple input `(S1.I, S2.I)`."""
    comptime O = Tuple[Self.S1.O, Self.S2.O]
    """2-tuple output `(S1.O, S2.O)`."""

    var s1: Pointer[Self.S1, Self.O1]
    """Pointer to the first stage."""
    var s2: Pointer[Self.S2, Self.O2]
    """Pointer to the second stage."""

    def __init__(
        out self, ref[Self.O1] s1: Self.S1, ref[Self.O2] s2: Self.S2
    ):
        """Initialize with references to two stages.

        Args:
            s1: First stage applied to `arg[0]`.
            s2: Second stage applied to `arg[1]`.
        """
        self.s1 = Pointer(to=s1)
        self.s2 = Pointer(to=s2)

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute both stages concurrently on their respective tuple elements.

        Args:
            arg: 2-tuple `(in1, in2)`.

        Returns:
            2-tuple `(s1(in1), s2(in2))`.
        """
        var out = uninitialized_storage[Self.O]()
        var tg = TaskGroup()
        var p0 = Pointer(to=rebind[Self.S1.I](arg[0]))
        tg.create_task(_run_zip_branch(self.s1, p0, Pointer(to=out[0])))
        Pointer(to=out[1]).unsafe_write(
            self.s2[](rebind[Self.S2.I](arg[1]))
        )
        tg.wait()
        return out^

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute this parallel product using executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: 2-tuple `(in1, in2)`.

        Returns:
            2-tuple `(s1(in1), s2(in2))`.
        """
        comptime if not E.IS_PARALLEL:
            var r0 = self.s1[].run_with(exec, rebind[Self.S1.I](arg[0]))
            var r1 = self.s2[].run_with(exec, rebind[Self.S2.I](arg[1]))
            return (r0^, r1^)
        else:
            comptime if E.IS_BOUNDED:
                if exec.concurrency_limit() == 1:
                    var r0 = self.s1[].run_with(
                        exec, rebind[Self.S1.I](arg[0])
                    )
                    var r1 = self.s2[].run_with(
                        exec, rebind[Self.S2.I](arg[1])
                    )
                    return (r0^, r1^)

            comptime if E.IS_TRACING:
                var out = uninitialized_storage[Self.O]()
                var p0 = Pointer(to=rebind[Self.S1.I](arg[0]))
                var starts = Array[Int, 2](fill=0)
                var ends = Array[Int, 2](fill=0)
                var tg = TaskGroup()
                tg.create_task(
                    _run_zip_branch_traced(
                        self.s1,
                        p0,
                        Pointer(to=out[0]),
                        Pointer(to=starts[0]).unsafe_origin_cast[
                            MutUntrackedOrigin
                        ](),
                        Pointer(to=ends[0]).unsafe_origin_cast[
                            MutUntrackedOrigin
                        ](),
                    )
                )
                starts[1] = perf_counter_ns()
                Pointer(to=out[1]).unsafe_write(
                    self.s2[](rebind[Self.S2.I](arg[1]))
                )
                ends[1] = perf_counter_ns()
                tg.wait()
                exec.record_span(reflect[Self.S1].name(), starts[0], ends[0])
                exec.record_span(reflect[Self.S2].name(), starts[1], ends[1])
                return out^
            else:
                return self(arg)


struct Zip3[
    O1: ImmOrigin,
    O2: ImmOrigin,
    O3: ImmOrigin,
    //,
    S1: Stage,
    S2: Stage,
    S3: Stage,
](ComposableStage) where (
    conforms_to(S1.I, Movable)
    and conforms_to(S1.I, Deinitable)
    and conforms_to(S2.I, Movable)
    and conforms_to(S2.I, Deinitable)
    and conforms_to(S3.I, Movable)
    and conforms_to(S3.I, Deinitable)
):
    """Parallel product executing `s1(inp[0])`, `s2(inp[1])`, `s3(inp[2])` concurrently.

    Parameters:
        O1: Origin of `s1`.
        O2: Origin of `s2`.
        O3: Origin of `s3`.
        S1: First stage type.
        S2: Second stage type.
        S3: Third stage type.
    """

    comptime _I1 = downcast[Self.S1.I, Movable & Deinitable]
    comptime _I2 = downcast[Self.S2.I, Movable & Deinitable]
    comptime _I3 = downcast[Self.S3.I, Movable & Deinitable]
    comptime I = Tuple[Self._I1, Self._I2, Self._I3]
    """3-tuple input `(S1.I, S2.I, S3.I)`."""
    comptime O = Tuple[Self.S1.O, Self.S2.O, Self.S3.O]
    """3-tuple output `(S1.O, S2.O, S3.O)`."""

    var s1: Pointer[Self.S1, Self.O1]
    """Pointer to the first stage."""
    var s2: Pointer[Self.S2, Self.O2]
    """Pointer to the second stage."""
    var s3: Pointer[Self.S3, Self.O3]
    """Pointer to the third stage."""

    def __init__(
        out self,
        ref[Self.O1] s1: Self.S1,
        ref[Self.O2] s2: Self.S2,
        ref[Self.O3] s3: Self.S3,
    ):
        """Initialize with references to three stages.

        Args:
            s1: First stage applied to `arg[0]`.
            s2: Second stage applied to `arg[1]`.
            s3: Third stage applied to `arg[2]`.
        """
        self.s1 = Pointer(to=s1)
        self.s2 = Pointer(to=s2)
        self.s3 = Pointer(to=s3)

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute all three stages concurrently on their tuple elements.

        Args:
            arg: 3-tuple `(in1, in2, in3)`.

        Returns:
            3-tuple `(s1(in1), s2(in2), s3(in3))`.
        """
        var out = uninitialized_storage[Self.O]()
        var tg = TaskGroup()
        var p0 = Pointer(to=rebind[Self.S1.I](arg[0]))
        var p1 = Pointer(to=rebind[Self.S2.I](arg[1]))
        tg.create_task(_run_zip_branch(self.s1, p0, Pointer(to=out[0])))
        tg.create_task(_run_zip_branch(self.s2, p1, Pointer(to=out[1])))
        Pointer(to=out[2]).unsafe_write(
            self.s3[](rebind[Self.S3.I](arg[2]))
        )
        tg.wait()
        return out^

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute this 3-way parallel product using executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: 3-tuple `(in1, in2, in3)`.

        Returns:
            3-tuple `(s1(in1), s2(in2), s3(in3))`.
        """
        comptime if not E.IS_PARALLEL:
            var r0 = self.s1[].run_with(exec, rebind[Self.S1.I](arg[0]))
            var r1 = self.s2[].run_with(exec, rebind[Self.S2.I](arg[1]))
            var r2 = self.s3[].run_with(exec, rebind[Self.S3.I](arg[2]))
            return (r0^, r1^, r2^)
        else:
            comptime if not E.IS_BOUNDED:
                comptime if E.IS_TRACING:
                    var out = uninitialized_storage[Self.O]()
                    var p0 = Pointer(to=rebind[Self.S1.I](arg[0]))
                    var p1 = Pointer(to=rebind[Self.S2.I](arg[1]))
                    var starts = Array[Int, 3](fill=0)
                    var ends = Array[Int, 3](fill=0)
                    var tg = TaskGroup()
                    tg.create_task(
                        _run_zip_branch_traced(
                            self.s1,
                            p0,
                            Pointer(to=out[0]),
                            Pointer(to=starts[0]).unsafe_origin_cast[
                                MutUntrackedOrigin
                            ](),
                            Pointer(to=ends[0]).unsafe_origin_cast[
                                MutUntrackedOrigin
                            ](),
                        )
                    )
                    tg.create_task(
                        _run_zip_branch_traced(
                            self.s2,
                            p1,
                            Pointer(to=out[1]),
                            Pointer(to=starts[1]).unsafe_origin_cast[
                                MutUntrackedOrigin
                            ](),
                            Pointer(to=ends[1]).unsafe_origin_cast[
                                MutUntrackedOrigin
                            ](),
                        )
                    )
                    starts[2] = perf_counter_ns()
                    Pointer(to=out[2]).unsafe_write(
                        self.s3[](rebind[Self.S3.I](arg[2]))
                    )
                    ends[2] = perf_counter_ns()
                    tg.wait()
                    exec.record_span(
                        reflect[Self.S1].name(), starts[0], ends[0]
                    )
                    exec.record_span(
                        reflect[Self.S2].name(), starts[1], ends[1]
                    )
                    exec.record_span(
                        reflect[Self.S3].name(), starts[2], ends[2]
                    )
                    return out^
                else:
                    return self(arg)
            else:
                var limit = exec.concurrency_limit()
                if limit == 1:
                    var r0 = self.s1[].run_with(
                        exec, rebind[Self.S1.I](arg[0])
                    )
                    var r1 = self.s2[].run_with(
                        exec, rebind[Self.S2.I](arg[1])
                    )
                    var r2 = self.s3[].run_with(
                        exec, rebind[Self.S3.I](arg[2])
                    )
                    return (r0^, r1^, r2^)

                var out = uninitialized_storage[Self.O]()
                var p0 = Pointer(to=rebind[Self.S1.I](arg[0]))
                var p1 = Pointer(to=rebind[Self.S2.I](arg[1]))
                comptime if E.IS_TRACING:
                    var starts = Array[Int, 3](fill=0)
                    var ends = Array[Int, 3](fill=0)
                    if limit == 2:
                        # Wave 1: branch 0 on worker + branch 1 inline
                        var tg = TaskGroup()
                        tg.create_task(
                            _run_zip_branch_traced(
                                self.s1,
                                p0,
                                Pointer(to=out[0]),
                                Pointer(to=starts[0]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                                Pointer(to=ends[0]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                            )
                        )
                        starts[1] = perf_counter_ns()
                        Pointer(to=out[1]).unsafe_write(
                            self.s2[](rebind[Self.S2.I](arg[1]))
                        )
                        ends[1] = perf_counter_ns()
                        tg.wait()
                        # Wave 2: branch 2 inline (no TaskGroup needed)
                        starts[2] = perf_counter_ns()
                        Pointer(to=out[2]).unsafe_write(
                            self.s3[](rebind[Self.S3.I](arg[2]))
                        )
                        ends[2] = perf_counter_ns()
                    else:
                        var tg = TaskGroup()
                        tg.create_task(
                            _run_zip_branch_traced(
                                self.s1,
                                p0,
                                Pointer(to=out[0]),
                                Pointer(to=starts[0]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                                Pointer(to=ends[0]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                            )
                        )
                        tg.create_task(
                            _run_zip_branch_traced(
                                self.s2,
                                p1,
                                Pointer(to=out[1]),
                                Pointer(to=starts[1]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                                Pointer(to=ends[1]).unsafe_origin_cast[
                                    MutUntrackedOrigin
                                ](),
                            )
                        )
                        starts[2] = perf_counter_ns()
                        Pointer(to=out[2]).unsafe_write(
                            self.s3[](rebind[Self.S3.I](arg[2]))
                        )
                        ends[2] = perf_counter_ns()
                        tg.wait()
                    exec.record_span(
                        reflect[Self.S1].name(), starts[0], ends[0]
                    )
                    exec.record_span(
                        reflect[Self.S2].name(), starts[1], ends[1]
                    )
                    exec.record_span(
                        reflect[Self.S3].name(), starts[2], ends[2]
                    )
                    return out^
                else:
                    if limit == 2:
                        var tg = TaskGroup()
                        tg.create_task(
                            _run_zip_branch(self.s1, p0, Pointer(to=out[0]))
                        )
                        Pointer(to=out[1]).unsafe_write(
                            self.s2[](rebind[Self.S2.I](arg[1]))
                        )
                        tg.wait()
                        Pointer(to=out[2]).unsafe_write(
                            self.s3[](rebind[Self.S3.I](arg[2]))
                        )
                        return out^
                    return self(arg)


def zip_stages[
    O1: ImmOrigin, O2: ImmOrigin, //, S1: Stage, S2: Stage
](ref[O1] s1: S1, ref[O2] s2: S2) -> Zip2[
    O1=O1, O2=O2, S1, S2
] where (
    conforms_to(S1.I, Movable)
    and conforms_to(S1.I, Deinitable)
    and conforms_to(S2.I, Movable)
    and conforms_to(S2.I, Deinitable)
):
    """Create a 2-way parallel product stage `(I1, I2) -> (O1, O2)`.

    Parameters:
        O1: Origin of `s1`.
        O2: Origin of `s2`.
        S1: First stage type.
        S2: Second stage type.

    Args:
        s1: Stage applied to element 0.
        s2: Stage applied to element 1.

    Returns:
        A `Zip2` stage conforming to `ComposableStage`.
    """
    return Zip2(s1, s2)


def zip_stages[
    O1: ImmOrigin,
    O2: ImmOrigin,
    O3: ImmOrigin,
    //,
    S1: Stage,
    S2: Stage,
    S3: Stage,
](ref[O1] s1: S1, ref[O2] s2: S2, ref[O3] s3: S3) -> Zip3[
    O1=O1, O2=O2, O3=O3, S1, S2, S3
] where (
    conforms_to(S1.I, Movable)
    and conforms_to(S1.I, Deinitable)
    and conforms_to(S2.I, Movable)
    and conforms_to(S2.I, Deinitable)
    and conforms_to(S3.I, Movable)
    and conforms_to(S3.I, Deinitable)
):
    """Create a 3-way parallel product stage `(I1, I2, I3) -> (O1, O2, O3)`.

    Parameters:
        O1: Origin of `s1`.
        O2: Origin of `s2`.
        O3: Origin of `s3`.
        S1: First stage type.
        S2: Second stage type.
        S3: Third stage type.

    Args:
        s1: Stage applied to element 0.
        s2: Stage applied to element 1.
        s3: Stage applied to element 2.

    Returns:
        A `Zip3` stage conforming to `ComposableStage`.
    """
    return Zip3(s1, s2, s3)


# ===----------------------------------------------------------------------=== #
# Map (Dynamic Parallel Map over List[I] -> List[O])
# ===----------------------------------------------------------------------=== #


__async def _run_map_worker[
    S: Stage,
    InT: _CopyMovStageVal,
    OutT: _CopyMovStageVal,
    s_orig: ImmOrigin,
](
    stage_ptr: Pointer[S, s_orig],
    in_base: Pointer[InT, ImmUntrackedOrigin],
    out_base: Pointer[OutT, MutUntrackedOrigin],
    next_ptr: Pointer[Atomic[Int64], MutUntrackedOrigin],
    n: Int,
):
    while True:
        var idx = Int(next_ptr[].fetch_add(1))
        if idx >= n:
            break
        var res = stage_ptr[](rebind[S.I](in_base[unsafe_offset=idx]))
        out_base.unsafe_offset(idx).unsafe_write(rebind_var[OutT](res^))


struct Map[origin: ImmOrigin, //, Inner: Stage](ComposableStage) where (
    conforms_to(Inner.I, Copyable)
    and conforms_to(Inner.I, Movable)
    and conforms_to(Inner.I, Deinitable)
    and conforms_to(Inner.O, Copyable)
    and conforms_to(Inner.O, Movable)
    and conforms_to(Inner.O, Deinitable)
):
    """Dynamic parallel map applying `Inner` to each element of `List[Inner.I]`.

    Preserves input element order in the returned `List[Inner.O]`. Optional
    `max_concurrency` caps concurrent tasks in flight per wave (`0` = unbounded).

    Parameters:
        origin: Origin of the wrapped stage reference.
        Inner: Element-wise stage type.
    """

    comptime _ElemIn = downcast[Self.Inner.I, _CopyMovStageVal]
    comptime _ElemOut = downcast[Self.Inner.O, _CopyMovStageVal]
    comptime I = List[Self._ElemIn]
    """Input list type."""
    comptime O = List[Self._ElemOut]
    """Output list type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the per-element stage."""
    var max_concurrency: Int
    """Maximum concurrent tasks per wave (`0` = unbounded)."""

    def __init__(
        out self,
        ref[Self.origin] inner: Self.Inner,
        max_concurrency: Int = 0,
    ):
        """Initialize a dynamic parallel map stage.

        Args:
            inner: Stage to execute on every input element.
            max_concurrency: Optional concurrency cap (`0` for unbounded).
        """
        self.inner = Pointer(to=inner)
        self.max_concurrency = max_concurrency if max_concurrency > 0 else 0

    def _run_waves(self, arg: Self.I, limit: Int) -> Self.O:
        var n = len(arg)
        if n == 0:
            return Self.O()

        var workers = min(limit, n) if limit > 0 else min(
            max(num_logical_cores(), 1), n
        )
        if workers <= 1 or n == 1:
            var out = Self.O(capacity=n)
            for i in range(n):
                var r = self.inner[](rebind[Self.Inner.I](arg[i]))
                out.append(rebind_var[Self._ElemOut](r^))
            return out^

        # Zero-copy uninitialized output buffer with single-TaskGroup atomic work-stealing.
        var results = Self.O(unsafe_uninit_length=n)
        var in_base = arg.unsafe_ptr().as_imm().unsafe_origin_cast[
            ImmUntrackedOrigin
        ]()
        var out_base = results.unsafe_ptr().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var next_idx = Atomic[Int64](0)
        var next_ptr = Pointer(to=next_idx).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()

        var tg = TaskGroup()
        for _ in range(workers - 1):
            tg.create_task(
                _run_map_worker[Self.Inner, Self._ElemIn, Self._ElemOut](
                    self.inner, in_base, out_base, next_ptr, n
                )
            )

        # Caller thread participates in work-stealing directly until all items are claimed.
        while True:
            var idx = Int(next_idx.fetch_add(1))
            if idx >= n:
                break
            var r = self.inner[](rebind[Self.Inner.I](arg[idx]))
            out_base.unsafe_offset(idx).unsafe_write(
                rebind_var[Self._ElemOut](r^)
            )

        tg.wait()
        keep(results)
        keep(arg)
        keep(self)
        keep(next_idx)
        return results^

    def __call__(self, arg: Self.I) -> Self.O:
        """Apply `inner` to every element of `arg` concurrently.

        Args:
            arg: Input list of elements.

        Returns:
            Output list of transformed elements in original order.
        """
        return self._run_waves(arg, self.max_concurrency)

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Execute this dynamic map using executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: Input list of elements.

        Returns:
            Output list of transformed elements.
        """
        var token = exec.on_stage_start(reflect[Self].name())
        comptime if not E.IS_PARALLEL:
            var out = Self.O(capacity=len(arg))
            for i in range(len(arg)):
                var r = self.inner[].run_with(
                    exec, rebind[Self.Inner.I](arg[i])
                )
                out.append(rebind_var[Self._ElemOut](r^))
            exec.on_stage_end(reflect[Self].name(), token)
            return out^
        else:
            var exec_limit = exec.concurrency_limit()
            var effective_limit = self.max_concurrency
            if exec_limit > 0:
                if effective_limit <= 0 or exec_limit < effective_limit:
                    effective_limit = exec_limit
            var res = self._run_waves(arg, effective_limit)
            exec.on_stage_end(reflect[Self].name(), token)
            return res^


def map_stage[
    origin: ImmOrigin, //, Inner: Stage
](ref[origin] inner: Inner, max_concurrency: Int = 0) -> Map[
    origin=origin, Inner
] where (
    conforms_to(Inner.I, Copyable)
    and conforms_to(Inner.I, Movable)
    and conforms_to(Inner.I, Deinitable)
    and conforms_to(Inner.O, Copyable)
    and conforms_to(Inner.O, Movable)
    and conforms_to(Inner.O, Deinitable)
):
    """Lift a stage `I -> O` into a parallel `Map` stage `List[I] -> List[O]`.

    Parameters:
        origin: Origin of `inner`.
        Inner: Element-wise stage type.

    Args:
        inner: Stage applied to every item.
        max_concurrency: Maximum concurrent tasks per wave (`0` = unbounded).

    Returns:
        A `Map` stage conforming to `ComposableStage`.
    """
    return Map(inner, max_concurrency)


# ===----------------------------------------------------------------------=== #
# Branch (Conditional Routing)
# ===----------------------------------------------------------------------=== #


struct Branch[
    O1: ImmOrigin,
    O2: ImmOrigin,
    //,
    TrueStage: Stage,
    FalseStage: Stage,
](ComposableStage) where (
    TrueStage.I == FalseStage.I and TrueStage.O == FalseStage.O
):
    """Conditional router choosing between `on_true` and `on_false` via `predicate`.

    Parameters:
        O1: Origin of `on_true`.
        O2: Origin of `on_false`.
        TrueStage: Stage executed when `predicate(arg)` returns `True`.
        FalseStage: Stage executed when `predicate(arg)` returns `False`.
    """

    comptime I = Self.TrueStage.I
    """Input type."""
    comptime O = Self.TrueStage.O
    """Output type."""

    var predicate: def(Self.I) thin -> Bool
    """Routing predicate evaluated on the input."""
    var on_true: Pointer[Self.TrueStage, Self.O1]
    """Pointer to the true branch stage."""
    var on_false: Pointer[Self.FalseStage, Self.O2]
    """Pointer to the false branch stage."""

    def __init__(
        out self,
        predicate: def(Self.I) thin -> Bool,
        ref[Self.O1] on_true: Self.TrueStage,
        ref[Self.O2] on_false: Self.FalseStage,
    ):
        """Initialize a conditional branch stage.

        Args:
            predicate: Pure predicate choosing the branch.
            on_true: Stage invoked when `predicate(arg)` is `True`.
            on_false: Stage invoked when `predicate(arg)` is `False`.
        """
        self.predicate = predicate
        self.on_true = Pointer(to=on_true)
        self.on_false = Pointer(to=on_false)

    def __call__(self, arg: Self.I) -> Self.O:
        """Route `arg` to `on_true` or `on_false` based on `predicate(arg)`.

        Args:
            arg: Input argument.

        Returns:
            Output from the selected branch.
        """
        if self.predicate(arg):
            return self.on_true[](arg)
        return rebind_var[Self.O](
            self.on_false[](rebind[Self.FalseStage.I](arg))
        )

    def run_with[E: Executor](self, mut exec: E, arg: Self.I) -> Self.O:
        """Route `arg` to the selected branch and execute it with `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and tracing.
            arg: Input argument.

        Returns:
            Output from the selected branch.
        """
        if self.predicate(arg):
            return self.on_true[].run_with(exec, arg)
        return rebind_var[Self.O](
            self.on_false[].run_with(exec, rebind[Self.FalseStage.I](arg))
        )


def branch[
    In: AnyType,
    O1: ImmOrigin,
    O2: ImmOrigin,
    //,
    TrueStage: Stage,
    FalseStage: Stage,
](
    predicate: def(In) thin -> Bool,
    ref[O1] on_true: TrueStage,
    ref[O2] on_false: FalseStage,
) -> Branch[O1=O1, O2=O2, TrueStage, FalseStage] where (
    In == TrueStage.I
    and TrueStage.I == FalseStage.I
    and TrueStage.O == FalseStage.O
):
    """Create a conditional `Branch` routing stage.

    Parameters:
        In: Predicate input type (must match `TrueStage.I`).
        O1: Origin of `on_true`.
        O2: Origin of `on_false`.
        TrueStage: Stage executed when `predicate(arg)` is `True`.
        FalseStage: Stage executed when `predicate(arg)` is `False`.

    Args:
        predicate: Function returning `True` or `False` for the input.
        on_true: Stage executed on `True`.
        on_false: Stage executed on `False`.

    Returns:
        A `Branch` stage conforming to `ComposableStage`.
    """
    return Branch(
        rebind[def(TrueStage.I) thin -> Bool](predicate), on_true, on_false
    )


# ===----------------------------------------------------------------------=== #
# Bounded-Memory Streaming Batch Execution
# ===----------------------------------------------------------------------=== #


trait OutputSink:
    """Consumer receiving streamed outputs from `stream_map` in input order."""

    comptime Item: Movable
    """Item type delivered to `on_item`."""

    def on_item(mut self, var item: Self.Item):
        """Consume one produced output item.

        Args:
            item: Produced output item in original input order.
        """
        ...


__async def _run_stream_item[
    S: Stage,
    InT: AnyType,
    OutT: _CopyMovStageVal,
    stage_orig: ImmOrigin,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
](
    stage_ptr: Pointer[S, stage_orig],
    in_ptr: Pointer[InT, in_orig],
    out_ptr: Pointer[Optional[OutT], out_orig],
) where (S.I == InT and S.O == OutT):
    var res = stage_ptr[](rebind[S.I](in_ptr[]))
    out_ptr[] = rebind_var[OutT](res^)


def stream_map[
    S: Stage,
    InElem: _CopyMovStageVal,
    OutElem: _CopyMovStageVal,
    Sink: OutputSink,
](
    stage: S,
    items: List[InElem],
    max_in_flight: Int,
    mut sink: Sink,
) where (S.I == InElem and S.O == OutElem and Sink.Item == OutElem):
    """Execute `stage` across `items` in bounded parallel windows, streaming results to `sink`.

    Unlike `Map`, which buffers all `len(items)` outputs in a single `List`,
    `stream_map` bounds intermediate output memory to `O(max_in_flight)` by
    delivering each completed window to `sink.on_item(...)` in input order
    before starting the next window.

    Parameters:
        S: Element-wise stage type.
        InElem: Input item type (must match `S.I`).
        OutElem: Output item type (must match `S.O`).
        Sink: Consumer type implementing `OutputSink` for `OutElem`.

    Args:
        stage: Stage applied concurrently to each input item.
        items: Input items to process.
        max_in_flight: Maximum concurrent tasks per window (`<= 1` runs sequentially).
        sink: Output consumer receiving items in input order.
    """
    var n = len(items)
    if n == 0:
        return

    if max_in_flight <= 1 or n == 1:
        for i in range(n):
            var r = stage(rebind[S.I](items[i]))
            sink.on_item(rebind_var[Sink.Item](r^))
        return

    var window = min(max_in_flight, n)
    var stage_ptr = Pointer(to=stage)
    var slots = List[Optional[OutElem]](length=window, fill=None)
    var offset = 0
    while offset < n:
        var count = min(window, n - offset)
        if count == 1:
            var r = stage(rebind[S.I](items[offset]))
            sink.on_item(rebind_var[Sink.Item](r^))
            offset += 1
            continue
        var last = count - 1
        var tg = TaskGroup()
        for j in range(last):
            var in_ptr = Pointer(to=items[offset + j]).unsafe_origin_cast[
                ImmUntrackedOrigin
            ]()
            var out_ptr = Pointer(to=slots[j]).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            tg.create_task(_run_stream_item(stage_ptr, in_ptr, out_ptr))
        var r_last = stage(rebind[S.I](items[offset + last]))
        slots[last] = rebind_var[OutElem](r_last^)
        tg.wait()
        keep(items)
        keep(stage)
        keep(slots)
        for j in range(count):
            if slots[j]:
                var item = slots[j].unsafe_take()
                sink.on_item(rebind_var[Sink.Item](item^))
        offset += count

