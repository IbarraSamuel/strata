"""Tests for immutable void task pipelines."""

from std.testing import TestSuite, assert_true, assert_equal
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


struct TimedImmutStep[o1: MutOrigin, o2: MutOrigin, o3: MutOrigin](
    immutable.ImmCallable
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

    def __call__(self):
        self.start[] = monotonic()
        sleep(TIME)
        self.hits[] += 1
        self.end[] = monotonic()


def test_immut_complex_nested_pipeline() raises:
    """Verify nested immutable void pipelines with ordering and overlap checks.

    Pipeline topology:
    ```text
    [init1] -> [init2]
                  |
        +---------+-------------------+---------+
        v         v                   v         |
      [b1a]     [b2a]                [b3]       |
        |         |                   |         |
        v     +---+---+               |         |
      [b1b]   v       v               |         |
        |   [b2b1]  [b2b2]            |         |
        |     |       |               |         |
        |     +---+---+               |         |
        |         v                   |         |
        |       [b2c]                 |         |
        |         |                   |         |
        +---------+-------------------+         |
                  v                             |
        +---------+---------+---------+         |
        v         v         v         v         |
       [p1]      [p2]      [p3]      [p4]       |
        |         |         |         |         |
        +---------+---------+---------+         |
                  v                             |
                [fin] <-------------------------+
    ```
    """
    var s_init1, e_init1, h_init1 = (0, 0, 0)
    var s_init2, e_init2, h_init2 = (0, 0, 0)
    var s_b1a, e_b1a, h_b1a = (0, 0, 0)
    var s_b1b, e_b1b, h_b1b = (0, 0, 0)
    var s_b2a, e_b2a, h_b2a = (0, 0, 0)
    var s_b2b1, e_b2b1, h_b2b1 = (0, 0, 0)
    var s_b2b2, e_b2b2, h_b2b2 = (0, 0, 0)
    var s_b2c, e_b2c, h_b2c = (0, 0, 0)
    var s_b3, e_b3, h_b3 = (0, 0, 0)
    var s_p1, e_p1, h_p1 = (0, 0, 0)
    var s_p2, e_p2, h_p2 = (0, 0, 0)
    var s_p3, e_p3, h_p3 = (0, 0, 0)
    var s_p4, e_p4, h_p4 = (0, 0, 0)
    var s_fin, e_fin, h_fin = (0, 0, 0)

    var init1 = TimedImmutStep(s_init1, e_init1, h_init1)
    var init2 = TimedImmutStep(s_init2, e_init2, h_init2)
    var b1a = TimedImmutStep(s_b1a, e_b1a, h_b1a)
    var b1b = TimedImmutStep(s_b1b, e_b1b, h_b1b)
    var b2a = TimedImmutStep(s_b2a, e_b2a, h_b2a)
    var b2b1 = TimedImmutStep(s_b2b1, e_b2b1, h_b2b1)
    var b2b2 = TimedImmutStep(s_b2b2, e_b2b2, h_b2b2)
    var b2c = TimedImmutStep(s_b2c, e_b2c, h_b2c)
    var b3 = TimedImmutStep(s_b3, e_b3, h_b3)
    var p1 = TimedImmutStep(s_p1, e_p1, h_p1)
    var p2 = TimedImmutStep(s_p2, e_p2, h_p2)
    var p3 = TimedImmutStep(s_p3, e_p3, h_p3)
    var p4 = TimedImmutStep(s_p4, e_p4, h_p4)
    var fin = TimedImmutStep(s_fin, e_fin, h_fin)

    # Topology:
    # (init1 >> init2)
    #   >> ((b1a >> b1b) + (b2a >> (b2b1 + b2b2) >> b2c) + b3)
    #   >> (p1 + p2 + p3 + p4)
    #   >> fin
    var init_seq = init1 >> init2
    var branch1 = b1a >> b1b
    var branch2_inner_par = b2b1 + b2b2
    var branch2 = b2a >> branch2_inner_par >> b2c
    var mid_fanout = branch1 + branch2 + b3
    var tail_fanout = p1 + p2 + p3 + p4
    var graph = init_seq >> mid_fanout >> tail_fanout >> fin

    graph()

    # Every node ran once
    assert_equal(h_init1, 1)
    assert_equal(h_init2, 1)
    assert_equal(h_b1a, 1)
    assert_equal(h_b1b, 1)
    assert_equal(h_b2a, 1)
    assert_equal(h_b2b1, 1)
    assert_equal(h_b2b2, 1)
    assert_equal(h_b2c, 1)
    assert_equal(h_b3, 1)
    assert_equal(h_p1, 1)
    assert_equal(h_p2, 1)
    assert_equal(h_p3, 1)
    assert_equal(h_p4, 1)
    assert_equal(h_fin, 1)

    # Sequential ordering guarantees
    assert_true(e_init1 <= s_init2)
    assert_true(e_init2 <= s_b1a)
    assert_true(e_init2 <= s_b2a)
    assert_true(e_init2 <= s_b3)
    assert_true(e_b1a <= s_b1b)
    assert_true(e_b2a <= s_b2b1)
    assert_true(e_b2a <= s_b2b2)
    assert_true(e_b2b1 <= s_b2c)
    assert_true(e_b2b2 <= s_b2c)
    assert_true(e_b1b <= s_p1)
    assert_true(e_b2c <= s_p1)
    assert_true(e_b3 <= s_p1)
    assert_true(e_p1 <= s_fin)
    assert_true(e_p2 <= s_fin)
    assert_true(e_p3 <= s_fin)
    assert_true(e_p4 <= s_fin)

    # Parallel overlap guarantees
    assert_true(s_b2b1 < e_b2b2)
    assert_true(s_b2b2 < e_b2b1)
    assert_true(s_p1 < e_p2)
    assert_true(s_p2 < e_p1)
    assert_true(s_p3 < e_p4)
    assert_true(s_p4 < e_p3)


def test_immut_mixed_containers_and_fn() raises:
    """Verify mixing SequentialTask, ParallelTask, Fn, and operators.

    Pipeline topology:
    ```text
         +-> [fn_stage] ---+
         +-> [t1] ---------+-> [fn_stage]
         +-> [t2] -> [t3] -+       |
                                   v
                         +---------+---------+
                         v                   v
                    +----+----+         [fn_stage] -> [t6]
                    v         v              |
                   [t4]      [t5]            |
                    |         |              |
                    +----+----+--------------+
                         v
                       (done)
    ```
    """
    comptime IS = immutable.SequentialTask
    comptime IP = immutable.ParallelTask
    comptime Fn = immutable.Fn

    def noop():
        sleep(TIME)

    var s1, e1, h1 = (0, 0, 0)
    var s2, e2, h2 = (0, 0, 0)
    var s3, e3, h3 = (0, 0, 0)
    var s4, e4, h4 = (0, 0, 0)
    var s5, e5, h5 = (0, 0, 0)
    var s6, e6, h6 = (0, 0, 0)

    var t1 = TimedImmutStep(s1, e1, h1)
    var t2 = TimedImmutStep(s2, e2, h2)
    var t3 = TimedImmutStep(s3, e3, h3)
    var t4 = TimedImmutStep(s4, e4, h4)
    var t5 = TimedImmutStep(s5, e5, h5)
    var t6 = TimedImmutStep(s6, e6, h6)
    var fn_stage = Fn(noop)

    var inner_seq = t2 >> t3
    var inner_par = IP(fn_stage, t1, inner_seq)
    var left_block = IS(inner_par, fn_stage)
    var right_par = IP(t4, t5)
    var right_seq = fn_stage >> t6
    var right_block = right_par + right_seq

    var combined = left_block >> right_block
    combined()

    assert_equal(h1, 1)
    assert_equal(h2, 1)
    assert_equal(h3, 1)
    assert_equal(h4, 1)
    assert_equal(h5, 1)
    assert_equal(h6, 1)
    assert_true(e2 <= s3)
    assert_true(e1 <= s4)
    assert_true(e3 <= s6)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
