"""Tests for async mutable void task pipelines."""

from std.testing import TestSuite, assert_equal, assert_true
from std.time import monotonic, sleep

from strata.void import async_mutable

comptime TIME = 0.001


@fieldwise_init
struct MutAsyncCounter(async_mutable.AsyncCallable, Movable):
    var count: Int

    __async def __call__(mut self):
        sleep(TIME)
        self.count += 1


def test_async_mutable_ref_series() raises:
    var t1 = MutAsyncCounter(0)
    var t2 = MutAsyncCounter(10)

    var ser = t1 >> t2
    ser.run()

    assert_equal(t1.count, 1)
    assert_equal(t2.count, 11)


def test_async_mutable_ref_parallel() raises:
    var t1 = MutAsyncCounter(0)
    var t2 = MutAsyncCounter(10)

    var par = t1 + t2
    par.run()

    assert_equal(t1.count, 1)
    assert_equal(t2.count, 11)


def test_async_mutable_ref_and_var() raises:
    var t_ref = MutAsyncCounter(0)
    var t_var = MutAsyncCounter(20)

    # ref + var
    var par = t_ref + (t_var^)
    par.run()
    assert_equal(t_ref.count, 1)

    # ref >> var
    var t_var2 = MutAsyncCounter(30)
    var ser = t_ref >> (t_var2^)
    ser.run()
    assert_equal(t_ref.count, 2)


def test_async_mutable_movable() raises:
    var t_ref = MutAsyncCounter(0)
    var t_var = MutAsyncCounter(10)

    # First construct a SerTaskPair (which implements AsyncCallableMovable)
    var ser1 = t_ref >> (t_var^)

    # var >> ref (AsyncCallableMovable.__rshift__ with ref)
    var t_ref2 = MutAsyncCounter(50)
    var ser2 = (ser1^) >> t_ref2
    ser2.run()
    assert_equal(t_ref2.count, 51)

    # var >> var (AsyncCallableMovable.__rshift__ with var)
    var t_var3 = MutAsyncCounter(100)
    var ser3 = (ser2^) >> (t_var3^)
    ser3.run()

    # var + ref (AsyncCallableMovable.__add__ with ref)
    var t_ref3 = MutAsyncCounter(60)
    var par1 = (ser3^) + t_ref3
    par1.run()
    assert_equal(t_ref3.count, 61)

    # var + var (AsyncCallableMovable.__add__ with var)
    var t_var4 = MutAsyncCounter(200)
    var par2 = (par1^) + (t_var4^)
    par2.run()


struct TimedAsyncMutCounter(async_mutable.AsyncCallable, Movable):
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


def test_async_mutable_nested_diamond() raises:
    """Verify nested async mutable diamond mixing ref and owned (^) tasks.

    Pipeline topology:
    ```text
    [init]
      |
      +------------------+-------------------+
      v                  v                   v
    [b1a]              [b2a]            [owned_b3^]
      |                  |                   |
      v             +----+----+              |
    [b1b]           v         v              |
      |          [b2b1]    [b2b2]            |
      |             |         |              |
      +-------------+---------+--------------+
                         v
                    [finalize]
    ```
    """
    var init = TimedAsyncMutCounter(0, 1)
    var b1a = TimedAsyncMutCounter(10, 2)
    var b1b = TimedAsyncMutCounter(20, 3)
    var b2a = TimedAsyncMutCounter(0, 4)
    var b2b1 = TimedAsyncMutCounter(0, 5)
    var b2b2 = TimedAsyncMutCounter(0, 6)
    var finalize = TimedAsyncMutCounter(100, 10)
    var owned_b3 = TimedAsyncMutCounter(0, 99)

    var branch1 = b1a >> b1b
    var branch2_par = b2b1 + b2b2
    var branch2 = b2a >> (branch2_par^)
    var mid_par = (branch1^) + (branch2^) + (owned_b3^)

    var graph = init >> (mid_par^) >> finalize
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

    # Re-run the graph and verify all ref counters accumulate
    graph.run()
    assert_equal(init.count, 2)
    assert_equal(b1b.count, 26)
    assert_equal(b2b1.count, 10)
    assert_equal(finalize.count, 120)


def test_async_mutable_owned_barriers() raises:
    """Verify chained parallel async mutable barriers with owned branches.

    Pipeline topology:
    ```text
    +-> [p1] -+     +-> [q1] -------+     +-> [r1] -------+
    |         + --> |               + --> |               + --> (done)
    +-> [p2] -+     +-> [owned_q2^]-+     +-> [owned_r2^]-+
    ```
    """
    var p1 = TimedAsyncMutCounter(0, 1)
    var p2 = TimedAsyncMutCounter(0, 2)
    var q1 = TimedAsyncMutCounter(0, 3)
    var owned_q2 = TimedAsyncMutCounter(0, 4)
    var r1 = TimedAsyncMutCounter(0, 5)
    var owned_r2 = TimedAsyncMutCounter(0, 6)

    var stage1 = p1 + p2
    var stage2 = q1 + (owned_q2^)
    var stage3 = r1 + (owned_r2^)
    var graph = (stage1^) >> (stage2^) >> (stage3^)

    graph.run()

    assert_equal(p1.count, 1)
    assert_equal(p2.count, 2)
    assert_equal(q1.count, 3)
    assert_equal(r1.count, 5)

    assert_true(p1.start < p2.end)
    assert_true(p2.start < p1.end)
    assert_true(p1.end <= q1.start)
    assert_true(p2.end <= q1.start)
    assert_true(q1.end <= r1.start)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
