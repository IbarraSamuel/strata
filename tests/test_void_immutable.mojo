"""Tests for immutable void task pipelines."""

from std.testing import TestSuite, assert_true
from std.time import monotonic, sleep

from strata.void import immutable

comptime TIME = 0.001


struct ImmutParallel[o1: MutOrigin, o2: MutOrigin](immutable.ImmCallable):
    var start: Pointer[Int, Self.o1]
    var end: Pointer[Int, Self.o2]

    def __init__(out self, ref[Self.o1] s: Int, ref[Self.o2] e: Int):
        self.start = Pointer(to=s)
        self.end = Pointer(to=e)

    def __call__(self):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


def test_immut_parallel() raises:
    comptime GP = ImmutParallel

    var start1, end1 = (0, 0)
    var start2, end2 = (0, 0)
    var start3, end3 = (0, 0)

    var p1 = GP(start1, end1)
    var p2 = GP(start2, end2)
    var p3 = GP(start3, end3)

    var graph = p1 + p2 + p3

    graph()

    assert_true(p1.start[] < p1.end[])
    assert_true(p1.start[] < p2.end[])
    assert_true(p1.start[] < p3.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p2.end[])
    assert_true(p3.start[] < p2.end[])
    assert_true(p3.start[] < p3.end[])
    assert_true(p3.start[] < p3.end[])


@fieldwise_init
struct EImmutParallel(immutable.ImmCallable):
    def __call__(self):
        pass


def test_immut_two_parallels() raises:
    comptime GP = EImmutParallel

    var p1 = GP()
    var p2 = GP()

    var f = p1 + p2 >> p1 + p2
    f()


@fieldwise_init
struct MyTask[job: StringLiteral](immutable.ImmCallable):
    var some_data: String

    def __call__(self):
        sleep(TIME)


def test_immut_examples() raises:
    comptime IS = immutable.SequentialTask
    comptime IP = immutable.ParallelTask

    var init = MyTask["Initialize"]("Setting up...")
    var load = MyTask["Load Data"]("Reading from some place...")
    var find_min = MyTask["Min"]("Calculating...")
    var find_max = MyTask["Max"]("Calculating...")
    var find_mean = MyTask["Mean"]("Calculating...")
    var find_median = MyTask["Median"]("Calculating...")
    var merge_results = MyTask["Merge Results"]("Getting all together...")

    # Using Type syntax
    var graph_1 = IS(
        init,
        load,
        IP(find_min, find_max, find_mean, find_median),
        merge_results,
    )
    graph_1()

    # Airflow Syntax
    var graph_2 = (
        init
        >> load
        >> find_min + find_max + find_mean + find_median
        >> merge_results
    )
    graph_2()

    def first_task():
        sleep(TIME)

    def last_task():
        sleep(TIME)

    def parallel_some():
        sleep(TIME)

    def parallel2():
        sleep(TIME)

    comptime Fn = immutable.Fn

    var ft = Fn(first_task)
    var ps = Fn(parallel_some)
    var p2 = Fn(parallel2)
    var lt = Fn(last_task)
    var fn_graph = ft >> ps + p2 + ps >> lt
    fn_graph()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
