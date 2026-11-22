"""Zero-sized compile-time function composition, execution, and introspection.

All pipelines built with `F[fn]`, `Unit[fn]`, `Id[T]`, `Spread[fn]`, `group`,
`|`, and `&` carry their full DAG topology in the type system:

- Static metadata (`STAGE_COUNT`, `MAX_PARALLEL_WIDTH`, `CRITICAL_DEPTH`)
- Graph visualization (`to_mermaid()`, `to_dot()`)
- Pluggable executors (`run_with(exec, val)`)
- Compile-time evaluation (`comptime_run[value]`)
"""

from std.builtin.rebind import downcast
from std.reflection import get_function_name, reflect
from std.time import perf_counter_ns

from .._internal.runtime import TaskGroup, uninitialized_storage
from ..executors import Executor

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

comptime _SumStageCount[
    Prev: Int, Elem: FnTrait, Idx: Int
] = Prev + Elem.STAGE_COUNT

comptime _SumParallelWidth[
    Prev: Int, Elem: FnTrait, Idx: Int
] = Prev + Elem.MAX_PARALLEL_WIDTH

comptime _MaxParallelWidth[
    Prev: Int, Elem: FnTrait, Idx: Int
] = Elem.MAX_PARALLEL_WIDTH if Elem.MAX_PARALLEL_WIDTH > Prev else Prev

comptime _SumCriticalDepth[
    Prev: Int, Elem: FnTrait, Idx: Int
] = Prev + Elem.CRITICAL_DEPTH

comptime _MaxCriticalDepth[
    Prev: Int, Elem: FnTrait, Idx: Int
] = Elem.CRITICAL_DEPTH if Elem.CRITICAL_DEPTH > Prev else Prev


struct GraphBuilder(Movable):
    """Internal builder accumulating Mermaid or Graphviz DOT graph syntax."""

    var is_dot: Bool
    """If `True`, emits Graphviz DOT; otherwise emits Mermaid flowchart."""
    var next_id: Int
    """Next sequential node identifier."""
    var next_group: Int
    """Next sequential subgraph/cluster identifier."""
    var indent: Int
    """Current indentation depth."""
    var lines: List[String]
    """Accumulated output lines."""

    def __init__(out self, is_dot: Bool):
        """Initialize a new graph builder.

        Args:
            is_dot: `True` for Graphviz DOT format, `False` for Mermaid.
        """
        self.is_dot = is_dot
        self.next_id = 0
        self.next_group = 0
        self.indent = 1
        self.lines = List[String]()
        if is_dot:
            self.lines.append("digraph Strata {")
            self.lines.append("  rankdir=LR;")
        else:
            self.lines.append("flowchart LR")

    def _pad(self) -> String:
        var out = String("")
        for _ in range(self.indent):
            out += "  "
        return out^

    def add_node(mut self, label: String, entries: List[Int]) -> Int:
        """Emit a labeled graph node and edges from all `entries`.

        Args:
            label: Node display label.
            entries: Upstream node IDs to connect into this node.

        Returns:
            Newly allocated node ID.
        """
        var nid = self.next_id
        self.next_id += 1
        var safe_label: String
        if self.is_dot:
            safe_label = (
                label.replace("\\", "\\\\")
                .replace('"', "'")
                .replace("\r", "")
                .replace("\n", "\\n")
            )
            self.lines.append(
                String(self._pad(), "n", nid, ' [label="', safe_label, '"];')
            )
            for e in entries:
                self.lines.append(
                    String(self._pad(), "n", e, " -> n", nid, ";")
                )
        else:
            safe_label = (
                label.replace("\\", "\\\\")
                .replace('"', "'")
                .replace("\r", "")
                .replace("\n", " ")
                .replace("]", "&#93;")
            )
            self.lines.append(
                String(self._pad(), "n", nid, '["', safe_label, '"]')
            )
            for e in entries:
                self.lines.append(String(self._pad(), "n", e, " --> n", nid))
        return nid

    def begin_group(mut self):
        """Open a visual subgraph/cluster block for an explicit `Group`."""
        var gid = self.next_group
        self.next_group += 1
        if self.is_dot:
            self.lines.append(
                String(self._pad(), "subgraph cluster_", gid, " {")
            )
            self.indent += 1
            self.lines.append(String(self._pad(), 'label="group ', gid, '";'))
        else:
            self.lines.append(
                String(self._pad(), "subgraph g", gid, '["group ', gid, '"]')
            )
            self.indent += 1

    def end_group(mut self):
        """Close the innermost visual subgraph/cluster block."""
        self.indent -= 1
        if self.is_dot:
            self.lines.append(String(self._pad(), "}"))
        else:
            self.lines.append(String(self._pad(), "end"))

    def finish(mut self) -> String:
        """Finalize and return the rendered diagram text.

        Returns:
            Complete Mermaid or Graphviz DOT diagram string.
        """
        if self.is_dot:
            self.lines.append("}")
        return "\n".join(self.lines)


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
    comptime STAGE_COUNT: Int = 1
    """Total number of leaf stages in this graph."""
    comptime MAX_PARALLEL_WIDTH: Int = 1
    """Maximum simultaneous parallel branch width in this graph."""
    comptime CRITICAL_DEPTH: Int = 1
    """Longest sequential path length (in leaf stages) through this graph."""

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

    @staticmethod
    def run_with[E: Executor](mut exec: E, inp: Self.I) -> Self.O:
        """Execute this stage using a pluggable `Executor`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            inp: Input value.

        Returns:
            Computed stage result.
        """
        ...

    @staticmethod
    def _emit_graph(mut builder: GraphBuilder, entries: List[Int]) -> List[Int]:
        """Emit nodes and edges for this stage into `builder`.

        Args:
            builder: Target graph builder.
            entries: Upstream node IDs feeding into this stage.

        Returns:
            Exit node IDs produced by this stage.
        """
        ...

    @staticmethod
    def to_mermaid() -> String:
        """Render this compile-time pipeline topology as a Mermaid flowchart.

        Returns:
            Mermaid `flowchart LR` diagram string.
        """
        var b = GraphBuilder(is_dot=False)
        _ = Self._emit_graph(b, List[Int]())
        return b.finish()

    @staticmethod
    def to_dot() -> String:
        """Render this compile-time pipeline topology as Graphviz DOT.

        Returns:
            Graphviz `digraph Strata` string.
        """
        var b = GraphBuilder(is_dot=True)
        _ = Self._emit_graph(b, List[Int]())
        return b.finish()


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
    comptime to = downcast[Tuple[*fns.map[FnToOut]()].Ts[ci], Movable]
    ref inp = rebind[fns[ci].I](in_ptr[])
    out_ptr.unsafe_bitcast[to]().unsafe_write(rebind_var[to](fns[ci].run(inp)))


