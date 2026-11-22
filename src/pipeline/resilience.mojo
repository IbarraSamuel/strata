"""Resilience combinators for fallible Mojo pipelines.

Provides composable fault-tolerance wrappers built on `FallibleStage`:

- `Retry`: Retries a failing stage up to `max_attempts` with optional
  exponential backoff.
- `Fallback`: Runs a secondary fallible stage if the primary stage raises.
- `Timeout`: Enforces a wall-clock deadline on a fallible stage (cooperative
  post-execution check).
- `Recover`: Bridges a `FallibleStage` into a non-raising `ComposableStage`
  via a recovery handler.
"""

from std.time import perf_counter_ns, sleep
from std.utils.numerics import isinf, isnan

from . import ComposableStage
from .fallible import ComposableFallibleStage, FallibleStage

comptime _MAX_RETRY_DELAY_SECS: Float64 = 86400.0
comptime _MAX_TIMEOUT_SECS: Float64 = 9_223_372_036.0


struct Retry[origin: ImmOrigin, //, Inner: FallibleStage](
    ComposableFallibleStage
):
    """Retry a fallible stage up to `max_attempts` with optional backoff.

    Parameters:
        origin: Origin of the wrapped fallible stage reference.
        Inner: Fallible stage type to retry.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the wrapped fallible stage."""
    var max_attempts: Int
    """Maximum total attempts (clamped to `>= 1`)."""
    var backoff_secs: Float64
    """Initial delay in seconds before the first retry."""
    var backoff_multiplier: Float64
    """Factor multiplying the delay after each failed attempt."""

    def __init__(
        out self,
        ref[Self.origin] inner: Self.Inner,
        max_attempts: Int = 3,
        backoff_secs: Float64 = 0.0,
        backoff_multiplier: Float64 = 2.0,
    ):
        """Initialize a retry wrapper around `inner`.

        Args:
            inner: Fallible stage to retry.
            max_attempts: Maximum number of attempts (`>= 1`).
            backoff_secs: Initial sleep delay before retrying (seconds).
            backoff_multiplier: Exponential multiplier applied between retries.
        """
        self.inner = Pointer(to=inner)
        self.max_attempts = max_attempts if max_attempts > 0 else 1
        if isnan(backoff_secs) or isinf(backoff_secs) or backoff_secs <= 0.0:
            self.backoff_secs = 0.0
        elif backoff_secs > _MAX_RETRY_DELAY_SECS:
            self.backoff_secs = _MAX_RETRY_DELAY_SECS
        else:
            self.backoff_secs = backoff_secs
        if (
            isnan(backoff_multiplier)
            or isinf(backoff_multiplier)
            or backoff_multiplier <= 0.0
        ):
            self.backoff_multiplier = 1.0
        else:
            self.backoff_multiplier = backoff_multiplier

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute `inner(arg)`, retrying up to `max_attempts` on failure.

        Args:
            arg: Input argument.

        Returns:
            Result from the first successful attempt.

        Raises:
            Error: The error from the final failed attempt.
        """
        var delay = self.backoff_secs
        var last_err = String("")
        for attempt in range(self.max_attempts):
            try:
                return self.inner[](arg)
            except e:
                last_err = String(e)
                if (
                    attempt + 1 < self.max_attempts
                    and not isnan(delay)
                    and not isinf(delay)
                    and delay > 0.0
                ):
                    sleep(delay)
                    var next_delay = delay * self.backoff_multiplier
                    if (
                        isnan(next_delay)
                        or isinf(next_delay)
                        or next_delay > _MAX_RETRY_DELAY_SECS
                    ):
                        delay = _MAX_RETRY_DELAY_SECS
                    else:
                        delay = next_delay
        raise Error(last_err)


def retry[
    origin: ImmOrigin, //, Inner: FallibleStage
](
    ref[origin] inner: Inner,
    max_attempts: Int = 3,
    backoff_secs: Float64 = 0.0,
    backoff_multiplier: Float64 = 2.0,
) -> Retry[origin=origin, Inner]:
    """Wrap a fallible stage with automatic retry and optional backoff.

    Parameters:
        origin: Origin of `inner`.
        Inner: Fallible stage type.

    Args:
        inner: Fallible stage to wrap.
        max_attempts: Maximum number of attempts (`>= 1`).
        backoff_secs: Initial delay between retries in seconds.
        backoff_multiplier: Exponential backoff factor.

    Returns:
        A `Retry` stage conforming to `ComposableFallibleStage`.
    """
    return Retry(inner, max_attempts, backoff_secs, backoff_multiplier)


struct Fallback[
    O1: ImmOrigin,
    O2: ImmOrigin,
    //,
    Primary: FallibleStage,
    Secondary: FallibleStage,
](ComposableFallibleStage):
    """Run `secondary` if `primary` raises an error.

    Parameters:
        O1: Origin of `primary`.
        O2: Origin of `secondary`.
        Primary: Primary fallible stage type.
        Secondary: Fallback fallible stage type with matching `I` and `O`.
    """

    comptime I = Self.Primary.I
    """Input type."""
    comptime O = Self.Primary.O
    """Output type."""

    var primary: Pointer[Self.Primary, Self.O1]
    """Pointer to the primary stage."""
    var secondary: Pointer[Self.Secondary, Self.O2]
    """Pointer to the fallback stage."""

    def __init__(
        out self,
        ref[Self.O1] primary: Self.Primary,
        ref[Self.O2] secondary: Self.Secondary,
    ) where (Self.Primary.I == Self.Secondary.I) and (
        Self.Primary.O == Self.Secondary.O
    ):
        """Initialize with references to primary and fallback stages.

        Args:
            primary: Primary stage tried first.
            secondary: Fallback stage called if `primary` raises.
        """
        self.primary = Pointer(to=primary)
        self.secondary = Pointer(to=secondary)

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute `primary(arg)`, falling back to `secondary(arg)` on error.

        Args:
            arg: Input argument.

        Returns:
            Result of `primary` if it succeeds, otherwise result of `secondary`.

        Raises:
            Error: If both `primary` and `secondary` raise.
        """
        try:
            return self.primary[](arg)
        except:
            return rebind_var[Self.O](
                self.secondary[](rebind[Self.Secondary.I](arg))
            )


