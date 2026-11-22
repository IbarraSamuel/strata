"""Tests for compile-time graph metadata and Mermaid/DOT visualization."""

from std.testing import TestSuite, assert_equal, assert_true

from strata.pipeline.compt import F, group


def _parse(x: Int) -> Int:
    return x + 1


def _branch_a(x: Int) -> Int:
    return x * 2


def _branch_b(x: Int) -> Int:
    return x * 3


def _branch_c(x: Int) -> Int:
    return x + 10


def _merge3(t: Tuple[Int, Int, Int]) -> Int:
    return t[0] + t[1] + t[2]


def _merge_nested(t: Tuple[Tuple[Int, Int], Int]) -> Int:
    return t[0][0] + t[0][1] + t[1]


def test_static_graph_metadata() raises:
    comptime diamond = (
        F[_parse]
        | (F[_branch_a] & (F[_branch_b] | F[_branch_c]) & F[_branch_c])
        | F[_merge3]
    )

    # 1 (_parse) + 1 (_branch_a) + 2 (_branch_b | _branch_c) + 1 (_branch_c) + 1 (_merge3) = 6
    comptime stages = diamond.STAGE_COUNT
    # Max simultaneous width: 3 parallel branches
    comptime width = diamond.MAX_PARALLEL_WIDTH
    # Critical depth: _parse (1) + max(1, 2, 1) (2) + _merge3 (1) = 4
    comptime depth = diamond.CRITICAL_DEPTH

    assert_equal(stages, 6)
    assert_equal(width, 3)
    assert_equal(depth, 4)


def test_mermaid_and_dot_rendering() raises:
    comptime diamond = (
        F[_parse] | (F[_branch_a] & F[_branch_b] & F[_branch_c]) | F[_merge3]
    )

    var mmd = diamond.to_mermaid()
    assert_true(mmd.startswith("flowchart LR"))
    assert_true("_parse" in mmd)
    assert_true("_branch_a" in mmd)
    assert_true("_branch_b" in mmd)
    assert_true("_branch_c" in mmd)
    assert_true("_merge3" in mmd)
    assert_true("-->" in mmd)

    var dot = diamond.to_dot()
    assert_true(dot.startswith("digraph Strata {"))
    assert_true("_parse" in dot)
    assert_true("_merge3" in dot)
    assert_true("->" in dot)
    assert_true(dot.endswith("}"))


def test_grouped_subgraph_rendering() raises:
    comptime grouped = (
        group(F[_branch_a] & F[_branch_b]) & F[_branch_c]
    ) | F[_merge_nested]

    comptime stages = grouped.STAGE_COUNT
    comptime width = grouped.MAX_PARALLEL_WIDTH
    assert_equal(stages, 4)
    assert_equal(width, 3)

    var mmd = grouped.to_mermaid()
    assert_true("subgraph g0" in mmd)
    assert_true("end" in mmd)

    var dot = grouped.to_dot()
    assert_true("subgraph cluster_0" in dot)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
