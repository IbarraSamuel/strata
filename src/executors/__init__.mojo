"""Pluggable execution strategies for Strata pipelines.

Provides the `Executor` trait and concrete execution policies that control
concurrency and observability without changing pipeline definitions:

- `AsyncRTExecutor`: Default unbounded parallel execution on `TaskGroup`.
- `SequentialExecutor`: Deterministic single-threaded execution (comptime-safe).
- `BoundedExecutor`: Parallel execution capped at `max_workers` concurrent tasks.
- `TracingExecutor`: Wraps any `Executor` to capture per-stage latency spans.
"""

from std.time import perf_counter_ns


@fieldwise_init
struct TraceSpan(Copyable, Movable, TrivialRegisterPassable, Writable):
    """Timing span recorded for a single stage execution."""

    var stage: StaticString
    """Human-readable name of the executed stage."""
    var start_ns: Int
    """Monotonic start timestamp in nanoseconds."""
    var end_ns: Int
    """Monotonic end timestamp in nanoseconds."""

    def duration_ns(self) -> Int:
        """Return elapsed duration in nanoseconds.

        Returns:
            Non-negative elapsed time in nanoseconds.
        """
        return self.end_ns - self.start_ns

    def write_to(self, mut writer: Some[Writer]):
        """Format this trace span for display.

        Args:
            writer: Destination writer.
        """
        writer.write(self.stage, ": ", self.duration_ns(), "ns")


trait Executor:
    """Execution strategy controlling parallelism and stage lifecycle hooks."""

    comptime IS_PARALLEL: Bool
    """Whether this executor may spawn concurrent `TaskGroup` tasks."""
    comptime IS_TRACING: Bool = False
    """Whether this executor collects per-stage timing spans (enables compile-time DCE)."""
    comptime IS_BOUNDED: Bool = False
    """Whether this executor enforces a finite per-wave concurrency bound."""

    def concurrency_limit(self) -> Int:
        """Return the maximum number of concurrent tasks (`0` means unbounded).

        Returns:
            `0` for unbounded concurrency, `1` for sequential, or `N > 1` for
            bounded parallel waves of size `N`.
        """
        ...

    def is_tracing(self) -> Bool:
        """Return whether this executor collects per-stage timing spans.

        Returns:
            `True` if timing spans should be measured and recorded.
        """
        ...

    def on_stage_start(mut self, name: StaticString) -> Int:
        """Hook invoked immediately before executing a stage.

        Args:
            name: Stage label.

        Returns:
            Opaque start token (e.g. start timestamp in nanoseconds).
        """
        ...

    def on_stage_end(mut self, name: StaticString, token: Int):
        """Hook invoked immediately after executing a stage.

        Args:
            name: Stage label.
            token: Token returned by `on_stage_start`.
        """
        ...

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        """Record a pre-measured span (used after parallel `TaskGroup.wait()`).

        Args:
            name: Stage label.
            start_ns: Monotonic start timestamp in nanoseconds.
            end_ns: Monotonic end timestamp in nanoseconds.
        """
        ...


@fieldwise_init
struct AsyncRTExecutor(Executor, Copyable, Movable, TrivialRegisterPassable):
    """Default executor running parallel branches concurrently via `TaskGroup`."""

    comptime IS_PARALLEL: Bool = True
    """Executes parallel branches concurrently."""
    comptime IS_TRACING: Bool = False
    """Disables tracing code paths at compile time."""
    comptime IS_BOUNDED: Bool = False
    """Unbounded concurrency (skips wave-splitting loops at compile time)."""

    def concurrency_limit(self) -> Int:
        """Return `0` (unbounded concurrency).

        Returns:
            `0`.
        """
        return 0

    def is_tracing(self) -> Bool:
        """Return `False` (no tracing overhead).

        Returns:
            `False`.
        """
        return Self.IS_TRACING

    def on_stage_start(mut self, name: StaticString) -> Int:
        """No-op start hook.

        Args:
            name: Stage label.

        Returns:
            `0`.
        """
        return 0

    def on_stage_end(mut self, name: StaticString, token: Int):
        """No-op end hook.

        Args:
            name: Stage label.
            token: Unused token.
        """
        pass

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        """No-op span recorder.

        Args:
            name: Stage label.
            start_ns: Start timestamp.
            end_ns: End timestamp.
        """
        pass


@fieldwise_init
struct SequentialExecutor(Executor, Copyable, Movable, TrivialRegisterPassable):
    """Deterministic single-threaded executor making no async runtime calls.

    Useful for deterministic debugging, benchmarking parallel speedup against a
    serial baseline, and compile-time evaluation.
    """

    comptime IS_PARALLEL: Bool = False
    """Forces all parallel stages to run sequentially."""
    comptime IS_TRACING: Bool = False
    """Disables tracing code paths at compile time."""
    comptime IS_BOUNDED: Bool = False
    """Sequential execution does not use bounded parallel waves."""

    def concurrency_limit(self) -> Int:
        """Return `1` (strictly sequential).

        Returns:
            `1`.
        """
        return 1

    def is_tracing(self) -> Bool:
        """Return `False`.

        Returns:
            `False`.
        """
        return Self.IS_TRACING

    def on_stage_start(mut self, name: StaticString) -> Int:
        """No-op start hook.

        Args:
            name: Stage label.

        Returns:
            `0`.
        """
        return 0

    def on_stage_end(mut self, name: StaticString, token: Int):
        """No-op end hook.

        Args:
            name: Stage label.
            token: Unused token.
        """
        pass

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        """No-op span recorder.

        Args:
            name: Stage label.
            start_ns: Start timestamp.
            end_ns: End timestamp.
        """
        pass