def fallback[
    O1: ImmOrigin,
    O2: ImmOrigin,
    //,
    Primary: FallibleStage,
    Secondary: FallibleStage,
](
    ref[O1] primary: Primary,
    ref[O2] secondary: Secondary,
) -> Fallback[O1=O1, O2=O2, Primary, Secondary] where (
    Primary.I == Secondary.I
) and (Primary.O == Secondary.O):
    """Create a `Fallback` stage that invokes `secondary` when `primary` fails.

    Parameters:
        O1: Origin of `primary`.
        O2: Origin of `secondary`.
        Primary: Primary fallible stage type.
        Secondary: Fallback fallible stage type.

    Args:
        primary: Stage attempted first.
        secondary: Stage invoked if `primary` raises.

    Returns:
        A `Fallback` stage conforming to `ComposableFallibleStage`.
    """
    return Fallback(primary, secondary)


struct Timeout[origin: ImmOrigin, //, Inner: FallibleStage](
    ComposableFallibleStage
):
    """Enforce a wall-clock execution deadline on a fallible stage.

    Note:
        Because Mojo's `TaskGroup` does not preemptively cancel running tasks,
        this performs a cooperative post-execution deadline check and raises an
        `Error` if elapsed duration exceeds `timeout_secs`.

    Parameters:
        origin: Origin of `inner`.
        Inner: Wrapped fallible stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the wrapped fallible stage."""
    var timeout_ns: Int
    """Maximum allowed duration in nanoseconds."""

    def __init__(
        out self,
        ref[Self.origin] inner: Self.Inner,
        timeout_secs: Float64,
    ):
        """Initialize a timeout wrapper.

        Args:
            inner: Fallible stage to guard.
            timeout_secs: Deadline in seconds.
        """
        self.inner = Pointer(to=inner)
        if isnan(timeout_secs) or timeout_secs <= 0.0:
            self.timeout_ns = 0
        elif isinf(timeout_secs) or timeout_secs >= _MAX_TIMEOUT_SECS:
            self.timeout_ns = Int.MAX
        else:
            var ns = Int(timeout_secs * 1_000_000_000.0)
            self.timeout_ns = ns if ns > 0 else 0

    def __call__(self, arg: Self.I) raises -> Self.O:
        """Execute `inner(arg)` and raise if execution exceeds `timeout_ns`.

        Args:
            arg: Input argument.

        Returns:
            Result of `inner(arg)` when completed within the deadline.

        Raises:
            Error: If `inner` raises or exceeds the configured timeout.
        """
        var start_ns = perf_counter_ns()
        var out = self.inner[](arg)
        var elapsed_ns = perf_counter_ns() - start_ns
        if elapsed_ns > self.timeout_ns:
            raise Error(
                String(
                    "Stage timed out after ",
                    elapsed_ns,
                    "ns (limit: ",
                    self.timeout_ns,
                    "ns)",
                )
            )
        return out^


