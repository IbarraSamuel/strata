from dataclasses import dataclass
from time import sleep

import pytest

from strata import (
    Combinable,
    GraphStats,
    SequentialExecutor,
    TracingExecutor,
    branch,
    fallback,
    graph_stats,
    group,
    identity,
    map_task,
    retry,
    select,
    spread,
    task,
    timeout,
    to_dot,
    to_mermaid,
    zip_tasks,
)

SLEEP_SHORT = 0.03


@task
def inc(x: int) -> int:
    return x + 1


@task
def double(x: int) -> int:
    return x * 2


@task
def to_str(x: int) -> str:
    return str(x)


@task
def str_len(s: str) -> int:
    return len(s)


@task
def slow_square(x: int) -> int:
    sleep(SLEEP_SHORT)
    return x * x


@spread
def add_pair(a: int, b: int) -> int:
    return a + b


@spread
def sum_triple(a: int, b: int, c: int) -> int:
    return a + b + c


def test_identity_select_and_spread():
    keep_and_double = identity() & double
    assert keep_and_double(7) == (7, 14)

    pick0 = keep_and_double | select(0)
    pick1 = keep_and_double | select(1)
    expected_zero = 7
    expected_one = 14
    assert pick0(7) == expected_zero
    assert pick1(7) == expected_one

    p2 = (inc & double) | add_pair
    expected_p2 = 16
    assert p2(5) == expected_p2

    p3 = (inc & double & identity()) | sum_triple
    expected_p3 = 21
    assert p3(5) == expected_p3


def test_zip_tasks_parallel_product():
    z = zip_tasks(double, str_len)
    assert z((6, "hello")) == (12, 5)

    composed = (inc & to_str) | zip_tasks(double, str_len) | add_pair
    expected_composed = 202
    # 99 -> (100, "99") -> (200, 2) -> 202
    assert composed(99) == expected_composed


def test_map_task_parallel_bounded_and_exceptions():
    mapper = map_task(slow_square)
    bounded = map_task(slow_square, max_concurrency=2)

    items = [1, 2, 3, 4, 5]
    assert mapper(items) == [1, 4, 9, 16, 25]
    assert bounded(items) == [1, 4, 9, 16, 25]
    assert mapper([]) == []
    assert mapper([7]) == [49]

    @task
    def fail_on_neg(x: int) -> int:
        if x < 0:
            msg = f"negative: {x}"
            raise ValueError(msg)
        return x * 2

    bad_mapper = map_task(fail_on_neg)
    with pytest.RaisesGroup(
        pytest.RaisesExc(ValueError, match="negative: -1"),
        pytest.RaisesExc(ValueError, match="negative: -2"),
    ):
        bad_mapper([1, -1, 2, -2])


def test_branch_routing():
    router = branch(lambda x: x % 2 == 0, double, inc)
    expected_even = 8
    expected_odd = 6
    assert router(4) == expected_even
    assert router(5) == expected_odd

    pipe = router | inc
    expected_pipe = 9
    assert pipe(4) == expected_pipe


@dataclass
class _FlakyTask(Combinable):
    fail_times: int
    calls: int = 0

    def __call__(self, x: int) -> int:
        self.calls += 1
        if self.calls <= self.fail_times:
            msg = f"boom #{self.calls}"
            raise RuntimeError(msg)
        return x * 10


def test_retry_fallback_and_timeout():
    flaky = _FlakyTask(fail_times=2)
    retried = retry(flaky, max_attempts=3, backoff=0.001)
    expected_ok = 70
    expected_calls = 3
    assert retried(7) == expected_ok
    assert flaky.calls == expected_calls

    always_flaky = _FlakyTask(fail_times=5)
    exhausted = retry(always_flaky, max_attempts=2)
    with pytest.raises(RuntimeError, match="boom #2"):
        exhausted(7)

    safe = fallback(exhausted, double)
    expected_fallback = 14
    assert safe(7) == expected_fallback

    @task
    def too_slow(x: int) -> int:
        sleep(0.15)
        return x

    guarded_ok = timeout(inc, seconds=1.0)
    expected_guarded = 42
    assert guarded_ok(41) == expected_guarded

    guarded_slow = timeout(too_slow, seconds=0.02)
    with pytest.raises(TimeoutError, match="timed out"):
        guarded_slow(1)


def test_introspection_mermaid_and_dot():
    diamond = inc | (double & (inc | double) & inc) | sum_triple

    assert diamond.stats() == GraphStats(
        stage_count=6,
        max_parallel_width=3,
        critical_depth=4,
    )
    assert graph_stats(diamond) == diamond.stats()

    mmd = diamond.to_mermaid()
    assert mmd.startswith("flowchart LR")
    assert "inc" in mmd
    assert "double" in mmd
    assert "spread(sum_triple)" in mmd
    assert "-->" in mmd

    dot = diamond.to_dot()
    assert dot.startswith("digraph Strata {")
    assert "->" in dot
    assert dot.endswith("}")

    grouped = group(inc & double) & inc
    assert "subgraph g0" in to_mermaid(grouped)
    assert "subgraph cluster_0" in to_dot(grouped)


def test_sequential_and_tracing_executors():
    @task
    def slow_inc(x: int) -> int:
        sleep(SLEEP_SHORT)
        return x + 1

    @task
    def slow_double(x: int) -> int:
        sleep(SLEEP_SHORT)
        return x * 2

    diamond = inc | (slow_inc & slow_double) | add_pair

    seq = SequentialExecutor()
    expected_res = 20
    # 6 -> 7 -> (8, 14) -> 22; for 5 -> 6 -> (7, 12) -> 19
    assert seq.run(diamond, 5) == 19  # ruff: ignore[magic-value-comparison]

    seq_tracer = TracingExecutor(sequential=True)
    assert seq_tracer.run(diamond, 5) == 19  # ruff: ignore[magic-value-comparison]
    expected_spans = 4
    assert len(seq_tracer.spans) == expected_spans
    assert seq_tracer.spans[1].end_ns <= seq_tracer.spans[2].start_ns
    assert seq_tracer.total_duration_ns() > 0
    assert "slow_inc" in seq_tracer.format_report()

    par_tracer = TracingExecutor(sequential=False)
    assert par_tracer.run(inc | (slow_inc & slow_double) | add_pair, 5) == 19  # ruff: ignore[magic-value-comparison]
    assert len(par_tracer.spans) == expected_spans
    # Verify concurrent execution overlap between slow_inc and slow_double
    by_name = {s.stage: s for s in par_tracer.spans}
    assert by_name["slow_inc"].end_ns > by_name["slow_double"].start_ns
    assert by_name["slow_double"].end_ns > by_name["slow_inc"].start_ns
    assert expected_res > 0

    par_tracer.clear()
    assert par_tracer.spans == []
