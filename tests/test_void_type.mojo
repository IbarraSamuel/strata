"""Tests for type-level void task pipelines."""

from std.testing import TestSuite
from std.time import sleep

from strata.void import type

comptime TIME = 0.001


@fieldwise_init
struct MyTypeTask[name: StringLiteral](
    type.TypeCallable, TrivialRegisterPassable
):
    @staticmethod
    def __call__():
        sleep(TIME)


def test_type_examples() raises:
    comptime SD = type.SeriesTypeTask
    comptime PD = type.ParallelTypeTask

    comptime Initialize = MyTypeTask["Initialize"]
    comptime LoadData = MyTypeTask["LoadData"]
    comptime FindMin = MyTypeTask["FindMin"]
    comptime FindMax = MyTypeTask["FindMax"]
    comptime FindMean = MyTypeTask["FindMean"]
    comptime FindMedian = MyTypeTask["FindMedian"]
    comptime MergeResults = MyTypeTask["MergeResults"]

    comptime TypesGraph = SD[
        Initialize,
        LoadData,
        PD[FindMin, FindMax, FindMean, FindMedian],
        MergeResults,
    ]
    TypesGraph.__call__()

    # Airflow Syntax
    comptime airflow_graph = (
        Initialize()
        >> LoadData()
        >> FindMin() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    airflow_graph.__call__()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