def timeout[
    origin: ImmOrigin, //, Inner: FallibleStage
](ref[origin] inner: Inner, timeout_secs: Float64) -> Timeout[
    origin=origin, Inner
]:
    """Wrap a fallible stage with a wall-clock timeout check.

    Parameters:
        origin: Origin of `inner`.
        Inner: Fallible stage type.

    Args:
        inner: Fallible stage to guard.
        timeout_secs: Maximum allowed duration in seconds.

    Returns:
        A `Timeout` stage conforming to `ComposableFallibleStage`.
    """
    return Timeout(inner, timeout_secs)


struct Recover[origin: ImmOrigin, //, Inner: FallibleStage](ComposableStage):
    """Bridge a `FallibleStage` into a non-raising `ComposableStage`.

    If `inner(arg)` raises, `handler(arg, String(error))` computes a recovery
    output so downstream infallible `|` / `&` stages can compose cleanly.

    Parameters:
        origin: Origin of `inner`.
        Inner: Wrapped fallible stage type.
    """

    comptime I = Self.Inner.I
    """Input type."""
    comptime O = Self.Inner.O
    """Output type."""

    var inner: Pointer[Self.Inner, Self.origin]
    """Pointer to the fallible stage."""
    var handler: def(Self.I, String) thin -> Self.O
    """Recovery handler invoked with `(arg, error_message)` on failure."""

    def __init__(
        out self,
        ref[Self.origin] inner: Self.Inner,
        handler: def(Self.I, String) thin -> Self.O,
    ):
        """Initialize a recovery adapter around `inner`.

        Args:
            inner: Fallible stage to execute.
            handler: Non-raising function producing a fallback value on error.
        """
        self.inner = Pointer(to=inner)
        self.handler = handler

    def __call__(self, arg: Self.I) -> Self.O:
        """Execute `inner(arg)`, calling `handler` if an error is raised.

        Args:
            arg: Input argument.

        Returns:
            Result of `inner(arg)` or `handler(arg, error_message)`.
        """
        try:
            return self.inner[](arg)
        except e:
            return self.handler(arg, String(e))


def recover[
    origin: ImmOrigin, //, Inner: FallibleStage
](
    ref[origin] inner: Inner,
    handler: def(Inner.I, String) thin -> Inner.O,
) -> Recover[origin=origin, Inner]:
    """Convert a `FallibleStage` into an infallible `ComposableStage` via `handler`.

    Parameters:
        origin: Origin of `inner`.
        Inner: Fallible stage type.

    Args:
        inner: Fallible stage to protect.
        handler: Recovery function `(input, error_message) -> output`.

    Returns:
        A `Recover` stage conforming to `ComposableStage`.
    """
    return Recover(inner, handler)
