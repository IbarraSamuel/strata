from strata.generic.compt_fn import Pipe, Parallel, Sequence
from std.testing import TestSuite, assert_equal


def test_generic_comptime_parallel() raises:
    def add_one(v: Int) -> Int:
        return v + 1

    def add_two(v: Int) -> Int:
        return v + 2

    def combine(v: Tuple[Int, Int]) -> Int:
        return v[0] + v[1]

    comptime workflow = Pipe.sequence[add_one].add[
        Pipe.parallel[add_one].add[add_two].handover
    ].add[combine]

    var result = workflow.run(4)
    # COMPTIME IS NOT POSSIBLE STILL BECAUSE OF TASK GROUP
    assert_equal(result, 13)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