@always_inline
__async def _run_fn_task_traced[
    ci: Int,
    *fns: FnTrait,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
    t_orig: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_orig],
    out_ptr: Pointer[Tuple[*fns.map[FnToOut]()].Ts[ci], out_orig],
    start_ptr: Pointer[Int, t_orig],
    end_ptr: Pointer[Int, t_orig],
):
    comptime to = downcast[Tuple[*fns.map[FnToOut]()].Ts[ci], Movable]
    ref inp = rebind[fns[ci].I](in_ptr[])
    start_ptr[] = perf_counter_ns()
    out_ptr.unsafe_bitcast[to]().unsafe_write(rebind_var[to](fns[ci].run(inp)))
    end_ptr[] = perf_counter_ns()


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
        comptime to = downcast[Tuple[*fns.map[FnToOut]()].Ts[ci], Movable]
        ref inp = rebind[fns[ci].I](val)
        Pointer(to=o[ci]).unsafe_bitcast[to]().unsafe_write(
            rebind_var[to](fns[ci].run_sequential(inp))
        )
    return o^


def par_exec_with[
    E: Executor, *fns: FnTrait
](mut exec: E, val: fns[0].I) -> Tuple[*fns.map[FnToOut]()] where AllSameInput[
    fns
]:
    """Execute multiple compile-time stages using a pluggable `Executor`.

    Parameters:
        E: Executor strategy type.
        fns: Stages to execute.

    Args:
        exec: Executor controlling concurrency and observability.
        val: Input value passed to each stage.

    Returns:
        Flat tuple containing each stage's result in stage order.
    """
    var o = uninitialized_storage[Tuple[*fns.map[FnToOut]()]]()
    comptime if not E.IS_PARALLEL:
        comptime for ci in range(fns.length):
            comptime to = downcast[Tuple[*fns.map[FnToOut]()].Ts[ci], Movable]
            ref inp = rebind[fns[ci].I](val)
            Pointer(to=o[ci]).unsafe_bitcast[to]().unsafe_write(
                rebind_var[to](fns[ci].run_with(exec, inp))
            )
        return o^
    else:
        var limit = exec.concurrency_limit()
        if limit == 1:
            comptime for ci in range(fns.length):
                comptime to = downcast[
                    Tuple[*fns.map[FnToOut]()].Ts[ci], Movable
                ]
                ref inp = rebind[fns[ci].I](val)
                Pointer(to=o[ci]).unsafe_bitcast[to]().unsafe_write(
                    rebind_var[to](fns[ci].run_with(exec, inp))
                )
            return o^

        var in_ptr = Pointer(to=val)
        var tracing = exec.is_tracing()
        var starts = List[Int](length=fns.length, fill=0)
        var ends = List[Int](length=fns.length, fill=0)
        var wave_size = limit if limit > 0 else fns.length
        var wave_start = 0
        while wave_start < fns.length:
            var wave_end = min(wave_start + wave_size, fns.length)
            var tg = TaskGroup()
            comptime for ci in range(fns.length):
                if ci >= wave_start and ci < wave_end:
                    var out_ptr = Pointer(to=o[ci])
                    if tracing:
                        var s_ptr = Pointer(
                            to=starts[ci]
                        ).unsafe_origin_cast[MutUntrackedOrigin]()
                        var e_ptr = Pointer(
                            to=ends[ci]
                        ).unsafe_origin_cast[MutUntrackedOrigin]()
                        tg.create_task(
                            _run_fn_task_traced[ci, *fns](
                                in_ptr, out_ptr, s_ptr, e_ptr
                            )
                        )
                    else:
                        tg.create_task(
                            _run_fn_task[ci, *fns](in_ptr, out_ptr)
                        )
            tg.wait()
            wave_start = wave_end

        if tracing:
            comptime for ci in range(fns.length):
                exec.record_span(reflect[fns[ci]].name(), starts[ci], ends[ci])
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


