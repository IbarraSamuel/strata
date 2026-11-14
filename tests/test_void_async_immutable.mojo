"""Tests for async immutable void task pipelines."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.void import async_immutable

comptime TIME = 0.001


@fieldwise_init
struct ATask(async_immutable.AsyncCallable):
    __async def __call__(self):
        sleep(TIME)


@fieldwise_init
struct ATask2(async_immutable.AsyncCallable):
    __async def __call__(self):
        sleep(TIME)


def test_immutable() raises:
    var graph = (
        ATask()
        >> ATask()
        >> ATask()
        >> ATask2() + ATask2() + ATask2()
        >> ATask()
        >> ATask()
    )
    graph.run()


def test_par_task_pair_run() raises:
    var t1 = ATask()
    var t2 = ATask2()
    var par_pair = t1 + t2
    par_pair.run()


struct TimedAsyncImmutStep[o1: MutOrigin, o2: MutOrigin, o3: MutOrigin](
    async_immutable.AsyncCallable
):
    var start: Pointer[Int, Self.o1]
    var end: Pointer[Int, Self.o2]
    var hits: Pointer[Int, Self.o3]

    def __init__(
        out self,
        ref[Self.o1] s: Int,
        ref[Self.o2] e: Int,
        ref[Self.o3] h: Int,
    ):
        self.start = Pointer(to=s)
        self.end = Pointer(to=e)
        self.hits = Pointer(to=h)

    __async def __call__(self):
        self.start[] = monotonic()
        sleep(TIME)
        self.hits[] += 1
        self.end[] = monotonic()


def test_async_immut_complex_workflow() raises:
    """Verify deep nested async immutable void pipelines.

    Pipeline topology:
    ```text
    [s1] -> [s2]
             |
        +----+--------------+---------+
        v                   v         v
      [b1a]               [b2a]      [b3]
        |                   |         |
        v              +----+----+    |
      [b1b]            v         v    |
        |           [b2b1]    [b2b2]  |
        |              |         |    |
        |              +----+----+    |
        |                   v         |
        |                 [b2c]       |
        |                   |         |
        +-------------------+---------+
                            v
              +------+------+------+
              v      v      v      v
             [p1]   [p2]   [p3]   [p4]
              |      |      |      |
              +------+------+------+
                            v
                          [fin]
    ```
    """
    var s1_s, s1_e, s1_h = (0, 0, 0)
    var s2_s, s2_e, s2_h = (0, 0, 0)
    var b1a_s, b1a_e, b1a_h = (0, 0, 0)
    var b1b_s, b1b_e, b1b_h = (0, 0, 0)
    var b2a_s, b2a_e, b2a_h = (0, 0, 0)
    var b2b1_s, b2b1_e, b2b1_h = (0, 0, 0)
    var b2b2_s, b2b2_e, b2b2_h = (0, 0, 0)
    var b2c_s, b2c_e, b2c_h = (0, 0, 0)
    var b3_s, b3_e, b3_h = (0, 0, 0)
    var p1_s, p1_e, p1_h = (0, 0, 0)
    var p2_s, p2_e, p2_h = (0, 0, 0)
    var p3_s, p3_e, p3_h = (0, 0, 0)
    var p4_s, p4_e, p4_h = (0, 0, 0)
    var fin_s, fin_e, fin_h = (0, 0, 0)

    var s1 = TimedAsyncImmutStep(s1_s, s1_e, s1_h)
    var s2 = TimedAsyncImmutStep(s2_s, s2_e, s2_h)
    var b1a = TimedAsyncImmutStep(b1a_s, b1a_e, b1a_h)
    var b1b = TimedAsyncImmutStep(b1b_s, b1b_e, b1b_h)
    var b2a = TimedAsyncImmutStep(b2a_s, b2a_e, b2a_h)
    var b2b1 = TimedAsyncImmutStep(b2b1_s, b2b1_e, b2b1_h)
    var b2b2 = TimedAsyncImmutStep(b2b2_s, b2b2_e, b2b2_h)
    var b2c = TimedAsyncImmutStep(b2c_s, b2c_e, b2c_h)
    var b3 = TimedAsyncImmutStep(b3_s, b3_e, b3_h)
    var p1 = TimedAsyncImmutStep(p1_s, p1_e, p1_h)
    var p2 = TimedAsyncImmutStep(p2_s, p2_e, p2_h)
    var p3 = TimedAsyncImmutStep(p3_s, p3_e, p3_h)
    var p4 = TimedAsyncImmutStep(p4_s, p4_e, p4_h)
    var fin = TimedAsyncImmutStep(fin_s, fin_e, fin_h)

    var head_seq = s1 >> s2
    var branch1 = b1a >> b1b
    var branch2_par = b2b1 + b2b2
    var branch2 = b2a >> branch2_par >> b2c
    var mid_par = branch1 + branch2 + b3
    var tail_par = p1 + p2 + p3 + p4
    var graph = head_seq >> mid_par >> tail_par >> fin

    graph.run()

    assert_equal(s1_h, 1)
    assert_equal(s2_h, 1)
    assert_equal(b1a_h, 1)
    assert_equal(b1b_h, 1)
    assert_equal(b2a_h, 1)
    assert_equal(b2b1_h, 1)
    assert_equal(b2b2_h, 1)
    assert_equal(b2c_h, 1)
    assert_equal(b3_h, 1)
    assert_equal(p1_h, 1)
    assert_equal(p2_h, 1)
    assert_equal(p3_h, 1)
    assert_equal(p4_h, 1)
    assert_equal(fin_h, 1)

    assert_true(s1_e <= s2_s)
    assert_true(s2_e <= b1a_s)
    assert_true(s2_e <= b2a_s)
    assert_true(s2_e <= b3_s)
    assert_true(b1a_e <= b1b_s)
    assert_true(b2a_e <= b2b1_s)
    assert_true(b2a_e <= b2b2_s)
    assert_true(b2b1_e <= b2c_s)
    assert_true(b2b2_e <= b2c_s)
    assert_true(b1b_e <= p1_s)
    assert_true(b2c_e <= p1_s)
    assert_true(b3_e <= p1_s)
    assert_true(p1_e <= fin_s)
    assert_true(p2_e <= fin_s)
    assert_true(p3_e <= fin_s)
    assert_true(p4_e <= fin_s)

    assert_true(b2b1_s < b2b2_e)
    assert_true(b2b2_s < b2b1_e)
    assert_true(p1_s < p2_e)
    assert_true(p2_s < p1_e)
    assert_true(p3_s < p4_e)
    assert_true(p4_s < p3_e)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