struct BoundedExecutor(Executor, Copyable, Movable, TrivialRegisterPassable):
    """Parallel executor bounding concurrent tasks per wave to `max_workers`."""

    comptime IS_PARALLEL: Bool = True
    """Executes waves concurrently via `TaskGroup`."""
    comptime IS_TRACING: Bool = False
    """Disables tracing code paths at compile time."""
    comptime IS_BOUNDED: Bool = True
    """Enforces wave-bounded concurrency limits."""

    var max_workers: Int
    """Maximum number of tasks allowed in flight per parallel wave."""

    def __init__(out self, max_workers: Int):
        """Initialize a bounded executor with at least 1 worker.

        Args:
            max_workers: Maximum concurrent tasks per wave (clamped to `>= 1`).
        """
        self.max_workers = max_workers if max_workers > 0 else 1

    def concurrency_limit(self) -> Int:
        """Return the configured maximum concurrent tasks per wave.

        Returns:
            Maximum concurrent workers (`>= 1`).
        """
        return self.max_workers

    def is_tracing(self) -> Bool:
        """Return `False`.

        Returns:
            `False`.
        """
        return Self.IS_TRACING

    def on_stage_start(mut self, name: StaticString) -> Int:
        """No-op start hook.

        Args:
            name: Stage label.

        Returns:
            `0`.
        """
        return 0

    def on_stage_end(mut self, name: StaticString, token: Int):
        """No-op end hook.

        Args:
            name: Stage label.
            token: Unused token.
        """
        pass

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        """No-op span recorder.

        Args:
            name: Stage label.
            start_ns: Start timestamp.
            end_ns: End timestamp.
        """
        pass


struct TracingExecutor[Inner: Executor & Movable & Deinitable = AsyncRTExecutor](
    Executor, Movable
):
    """Executor wrapper recording monotonic nanosecond spans for every stage.

    Parameters:
        Inner: Underlying concurrency policy (defaults to `AsyncRTExecutor`).
    """

    comptime IS_PARALLEL: Bool = Self.Inner.IS_PARALLEL
    """Inherits parallel capability from `Inner`."""
    comptime IS_TRACING: Bool = True
    """Enables per-stage tracing at compile time."""
    comptime IS_BOUNDED: Bool = Self.Inner.IS_BOUNDED
    """Inherits bounded wave behavior from `Inner`."""

    var inner: Self.Inner
    """Wrapped executor defining concurrency limits."""
    var spans: List[TraceSpan]
    """Collected stage execution spans in completion/recording order."""
    var _inner_tokens: List[Int]
    """Stack of active start tokens returned by `self.inner.on_stage_start`."""

    def __init__(out self, var inner: Self.Inner):
        """Initialize tracing around an explicit inner executor.

        Args:
            inner: Underlying executor policy.
        """
        self.inner = inner^
        self.spans = List[TraceSpan]()
        self._inner_tokens = List[Int]()

    def __init__(out self) where Self.Inner == AsyncRTExecutor:
        """Initialize tracing using the default `AsyncRTExecutor`."""
        self.inner = rebind_var[Self.Inner](AsyncRTExecutor())
        self.spans = List[TraceSpan]()
        self._inner_tokens = List[Int]()

    def concurrency_limit(self) -> Int:
        """Delegate concurrency limit to the inner executor.

        Returns:
            Inner executor's concurrency limit.
        """
        return self.inner.concurrency_limit()

    def is_tracing(self) -> Bool:
        """Return `True` to enable per-branch timestamp capture.

        Returns:
            `True`.
        """
        return Self.IS_TRACING

    def on_stage_start(mut self, name: StaticString) -> Int:
        """Capture start timestamp before stage execution.

        Args:
            name: Stage label.

        Returns:
            Start timestamp in nanoseconds from `perf_counter_ns()`.
        """
        self._inner_tokens.append(self.inner.on_stage_start(name))
        return perf_counter_ns()

    def on_stage_end(mut self, name: StaticString, token: Int):
        """Capture end timestamp and append a `TraceSpan`.

        Args:
            name: Stage label.
            token: Start timestamp returned by `on_stage_start`.
        """
        var end_ns = perf_counter_ns()
        var inner_token = (
            self._inner_tokens.pop() if len(self._inner_tokens) > 0 else 0
        )
        self.inner.on_stage_end(name, inner_token)
        self.spans.append(TraceSpan(name, token, end_ns))

    def record_span(mut self, name: StaticString, start_ns: Int, end_ns: Int):
        """Append a pre-measured span from a parallel branch.

        Args:
            name: Stage label.
            start_ns: Branch start timestamp in nanoseconds.
            end_ns: Branch end timestamp in nanoseconds.
        """
        self.inner.record_span(name, start_ns, end_ns)
        self.spans.append(TraceSpan(name, start_ns, end_ns))

    def clear(mut self):
        """Clear all previously recorded spans and internal token state."""
        self.spans.clear()
        self._inner_tokens.clear()

    def total_duration_ns(self) -> Int:
        """Return the sum of durations across all recorded spans.

        Returns:
            Total recorded stage duration in nanoseconds.
        """
        var total = 0
        for span in self.spans:
            total += span.duration_ns()
        return total

    def format_report(self) -> String:
        """Format recorded spans as a multi-line human-readable summary.

        Returns:
            Newline-separated report of stage names and durations.
        """
        var lines = List[String]()
        for span in self.spans:
            lines.append(String(span))
        return "\n".join(lines)
