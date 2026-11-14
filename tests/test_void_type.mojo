"""Tests for type-level void task pipelines."""

from std.testing import TestSuite, assert_true
from std.time import monotonic, sleep

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


def test_type_complex_nested_workflows() raises:
    """Verify nested type-level SeriesTypeTask/ParallelTypeTask and operators.

    Pipeline topologies:
    ```text
    1) NestedTypesGraph:
       [Init] -> [Validate]
                    |
         +----------+----------+----------+
         v                     v          v
       [B1A] -> [B1B]        [B2A]       [B3]
         |                     |          |
         |                +----+----+     |
         |                v         v     |
         |             [B2B1]    [B2B2]   |
         |                |         |     |
         |                +----+----+     |
         |                     v          |
         |                   [B2C]        |
         |                     |          |
         +---------------------+----------+
                               v
             +-----+-----+-----+-----+-----+
             v     v     v     v     v     v
           [P1]  [P2]  [P3]  [P4]  [P5]  [P6]
             |     |     |     |     |     |
             +-----+-----+-----+-----+-----+
                               v
                          [Finalize]

    2) OperatorGraph (same head/mid, mixed tail):
       ... -> (PD[P1, P2, P3] + (P4 >> P5) + P6) -> [Finalize]
    ```
    """
    comptime SD = type.SeriesTypeTask
    comptime PD = type.ParallelTypeTask

    comptime Init = MyTypeTask["Init"]
    comptime Validate = MyTypeTask["Validate"]
    comptime B1A = MyTypeTask["B1A"]
    comptime B1B = MyTypeTask["B1B"]
    comptime B2A = MyTypeTask["B2A"]
    comptime B2B1 = MyTypeTask["B2B1"]
    comptime B2B2 = MyTypeTask["B2B2"]
    comptime B2C = MyTypeTask["B2C"]
    comptime B3 = MyTypeTask["B3"]
    comptime P1 = MyTypeTask["P1"]
    comptime P2 = MyTypeTask["P2"]
    comptime P3 = MyTypeTask["P3"]
    comptime P4 = MyTypeTask["P4"]
    comptime P5 = MyTypeTask["P5"]
    comptime P6 = MyTypeTask["P6"]
    comptime Finalize = MyTypeTask["Finalize"]

    # Deep nested comptime SeriesTypeTask / ParallelTypeTask tree
    comptime NestedTypesGraph = SD[
        Init,
        Validate,
        PD[
            SD[B1A, B1B],
            SD[B2A, PD[B2B1, B2B2], B2C],
            B3,
        ],
        PD[P1, P2, P3, P4, P5, P6],
        Finalize,
    ]
    var t0 = monotonic()
    NestedTypesGraph.__call__()
    var t1 = monotonic()
    assert_true(t1 > t0)

    # Complex operator-composed tree mixing SeriesTypeTask/ParallelTypeTask with >> and +
    comptime OperatorGraph = (
        (Init() >> Validate())
        >> ((B1A() >> B1B()) + (B2A() >> (B2B1() + B2B2()) >> B2C()) + B3())
        >> (PD[P1, P2, P3]() + (P4() >> P5()) + P6())
        >> Finalize()
    )
    var t2 = monotonic()
    OperatorGraph.__call__()
    var t3 = monotonic()
    assert_true(t3 > t2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
