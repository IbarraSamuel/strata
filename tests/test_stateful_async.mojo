"""Tests for Strata v2 async stateful pipelines (`strata.stateful.async_stage`)."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.stateful import async_stage

comptime TIME = 0.001


struct TimedAsyncStage(async_stage.AsyncMutStage, Movable):
    var count: Int
    var step: Int
    var start: Int
    var end: Int

    def __init__(out self, count: Int = 0, step: Int = 1):
        self.count = count
        self.step = step
        self.start = 0
        self.end = 0

    __async def __call__(mut self):
        self.start = monotonic()
        sleep(TIME)
        self.count += self.step
        self.end = monotonic()


def test_async_stateful_flat_parallel_and_diamond() raises:
    var init = TimedAsyncStage(0, 1)
    var b1a = TimedAsyncStage(10, 2)
    var b1b = TimedAsyncStage(20, 3)
    var b2a = TimedAsyncStage(0, 4)
    var b2b1 = TimedAsyncStage(0, 5)
    var b2b2 = TimedAsyncStage(0, 6)
    var finalize = TimedAsyncStage(100, 10)
    var owned_branch = TimedAsyncStage(0, 99)

    var branch1 = b1a | b1b
    var branch2_par = b2b1 & b2b2
    var branch2 = b2a | (branch2_par^)
    var mid_par = (branch1^) & (branch2^) & (owned_branch^)
    var graph = init | (mid_par^) | finalize

    graph.run()

    assert_equal(init.count, 1)
    assert_equal(b1a.count, 12)
    assert_equal(b1b.count, 23)
    assert_equal(b2a.count, 4)
    assert_equal(b2b1.count, 5)
    assert_equal(b2b2.count, 6)
    assert_equal(finalize.count, 110)

    assert_true(init.end <= b1a.start)
    assert_true(init.end <= b2a.start)
    assert_true(b1a.end <= b1b.start)
    assert_true(b2a.end <= b2b1.start)
    assert_true(b2a.end <= b2b2.start)
    assert_true(b1b.end <= finalize.start)
    assert_true(b2b1.end <= finalize.start)
    assert_true(b2b2.end <= finalize.start)

    assert_true(b2b1.start < b2b2.end)
    assert_true(b2b2.start < b2b1.end)

    # Re-run to verify stateful accumulation
    graph.run()
    assert_equal(init.count, 2)
    assert_equal(b1b.count, 26)
    assert_equal(finalize.count, 120)


def test_async_stateful_associative_parallel_merge() raises:
    var p1 = TimedAsyncStage(0, 1)
    var p2 = TimedAsyncStage(0, 2)
    var p3 = TimedAsyncStage(0, 3)
    var p4 = TimedAsyncStage(0, 4)

    var left = p1 & p2
    var right = p3 & p4
    var merged = (left^) & (right^)
    merged.run()

    assert_equal(p1.count, 1)
    assert_equal(p2.count, 2)
    assert_equal(p3.count, 3)
    assert_equal(p4.count, 4)
    assert_true(p1.start < p4.end)
    assert_true(p4.start < p1.end)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
