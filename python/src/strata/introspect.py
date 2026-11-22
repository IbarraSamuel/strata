"""Graph introspection, Mermaid/DOT visualization, and tracing executors."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from time import perf_counter_ns
from typing import TYPE_CHECKING, Any, cast

from strata import mojo_strata
from strata.async_support import AsyncTask
from strata.combinators import (
    BranchTask,
    FallbackTask,
    IdTask,
    MapTask,
    RetryTask,
    SelectTask,
    SpreadTask,
    TimeoutTask,
    ZipTask,
    _run_with_retry,
    _run_with_timeout,
    _validate_zip_input,
)
from strata.graph import (
    FnTask,
    GroupedTask,
    GroupMode,
    _BaseTaskGroup,
    _invoke_stage,
    _resolve_native,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

_MERMAID_DIRECTIONS = frozenset({"LR", "RL", "TB", "TD", "BT"})
_DOT_DIRECTIONS = frozenset({"LR", "RL", "TB", "BT"})
_DOT_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(frozen=True)
class GraphStats:
    """Static topology summary of a Strata task graph."""

    stage_count: int
    max_parallel_width: int
    critical_depth: int


@dataclass(frozen=True)
class TraceSpan:
    """Timing span recorded for a single Python stage execution."""

    stage: str
    start_ns: int
    end_ns: int

    @property
    def duration_ns(self) -> int:
        """Elapsed execution time in nanoseconds."""
        return self.end_ns - self.start_ns


def _callable_name(fn: object, default: str | None = None) -> str:
    name = getattr(fn, "__name__", None)
    if isinstance(name, str):
        return name
    return default if default is not None else repr(fn)


def _combinator_label(obj: object) -> str | None:
    label: str | None = None
    if isinstance(obj, MapTask):
        label = f"map({_stage_label(obj.stage)})"
    elif isinstance(obj, BranchTask):
        label = f"branch({_callable_name(obj.predicate, 'predicate')})"
    elif isinstance(obj, RetryTask):
        label = f"retry({obj.max_attempts}x, {_stage_label(obj.stage)})"
    elif isinstance(obj, FallbackTask):
        label = f"fallback({_stage_label(obj.primary)}, {_stage_label(obj.secondary)})"
    elif isinstance(obj, TimeoutTask):
        label = f"timeout({obj.seconds}s, {_stage_label(obj.stage)})"
    elif isinstance(obj, GroupedTask):
        label = "group"
    elif isinstance(obj, ZipTask):
        label = "zip"
    return label


def _stage_label(obj: object) -> str:
    native = _resolve_native(obj)
    if native is not None:
        label = f"native({native.get_name()})"
    elif isinstance(obj, AsyncTask):
        label = f"async({_callable_name(obj.inner_fn)})"
    elif isinstance(obj, FnTask):
        label = _callable_name(obj.inner_fn)
    elif isinstance(obj, SpreadTask):
        label = f"spread({_callable_name(obj.inner_fn)})"
    elif isinstance(obj, IdTask):
        label = "identity"
    elif isinstance(obj, SelectTask):
        label = f"select[{obj.index}]"
    else:
        comb = _combinator_label(obj)
        if comb is not None:
            label = comb
        elif callable(obj) and isinstance(getattr(obj, "__name__", None), str):
            label = str(getattr(obj, "__name__", type(obj).__name__))
        else:
            label = type(obj).__name__
    return label


def _unwrap_group(obj: object) -> mojo_strata.TaskGroup[Any, Any] | None:
    if isinstance(obj, _BaseTaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj.inner)
    if isinstance(obj, mojo_strata.TaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj)
    return None


def _escape_dot_label(text: str) -> str:
    return (
        text
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
        .replace("\r", "\\n")
    )


def _escape_mermaid_label(text: str) -> str:
    return (
        text
        .replace("\\", "\\\\")
        .replace('"', "&quot;")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
        .replace("\r", "\\n")
        .replace("]", "&#93;")
    )


def _format_dot_name(name: str) -> str:
    if not name or not name.strip():
        msg = "DOT graph name must be non-empty"
        raise ValueError(msg)
    if _DOT_IDENT_RE.fullmatch(name):
        return name
    return f'"{_escape_dot_label(name)}"'


def _combinator_stats(stage: object) -> GraphStats | None:
    if isinstance(stage, GroupedTask):
        return graph_stats(stage.inner_stage)
    if isinstance(stage, ZipTask):
        child_stats = [graph_stats(c) for c in stage.stages]
        return GraphStats(
            stage_count=sum(s.stage_count for s in child_stats),
            max_parallel_width=sum(s.max_parallel_width for s in child_stats),
            critical_depth=max(s.critical_depth for s in child_stats),
        )
    if isinstance(stage, (MapTask, RetryTask, TimeoutTask)):
        return graph_stats(stage.stage)
    if isinstance(stage, BranchTask):
        t_stats = graph_stats(stage.on_true)
        f_stats = graph_stats(stage.on_false)
        return GraphStats(
            stage_count=t_stats.stage_count + f_stats.stage_count,
            max_parallel_width=max(
                t_stats.max_parallel_width, f_stats.max_parallel_width
            ),
            critical_depth=max(t_stats.critical_depth, f_stats.critical_depth),
        )
    if isinstance(stage, FallbackTask):
        p_stats = graph_stats(stage.primary)
        s_stats = graph_stats(stage.secondary)
        return GraphStats(
            stage_count=p_stats.stage_count + s_stats.stage_count,
            max_parallel_width=max(
                p_stats.max_parallel_width, s_stats.max_parallel_width
            ),
            critical_depth=p_stats.critical_depth + s_stats.critical_depth,
        )
    return None


def graph_stats(stage: object) -> GraphStats:
    """Compute topology statistics for any Strata stage or composed graph.

    Parameters
    ----------
    stage : object
        Task, combinator, or composed pipeline group.

    Returns
    -------
    GraphStats
        Stage count, maximum parallel width, and critical path depth.
    """
    tg = _unwrap_group(stage)
    if tg is not None:
        mode = tg.get_mode()
        children = tg.get_tasks()
        if not children:
            return GraphStats(stage_count=0, max_parallel_width=0, critical_depth=0)
        child_stats = [graph_stats(c) for c in children]
        if mode == GroupMode.PARALLEL.value:
            return GraphStats(
                stage_count=sum(s.stage_count for s in child_stats),
                max_parallel_width=sum(s.max_parallel_width for s in child_stats),
                critical_depth=max(s.critical_depth for s in child_stats),
            )
        return GraphStats(
            stage_count=sum(s.stage_count for s in child_stats),
            max_parallel_width=max(s.max_parallel_width for s in child_stats),
            critical_depth=sum(s.critical_depth for s in child_stats),
        )

    comb = _combinator_stats(stage)
    if comb is not None:
        return comb

    return GraphStats(stage_count=1, max_parallel_width=1, critical_depth=1)


class _DiagramBuilder:
    def __init__(self, *, is_dot: bool, direction: str, name: str) -> None:
        self.is_dot = is_dot
        self.next_id = 0
        self.next_group = 0
        self.indent = 1
        self.lines: list[str] = []
        allowed = _DOT_DIRECTIONS if is_dot else _MERMAID_DIRECTIONS
        if direction not in allowed:
            msg = f"Unsupported diagram direction: {direction!r}"
            raise ValueError(msg)
        if is_dot:
            self.lines.append(f"digraph {_format_dot_name(name)} {{")
            self.lines.append(f"  rankdir={direction};")
        else:
            self.lines.append(f"flowchart {direction}")

    def _pad(self) -> str:
        return "  " * self.indent

    def _escape(self, text: str) -> str:
        return _escape_dot_label(text) if self.is_dot else _escape_mermaid_label(text)

    def add_node(self, label: str, entries: list[int]) -> int:
        nid = self.next_id
        self.next_id += 1
        safe = self._escape(label)
        if self.is_dot:
            self.lines.append(f'{self._pad()}n{nid} [label="{safe}"];')
            for e in entries:
                self.lines.append(f"{self._pad()}n{e} -> n{nid};")
        else:
            self.lines.append(f'{self._pad()}n{nid}["{safe}"]')
            for e in entries:
                self.lines.append(f"{self._pad()}n{e} --> n{nid}")
        return nid

    def begin_group(self, title: str) -> None:
        gid = self.next_group
        self.next_group += 1
        safe = self._escape(title)
        if self.is_dot:
            self.lines.append(f"{self._pad()}subgraph cluster_{gid} {{")
            self.indent += 1
            self.lines.append(f'{self._pad()}label="{safe}";')
        else:
            self.lines.append(f'{self._pad()}subgraph g{gid}["{safe}"]')
            self.indent += 1

    def end_group(self) -> None:
        self.indent -= 1
        self.lines.append(f"{self._pad()}}}" if self.is_dot else f"{self._pad()}end")

    def _emit_group(
        self, title: str, children: Sequence[object], entries: list[int]
    ) -> list[int]:
        self.begin_group(title)
        exits: list[int] = []
        for child in children:
            exits.extend(self.emit(child, entries))
        self.end_group()
        return exits

    def _emit_combinator(self, obj: object, entries: list[int]) -> list[int] | None:
        exits: list[int] | None = None
        if isinstance(obj, GroupedTask):
            exits = self._emit_group(
                f"group {self.next_group}", [obj.inner_stage], entries
            )
        elif isinstance(obj, ZipTask):
            exits = self._emit_group("zip", obj.stages, entries)
        elif isinstance(obj, MapTask):
            title = (
                f"map (max={obj.max_concurrency})" if obj.max_concurrency > 0 else "map"
            )
            exits = self._emit_group(title, [obj.stage], entries)
        elif isinstance(obj, RetryTask):
            exits = self._emit_group(
                f"retry ({obj.max_attempts}x)", [obj.stage], entries
            )
        elif isinstance(obj, TimeoutTask):
            exits = self._emit_group(f"timeout ({obj.seconds}s)", [obj.stage], entries)
        elif isinstance(obj, BranchTask):
            pred = _callable_name(obj.predicate, "predicate")
            exits = self._emit_group(
                f"branch ({pred})", [obj.on_true, obj.on_false], entries
            )
        elif isinstance(obj, FallbackTask):
            exits = self._emit_group("fallback", [obj.primary, obj.secondary], entries)
        return exits

    def emit(self, obj: object, entries: list[int]) -> list[int]:
        tg = _unwrap_group(obj)
        if tg is not None:
            mode = tg.get_mode()
            children = tg.get_tasks()
            if mode == GroupMode.PARALLEL.value:
                exits: list[int] = []
                for child in children:
                    exits.extend(self.emit(child, entries))
                return exits
            current = list(entries)
            for child in children:
                current = self.emit(child, current)
            return current

        comb_exits = self._emit_combinator(obj, entries)
        if comb_exits is not None:
            return comb_exits

        return [self.add_node(_stage_label(obj), entries)]

    def finish(self) -> str:
        if self.is_dot:
            self.lines.append("}")
        return "\n".join(self.lines)


def to_mermaid(stage: object, *, direction: str = "LR") -> str:
    """Render a Strata pipeline topology as a Mermaid flowchart.

    Parameters
    ----------
    stage : object
        Task, combinator, or composed pipeline.
    direction : str, optional
        Mermaid flow direction (`"LR"`, `"RL"`, `"TB"`, `"TD"`, `"BT"`).

    Returns
    -------
    str
        Mermaid flowchart source.
    """
    builder = _DiagramBuilder(is_dot=False, direction=direction, name="Strata")
    builder.emit(stage, [])
    return builder.finish()


def to_dot(stage: object, *, name: str = "Strata", direction: str = "LR") -> str:
    """Render a Strata pipeline topology as a Graphviz DOT graph.

    Parameters
    ----------
    stage : object
        Task, combinator, or composed pipeline.
    name : str, optional
        DOT graph identifier.
    direction : str, optional
        Graphviz `rankdir` (`"LR"`, `"RL"`, `"TB"`, `"BT"`).

    Returns
    -------
    str
        Graphviz DOT source.
    """
    builder = _DiagramBuilder(is_dot=True, direction=direction, name=name)
    builder.emit(stage, [])
    return builder.finish()


def _exec_combinator_seq(
    exec_fn: Callable[[object, object], object],
    obj: object,
    msg: object,
) -> tuple[bool, object]:
    handled = True
    result: object = None
    if isinstance(obj, GroupedTask):
        result = exec_fn(obj.inner_stage, msg)
    elif isinstance(obj, ZipTask):
        seq = _validate_zip_input(len(obj.stages), msg)
        result = tuple(exec_fn(child, seq[idx]) for idx, child in enumerate(obj.stages))
    elif isinstance(obj, MapTask):
        items = cast("Sequence[object]", msg)
        result = [exec_fn(obj.stage, item) for item in items]
    elif isinstance(obj, BranchTask):
        target = obj.on_true if obj.predicate(msg) else obj.on_false
        result = exec_fn(target, msg)
    elif isinstance(obj, RetryTask):
        result = _run_with_retry(lambda m: exec_fn(obj.stage, m), msg, obj)
    elif isinstance(obj, FallbackTask):
        try:
            result = exec_fn(obj.primary, msg)
        except obj.catch:
            result = exec_fn(obj.secondary, msg)
    elif isinstance(obj, TimeoutTask):
        result = _run_with_timeout(lambda m: exec_fn(obj.stage, m), msg, obj.seconds)
    else:
        handled = False
    return (handled, result)


class SequentialExecutor:
    """Deterministic single-threaded executor running all branches sequentially."""

    def run[I, O](self, stage: Any, msg: I) -> O:  # ruff: ignore[any-type]
        """Execute `stage` on `msg` strictly sequentially without parallelism.

        Parameters
        ----------
        stage : Any
            Task, combinator, or composed pipeline.
        msg : I
            Input value.

        Returns
        -------
        O
            Pipeline output matching parallel execution semantics.
        """
        return cast("O", self._exec(stage, msg))

    def _exec(self, obj: object, msg: object) -> object:
        tg = _unwrap_group(obj)
        if tg is not None:
            mode = tg.get_mode()
            children = tg.get_tasks()
            if not children:
                return msg
            if mode == GroupMode.PARALLEL.value:
                return tuple(self._exec(child, msg) for child in children)
            val = msg
            for child in children:
                val = self._exec(child, val)
            return val

        handled, result = _exec_combinator_seq(self._exec, obj, msg)
        if handled:
            return result

        return _invoke_stage(obj, msg)


@dataclass
class TracingExecutor:
    """Executor recording per-stage monotonic nanosecond spans.

    When `sequential=True`, executes every branch sequentially in deterministic
    order. When `sequential=False` (default), instruments leaf stages and runs
    parallel branches concurrently via Mojo's `TaskGroup`.
    """

    sequential: bool = False
    spans: list[TraceSpan] = field(default_factory=list)

    def clear(self) -> None:
        """Clear all recorded spans."""
        self.spans.clear()

    def total_duration_ns(self) -> int:
        """Return the sum of durations across all recorded spans.

        Returns
        -------
        int
            Total elapsed duration across all recorded spans in nanoseconds.
        """
        return sum(span.duration_ns for span in self.spans)

    def format_report(self) -> str:
        """Return a multi-line human-readable report of recorded spans.

        Returns
        -------
        str
            Newline-separated list of stage names and durations.
        """
        return "\n".join(f"{span.stage}: {span.duration_ns}ns" for span in self.spans)

    def run[I, O](self, stage: Any, msg: I) -> O:  # ruff: ignore[any-type]
        """Execute `stage` on `msg` while capturing per-stage timing spans.

        Parameters
        ----------
        stage : Any
            Task, combinator, or composed pipeline.
        msg : I
            Input value.

        Returns
        -------
        O
            Pipeline output.
        """
        if self.sequential:
            return cast("O", self._exec_sequential(stage, msg))
        wrapped = self._instrument(stage)
        return _invoke_stage(wrapped, msg)

    def _exec_sequential(self, obj: object, msg: object) -> object:
        tg = _unwrap_group(obj)
        if tg is not None:
            mode = tg.get_mode()
            children = tg.get_tasks()
            if not children:
                return msg
            if mode == GroupMode.PARALLEL.value:
                return tuple(self._exec_sequential(child, msg) for child in children)
            val = msg
            for child in children:
                val = self._exec_sequential(child, val)
            return val

        handled, result = _exec_combinator_seq(self._exec_sequential, obj, msg)
        if handled:
            return result

        label = _stage_label(obj)
        start = perf_counter_ns()
        res = _invoke_stage(obj, msg)
        end = perf_counter_ns()
        self.spans.append(TraceSpan(stage=label, start_ns=start, end_ns=end))
        return res

    def _instrument_combinator(self, obj: object) -> Any:  # ruff: ignore[any-type]
        wrapped: Any = None
        if isinstance(obj, GroupedTask):
            wrapped = GroupedTask(self._instrument(obj.inner_stage))
        elif isinstance(obj, ZipTask):
            wrapped = ZipTask(*(self._instrument(c) for c in obj.stages))
        elif isinstance(obj, MapTask):
            wrapped = MapTask(
                self._instrument(obj.stage), max_concurrency=obj.max_concurrency
            )
        elif isinstance(obj, BranchTask):
            wrapped = BranchTask(
                obj.predicate,
                self._instrument(obj.on_true),
                self._instrument(obj.on_false),
            )
        elif isinstance(obj, RetryTask):
            wrapped = RetryTask(
                self._instrument(obj.stage),
                max_attempts=obj.max_attempts,
                backoff=obj.backoff,
                backoff_multiplier=obj.backoff_multiplier,
                retry_on=obj.retry_on,
            )
        elif isinstance(obj, FallbackTask):
            wrapped = FallbackTask(
                self._instrument(obj.primary),
                self._instrument(obj.secondary),
                catch=obj.catch,
            )
        elif isinstance(obj, TimeoutTask):
            wrapped = TimeoutTask(self._instrument(obj.stage), obj.seconds)
        return wrapped

    def _instrument(self, obj: object) -> Any:  # ruff: ignore[any-type]
        tg = _unwrap_group(obj)
        if tg is not None:
            mode = tg.get_mode()
            children = tg.get_tasks()
            if not children:
                return obj
            instrumented = [self._instrument(c) for c in children]
            if len(instrumented) == 1:
                return instrumented[0]
            group_tg: mojo_strata.TaskGroup[Any, Any] = mojo_strata.TaskGroup(
                task=instrumented[0]
            )
            for child in instrumented[1:]:
                if mode == GroupMode.PARALLEL.value:
                    group_tg = group_tg.with_task(child, GroupMode.PARALLEL.value)
                else:
                    group_tg = group_tg.with_task(child, GroupMode.SERIAL.value)
            return group_tg

        comb = self._instrument_combinator(obj)
        if comb is not None:
            return comb

        label = _stage_label(obj)
        spans = self.spans

        def _traced_call(val: object) -> object:
            start = perf_counter_ns()
            res = _invoke_stage(obj, val)
            end = perf_counter_ns()
            spans.append(TraceSpan(stage=label, start_ns=start, end_ns=end))
            return res

        return _traced_call
