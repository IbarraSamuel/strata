"""Tests for mutable void task pipelines."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.void import mutable

comptime TIME = 0.001


struct MutParallel(mutable.MutCallable):
    var start: Int
    var end: Int

    def __init__(out self):
        self.start = 0
        self.end = 0

    def __call__(mut self):
        self.start = monotonic()
        sleep(TIME)
        self.end = monotonic()


def test_mut_parallel() raises:
    comptime GP = MutParallel

    var p1 = GP()
    var p2 = GP()
    var p3 = GP()

    var graph = p1 + p2 + p3

    graph()

    assert_true(p1.start < p1.end)
    assert_true(p1.start < p2.end)
    assert_true(p1.start < p3.end)
    assert_true(p2.start < p1.end)
    assert_true(p2.start < p1.end)
    assert_true(p2.start < p2.end)
    assert_true(p3.start < p2.end)
    assert_true(p3.start < p3.end)
    assert_true(p3.start < p3.end)


@fieldwise_init
struct EMutParallel(mutable.MutCallable):
    def __call__(mut self):
        pass


def test_mut_two_parallels() raises:
    comptime GP = EMutParallel

    var p1 = GP()
    var p2 = GP()
    var p3 = GP()
    var p4 = GP()

    var f = p1 + p2 >> p3 + p4
    f()


@fieldwise_init
struct InitTask[name: String = "Init"](mutable.MutCallable):
    var value: Int

    def __call__(mut self):
        self.value += 1
        sleep(TIME)


def test_mut_examples() raises:
    comptime ST = mutable.SeriesTask
    comptime PT = mutable.ParallelTask

    var task1 = InitTask["first"](0)
    var task2 = InitTask["second"](0)
    var task31 = InitTask["third parallel 1"](1)
    var task32 = InitTask["third parallel 2"](1)
    var task33 = InitTask["third parallel 2"](1)
    var task34 = InitTask["third parallel 2"](1)
    var task4 = InitTask["pre-last"](2)
    var task5 = InitTask["last"](2)

    var grp = PT(task31, task32, task33, task34)
    var type_graph = ST(task1, task2, grp, task4, task5)
    type_graph()

    var graph = (
        task1 >> task2 >> task31 + task32 + task33 + task34 >> task4 >> task5
    )
    graph()


@fieldwise_init
struct MovableTask(mutable.MutCallable, Movable):
    var counter: Int

    def __call__(mut self):
        self.counter += 1


def test_mut_ref_and_var() raises:
    var t_ref = MovableTask(0)
    var t_var = MovableTask(10)

    # Test ref + var (MutCallable.__add__ with owned second argument)
    var par_rv = t_ref + t_var^
    par_rv()
    assert_equal(t_ref.counter, 1)

    # Test ref >> var (MutCallable.__rshift__ with owned second argument)
    var t_var2 = MovableTask(20)
    var seq_rv = t_ref >> t_var2^
    seq_rv()
    assert_equal(t_ref.counter, 2)

    # Test var + ref (_MovableMutCallable.__add__ with ref other argument)
    var r_target = MovableTask(0)
    var par_vr = (par_rv^) + r_target
    par_vr()
    assert_equal(r_target.counter, 1)

    # Test var >> ref (_MovableMutCallable.__rshift__ with ref other argument)
    var seq_vr = (seq_rv^) >> r_target
    seq_vr()
    assert_equal(r_target.counter, 2)

    # Test var + var (_MovableMutCallable.__add__ with owned other argument)
    var v_owned = MovableTask(5)
    var par_vv = (par_vr^) + (v_owned^)
    par_vv()

    # Test var >> var (_MovableMutCallable.__rshift__ with owned other argument)
    var v_owned2 = MovableTask(6)
    var seq_vv = (seq_vr^) >> (v_owned2^)
    seq_vv()


struct TimedMutTask(mutable.MutCallable, Movable):
    var count: Int
    var step: Int
    var start: Int
    var end: Int

    def __init__(out self, count: Int = 0, step: Int = 1):
        self.count = count
        self.step = step
        self.start = 0
        self.end = 0

    def __call__(mut self):
        self.start = monotonic()
        sleep(TIME)
        self.count += self.step
        self.end = monotonic()


def test_mut_complex_nested_workflow() raises:
    """Verify deep nested mutable pipelines mixing ref and owned (^) tasks.

    Pipeline topology:
    ```text
    [init]
      |
      +------------------+-------------------+
      v                  v                   v
    [b1a]              [b2a]               [b3a]
      |                  |                   |
      v             +----+----+              v
    [b1b]           v         v         [owned_b3b^]
      |          [b2b1]    [b2b2]            |
      |             |         |              |
      |             +----+----+              |
      |                  v                   |
      |                [b2c]                 |
      |                  |                   |
      +------------------+-------------------+
                         v
            +--------+--------+--------+
            v        v        v        v
           [p1]     [p2]     [p3]  [owned_p4^]
            |        |        |        |
            +--------+--------+--------+
                         v
                    [finalize]
    ```
    """
    var init = TimedMutTask(0, 1)
    var b1a = TimedMutTask(10, 2)
    var b1b = TimedMutTask(20, 3)
    var b2a = TimedMutTask(0, 4)
    var b2b1 = TimedMutTask(0, 5)
    var b2b2 = TimedMutTask(0, 6)
    var b2c = TimedMutTask(0, 7)
    var b3a = TimedMutTask(0, 8)
    var p1 = TimedMutTask(0, 1)
    var p2 = TimedMutTask(0, 2)
    var p3 = TimedMutTask(0, 3)
    var finalize = TimedMutTask(100, 10)

    var owned_b3b = TimedMutTask(0, 99)
    var owned_p4 = TimedMutTask(0, 50)

    var branch1 = b1a >> b1b
    var branch2_par = b2b1 + b2b2
    var branch2 = b2a >> (branch2_par^) >> b2c
    var branch3 = b3a >> owned_b3b^
    var mid_par = (branch1^) + (branch2^) + (branch3^)
    var tail_par = p1 + p2 + p3 + (owned_p4^)

    var graph = init >> (mid_par^) >> (tail_par^) >> finalize
    graph()

    assert_equal(init.count, 1)
    assert_equal(b1a.count, 12)
    assert_equal(b1b.count, 23)
    assert_equal(b2a.count, 4)
    assert_equal(b2b1.count, 5)
    assert_equal(b2b2.count, 6)
    assert_equal(b2c.count, 7)
    assert_equal(b3a.count, 8)
    assert_equal(p1.count, 1)
    assert_equal(p2.count, 2)
    assert_equal(p3.count, 3)
    assert_equal(finalize.count, 110)

    # Sequential dependency checks
    assert_true(init.end <= b1a.start)
    assert_true(init.end <= b2a.start)
    assert_true(init.end <= b3a.start)
    assert_true(b1a.end <= b1b.start)
    assert_true(b2a.end <= b2b1.start)
    assert_true(b2a.end <= b2b2.start)
    assert_true(b2b1.end <= b2c.start)
    assert_true(b2b2.end <= b2c.start)
    assert_true(b1b.end <= p1.start)
    assert_true(b2c.end <= p1.start)
    assert_true(p1.end <= finalize.start)
    assert_true(p2.end <= finalize.start)
    assert_true(p3.end <= finalize.start)

    # Parallel overlap checks
    assert_true(b2b1.start < b2b2.end)
    assert_true(b2b2.start < b2b1.end)
    assert_true(p1.start < p2.end)
    assert_true(p2.start < p1.end)

    # Re-run the composed mutable graph
    graph()
    assert_equal(init.count, 2)
    assert_equal(b1b.count, 26)
    assert_equal(b2c.count, 14)
    assert_equal(finalize.count, 120)


def test_mut_mixed_containers_and_owned() raises:
    """Verify SeriesTask, ParallelTask, ref tasks, and owned tasks combined.

    Pipeline topology:
    ```text
       +-> (SeriesTask: [t1] -> [t2]) ---+
       |                                 +-> (ParallelTask: [t4] + [t5])
       +-> ([t3] -> [owned^]) -----------+
    ```
    """
    comptime ST = mutable.SeriesTask
    comptime PT = mutable.ParallelTask

    var t1 = TimedMutTask(0, 1)
    var t2 = TimedMutTask(0, 2)
    var t3 = TimedMutTask(0, 3)
    var t4 = TimedMutTask(0, 4)
    var t5 = TimedMutTask(0, 5)
    var owned = TimedMutTask(0, 10)

    var left_seq = ST(t1, t2)
    var mid_seq = t3 >> (owned^)
    var right_par = PT(t4, t5)

    var graph = (left_seq + (mid_seq^)) >> right_par
    graph()

    assert_equal(t1.count, 1)
    assert_equal(t2.count, 2)
    assert_equal(t3.count, 3)
    assert_equal(t4.count, 4)
    assert_equal(t5.count, 5)
    assert_true(t1.end <= t2.start)
    assert_true(t2.end <= t4.start)
    assert_true(t3.end <= t5.start)
    assert_true(t4.start < t5.end)
    assert_true(t5.start < t4.end)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
