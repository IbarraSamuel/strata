"""Tests for async immutable void task pipelines."""

from std.testing import TestSuite
from std.time import sleep

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