def _seq_exec_with_tail[
    E: Executor,
    ci: Int,
    *fns: FnTrait,
](mut exec: E, var inp: fns[ci - 1].O) -> fns[
    fns.length - 1
].O where AllPipeable[fns]:
    var out = fns[ci].run_with(exec, rebind[fns[ci].I](inp))
    deinit(inp^)
    comptime if ci + 1 == fns.length:
        return rebind_var[fns[fns.length - 1].O](out^)
    else:
        return _seq_exec_with_tail[E, ci + 1, *fns](exec, out^)


def seq_exec_with[
    E: Executor, *fns: FnTrait
](mut exec: E, val: fns[0].I) -> fns[fns.length - 1].O where AllPipeable[fns]:
    """Execute multiple compile-time stages sequentially using `exec`.

    Parameters:
        E: Executor strategy type.
        fns: Stages to execute in order.

    Args:
        exec: Executor controlling concurrency and observability.
        val: Input value passed to the first stage.

    Returns:
        Result returned by the final stage.
    """
    var first = fns[0].run_with(exec, val)
    comptime if fns.length == 1:
        return rebind_var[fns[fns.length - 1].O](first^)
    else:
        return _seq_exec_with_tail[E, 1, *fns](exec, first^)


def _call_unit[Func: def() thin](val: NoneType) -> NoneType:
    Func()
    return None


def _identity_fn[T: Copyable & Deinitable](val: T) -> T:
    return val.copy()


def _spread2_fn[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B) thin -> Out,
](val: Tuple[A, B]) -> Out:
    return Func(val[0], val[1])


def _spread3_fn[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B, C) thin -> Out,
](val: Tuple[A, B, C]) -> Out:
    return Func(val[0], val[1], val[2])


def _spread4_fn[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    D: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B, C, D) thin -> Out,
](val: Tuple[A, B, C, D]) -> Out:
    return Func(val[0], val[1], val[2], val[3])


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

comptime Id[T: Copyable & Deinitable] = Function[_identity_fn[T]]()
"""Zero-sized compile-time identity stage (`T -> T`).

Parameters:
    T: Value type passed through unchanged.
"""

comptime Spread2[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B) thin -> Out,
] = Function[_spread2_fn[Func]]()
"""Zero-sized compile-time tuple-unpacking stage for a 2-argument function.

Parameters:
    A: First argument type.
    B: Second argument type.
    Out: Return type.
    Func: Two-argument function to unpack `Tuple[A, B]` into.
"""

comptime Spread3[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B, C) thin -> Out,
] = Function[_spread3_fn[Func]]()
"""Zero-sized compile-time tuple-unpacking stage for a 3-argument function.

Parameters:
    A: First argument type.
    B: Second argument type.
    C: Third argument type.
    Out: Return type.
    Func: Three-argument function to unpack `Tuple[A, B, C]` into.
"""

