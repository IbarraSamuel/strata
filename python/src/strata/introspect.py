"""Graph introspection, Mermaid/DOT visualization, and tracing executors."""

from __future__ import annotations

from dataclasses import dataclass, field
from time import perf_counter_ns
from typing import Any, cast

from strata import mojo_strata
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
)
from strata.graph import (
    FnTask,
    GroupedTask,
    GroupMode,
    _BaseTaskGroup,
)


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


def _stage_label(obj: object) -> str:
    formatters: dict[type[object], Any] = {
        FnTask: lambda o: _callable_name(o.inner_fn),
        SpreadTask: lambda o: f"spread({_callable_name(o.inner_fn)})",
        IdTask: lambda _o: "identity",
        SelectTask: lambda o: f"select[{o.index}]",
        MapTask: lambda o: f"map({_stage_label(o.stage)})",
        BranchTask: lambda o: f"branch({_callable_name(o.predicate, 'predicate')})",
        RetryTask: lambda o: f"retry({o.max_attempts}x, {_stage_label(o.stage)})",
        FallbackTask: lambda o: (
            f"fallback({_stage_label(o.primary)}, {_stage_label(o.secondary)})"
        ),
        TimeoutTask: lambda o: f"timeout({o.seconds}s, {_stage_label(o.stage)})",
        GroupedTask: lambda _o: "group",
        ZipTask: lambda _o: "zip",
    }
    formatter = formatters.get(type(obj))
    if formatter is not None:
        return str(formatter(obj))
    if callable(obj) and isinstance(getattr(obj, "__name__", None), str):
        return str(getattr(obj, "__name__", type(obj).__name__))
    return type(obj).__name__


def _unwrap_group(obj: object) -> mojo_strata.TaskGroup[Any, Any] | None:
    if isinstance(obj, _BaseTaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj.inner)
    if isinstance(obj, mojo_strata.TaskGroup):
        return cast("mojo_strata.TaskGroup[Any, Any]", obj)
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

    if isinstance(stage, GroupedTask):
        return graph_stats(stage.inner_stage)

    if isinstance(stage, ZipTask):
        child_stats = [graph_stats(c) for c in stage.stages]
        return GraphStats(
            stage_count=sum(s.stage_count for s in child_stats),
            max_parallel_width=sum(s.max_parallel_width for s in child_stats),
            critical_depth=max(s.critical_depth for s in child_stats),
        )

    return GraphStats(stage_count=1, max_parallel_width=1, critical_depth=1)


class _DiagramBuilder:
    def __init__(self, *, is_dot: bool, direction: str, name: str) -> None:
        self.is_dot = is_dot
        self.next_id = 0
        self.next_group = 0
        self.indent = 1
        self.lines: list[str] = []
        if is_dot:
            self.lines.append(f"digraph {name} {{")
            self.lines.append(f"  rankdir={direction};")
        else:
            self.lines.append(f"flowchart {direction}")

    def _pad(self) -> str:
        return "  " * self.indent

    def add_node(self, label: str, entries: list[int]) -> int:
        nid = self.next_id
        self.next_id += 1
        safe = label.replace('"', "'")
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
        safe = title.replace('"', "'")
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

        if isinstance(obj, GroupedTask):
            self.begin_group(f"group {self.next_group}")
            exits = self.emit(obj.inner_stage, entries)
            self.end_group()
            return exits

        if isinstance(obj, ZipTask):
            self.begin_group("zip")
            exits = []
            for child in obj.stages:
                exits.extend(self.emit(child, entries))
            self.end_group()
            return exits

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
        Mermaid flow direction (`"LR"`, `"TD"`, etc.).

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
        Graphviz `rankdir` (`"LR"`, `"TB"`, etc.).

    Returns
    -------
    str
        Graphviz DOT source.
    """
    builder = _DiagramBuilder(is_dot=True, direction=direction, name=name)
    builder.emit(stage, [])
    return builder.finish()


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

        if isinstance(obj, GroupedTask):
            return self._exec(obj.inner_stage, msg)

        if isinstance(obj, ZipTask):
            seq = cast("tuple[object, ...]", msg)
            return tuple(
                self._exec(child, seq[idx]) for idx, child in enumerate(obj.stages)
            )

        return cast("Any", obj)(msg)


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
        if isinstance(wrapped, mojo_strata.TaskGroup):
            return cast("O", wrapped.call(msg))
        return cast("O", wrapped(msg))

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

        if isinstance(obj, GroupedTask):
            return self._exec_sequential(obj.inner_stage, msg)

        if isinstance(obj, ZipTask):
            seq = cast("tuple[object, ...]", msg)
            return tuple(
                self._exec_sequential(child, seq[idx])
                for idx, child in enumerate(obj.stages)
            )

        label = _stage_label(obj)
        start = perf_counter_ns()
        res = cast("Any", obj)(msg)
        end = perf_counter_ns()
        self.spans.append(TraceSpan(stage=label, start_ns=start, end_ns=end))
        return res

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

        if isinstance(obj, GroupedTask):
            inner_wrapped = self._instrument(obj.inner_stage)
            return GroupedTask(inner_wrapped)

        label = _stage_label(obj)
        spans = self.spans

        def _traced_call(val: object) -> object:
            start = perf_counter_ns()
            res = cast("Any", obj)(val)
            end = perf_counter_ns()
            spans.append(TraceSpan(stage=label, start_ns=start, end_ns=end))
            return res

        return _traced_call
