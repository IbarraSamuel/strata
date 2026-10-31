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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
