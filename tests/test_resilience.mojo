"""Tests for resilience combinators (`Retry`, `Fallback`, `Timeout`, `Recover`)."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from std.time import sleep

from strata.pipeline import Fn
from strata.pipeline.fallible import ComposableFallibleStage, RaisingFn
from strata.pipeline.resilience import fallback, recover, retry, timeout


struct FlakyStage(ComposableFallibleStage):
    """Fails the first `fail_count` invocations before succeeding."""

    comptime I = Int
    comptime O = Int

    var fail_count: Int
    var attempts: Pointer[Int, MutUntrackedOrigin]

    def __init__(
        out self, fail_count: Int, attempts: Pointer[Int, MutUntrackedOrigin]
    ):
        self.fail_count = fail_count
        self.attempts = attempts

    def __call__(self, arg: Int) raises -> Int:
        self.attempts[] += 1
        if self.attempts[] <= self.fail_count:
            raise Error(String("transient failure #", self.attempts[]))
        return arg * 10


def _always_fail(x: Int) raises -> Int:
    raise Error(String("permanent boom: ", x))


def _backup_stage(x: Int) raises -> Int:
    return x + 100


def _slow_stage(x: Int) raises -> Int:
    sleep(0.05)
    return x + 1


def _fast_stage(x: Int) raises -> Int:
    return x + 1


def _recover_handler(x: Int, err_msg: String) -> Int:
    return -x


def _double(x: Int) -> Int:
    return x * 2


def test_retry_succeeds_after_transient_failures() raises:
    var attempts = 0
    var flaky = FlakyStage(
        2, Pointer(to=attempts).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var r = retry(flaky, max_attempts=3, backoff_secs=0.001)
    assert_equal(r(7), 70)
    assert_equal(attempts, 3)


def test_retry_exhausted_raises() raises:
    var attempts = 0
    var flaky = FlakyStage(
        5, Pointer(to=attempts).unsafe_origin_cast[MutUntrackedOrigin]()
    )
    var r = retry(flaky, max_attempts=2)
    with assert_raises(contains="transient failure #2"):
        _ = r(7)
    assert_equal(attempts, 2)


def test_fallback_on_error() raises:
    var primary = RaisingFn(_always_fail)
    var backup = RaisingFn(_backup_stage)
    var safe = fallback(primary, backup)

    assert_equal(safe(5), 105)

    # Primary succeeding skips fallback
    var good = RaisingFn(_fast_stage)
    var ok = fallback(good, backup)
    assert_equal(ok(5), 6)


def test_timeout_pass_and_exceed() raises:
    var fast = RaisingFn(_fast_stage)
    var slow = RaisingFn(_slow_stage)

    var guarded_fast = timeout(fast, timeout_secs=1.0)
    assert_equal(guarded_fast(41), 42)

    var guarded_slow = timeout(slow, timeout_secs=0.01)
    with assert_raises(contains="timed out"):
        _ = guarded_slow(41)


def test_recover_bridges_to_infallible_pipeline() raises:
    var boom = RaisingFn(_always_fail)
    var ok = RaisingFn(_fast_stage)
    var dbl = Fn(_double)

    var recovered_boom = recover(boom, _recover_handler) | dbl
    assert_equal(recovered_boom(5), -10)

    var recovered_ok = recover(ok, _recover_handler) | dbl
    assert_equal(recovered_ok(5), 12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