comptime Spread4[
    A: Movable & Deinitable,
    B: Movable & Deinitable,
    C: Movable & Deinitable,
    D: Movable & Deinitable,
    Out: Movable & Deinitable,
    //,
    Func: def(A, B, C, D) thin -> Out,
] = Function[_spread4_fn[Func]]()
"""Zero-sized compile-time tuple-unpacking stage for a 4-argument function.

Parameters:
    A: First argument type.
    B: Second argument type.
    C: Third argument type.
    D: Fourth argument type.
    Out: Return type.
    Func: Four-argument function to unpack `Tuple[A, B, C, D]` into.
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
    comptime STAGE_COUNT: Int = 1
    """Leaf function contributes 1 stage."""
    comptime MAX_PARALLEL_WIDTH: Int = 1
    """Leaf function has parallel width 1."""
    comptime CRITICAL_DEPTH: Int = 1
    """Leaf function has critical depth 1."""

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

    @staticmethod
    def run_with[E: Executor](mut exec: E, inp: Self.I) -> Self.O:
        """Run the wrapped function with executor hooks.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling observability.
            inp: Input value.

        Returns:
            Function output.
        """
        var token = exec.on_stage_start(get_function_name[Self.Func]())
        var res = Self.Func(inp)
        exec.on_stage_end(get_function_name[Self.Func](), token)
        return res^

    @staticmethod
    def _emit_graph(mut builder: GraphBuilder, entries: List[Int]) -> List[Int]:
        var label = String(
            get_function_name[Self.Func](),
            " (",
            reflect[Self.In].name(),
            " -> ",
            reflect[Self.Out].name(),
            ")",
        )
        var nid = builder.add_node(label, entries)
        return [nid]

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
    comptime STAGE_COUNT: Int = Self.Inner.STAGE_COUNT
    """Stage count inherited from `Inner`."""
    comptime MAX_PARALLEL_WIDTH: Int = Self.Inner.MAX_PARALLEL_WIDTH
    """Max parallel width inherited from `Inner`."""
    comptime CRITICAL_DEPTH: Int = Self.Inner.CRITICAL_DEPTH
    """Critical depth inherited from `Inner`."""

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

    @staticmethod
    def run_with[E: Executor](mut exec: E, inp: Self.I) -> Self.O:
        """Run the wrapped stage with executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            inp: Input value.

        Returns:
            Wrapped stage output.
        """
        return Self.Inner.run_with(exec, inp)

    @staticmethod
    def _emit_graph(mut builder: GraphBuilder, entries: List[Int]) -> List[Int]:
        builder.begin_group()
        var exits = Self.Inner._emit_graph(builder, entries)
        builder.end_group()
        return exits^

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
    comptime STAGE_COUNT: Int = Self.fns.reduce_idx[0, _SumStageCount]
    """Total leaf stages across all parallel branches."""
    comptime MAX_PARALLEL_WIDTH: Int = Self.fns.reduce_idx[0, _SumParallelWidth]
    """Sum of simultaneous parallel widths across branches."""
    comptime CRITICAL_DEPTH: Int = Self.fns.reduce_idx[0, _MaxCriticalDepth]
    """Longest branch critical depth."""

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

    @staticmethod
    def run_with[E: Executor](mut exec: E, val: Self.I) -> Self.O:
        """Run all branches using executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            val: Input value passed to every branch.

        Returns:
            Flat tuple containing each branch's result in order.
        """
        return par_exec_with[E, *Self.fns](exec, val)

    @staticmethod
    def _emit_graph(mut builder: GraphBuilder, entries: List[Int]) -> List[Int]:
        var exits = List[Int]()
        comptime for ci in range(Self.fns.length):
            var branch_exits = Self.fns[ci]._emit_graph(builder, entries)
            for ex in branch_exits:
                exits.append(ex)
        return exits^

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
    comptime STAGE_COUNT: Int = Self.fns.reduce_idx[0, _SumStageCount]
    """Total leaf stages in this sequence."""
    comptime MAX_PARALLEL_WIDTH: Int = Self.fns.reduce_idx[0, _MaxParallelWidth]
    """Maximum parallel width across stages in this sequence."""
    comptime CRITICAL_DEPTH: Int = Self.fns.reduce_idx[0, _SumCriticalDepth]
    """Sum of critical depths along this sequence."""

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

    @staticmethod
    def run_with[E: Executor](mut exec: E, val: Self.I) -> Self.O:
        """Run the sequential pipeline using executor `exec`.

        Parameters:
            E: Executor strategy type.

        Args:
            exec: Executor controlling concurrency and observability.
            val: Input value passed to the first stage.

        Returns:
            Result returned by the final stage.
        """
        return seq_exec_with[E, *Self.fns](exec, val)

    @staticmethod
    def _emit_graph(mut builder: GraphBuilder, entries: List[Int]) -> List[Int]:
        var current = entries.copy()
        comptime for ci in range(Self.fns.length):
            current = Self.fns[ci]._emit_graph(builder, current)
        return current^

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
