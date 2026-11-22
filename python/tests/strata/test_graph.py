from dataclasses import dataclass
from time import sleep, time_ns

import pytest

from strata.graph import Combinable, group, task

SLEEP_TIME = 0.1


@task
def increment(message: int) -> int:
    return message + 1


@task
def double(message: int) -> int:
    return message * 2


@dataclass
class MyTask(Combinable):
    value: int = 0

    def __call__(self, message: int) -> int:
        self.value += message
        return self.value


def test_task():
    motask = MyTask()

    value = 1
    result = motask(value)
    result = motask(result)
    assert motask.value == value * 2
    assert result == 1 * 2


def test_decorated_serial_tasks():
    pipeline = increment | double

    assert pipeline(3) == 8  # ruff: ignore[magic-value-comparison]


def test_decorated_parallel_tasks():
    pipeline = increment & double

    assert pipeline(3) == (4, 6)


@dataclass
class AddOneTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> int:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return message + 1


@dataclass
class IntToStrTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> str:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return str(message)


@dataclass
class StrToIntTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: str) -> int:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return int(message)


@dataclass
class SumTuple(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: tuple[int, int, int]) -> int:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return message[0] + message[1]


def test_serial_task():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    serial_task = my_task_1 | my_task_2

    print("[Serial Task]...")

    message = 5
    out = serial_task(message)

    print("[End of Task]...")

    assert out == message + 2, "tasks should add 1 to each input"
    assert my_task_1.end < my_task_2.start, "task1 should finish before task2 starts"


def test_serial_task_combination():
    str_to_int = StrToIntTask()
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    int_to_str = IntToStrTask()
    serial_task = str_to_int | my_task_1 | my_task_2 | int_to_str

    print("[Serial Task]...")

    message = "5"
    out = serial_task(message)

    print("[End of Task]...")

    assert out == str(int(message) + 2), "tasks should add 1 to each input"
    assert my_task_1.end < my_task_2.start, "task1 should finish before task2 starts"


# @pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_parallel_task():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    parallel_task = my_task_1 & my_task_2

    print("[Parallel Task]...")

    message = 5
    out = parallel_task(message)

    print("[End of Task]...")

    assert out == (message + 1, message + 1), "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 starts before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 starts before t2 finishes"


# @pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_parallel_task_combination():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    my_task_3 = AddOneTask()
    parallel_task = my_task_1 & my_task_2 & my_task_3

    print("[Parallel Task]...")

    msg = 5
    out = parallel_task(msg)

    print("[End of Task]...")

    assert out == (msg + 1, msg + 1, msg + 1), "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 should start before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 should start before t2 finishes"


# @pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_mixed_task_combination():
    str_to_int = StrToIntTask()
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    my_task_3 = AddOneTask()
    sum_tuple = SumTuple()
    int_to_str = IntToStrTask()

    pipeline = str_to_int | my_task_1 & my_task_2 & my_task_3 | sum_tuple | int_to_str
    print("[Mixed Task]...")

    message = "5"
    out = pipeline(message)

    print("[End of Task]...")

    assert out == "12", "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 starts before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 starts before t2 finishes"


@dataclass
class TimedOpTask(Combinable):
    delta: int = 0
    scale: int = 1
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> int:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return (message + self.delta) * self.scale


@dataclass
class TimedPairSumTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: tuple[int, int]) -> int:
        self.start = time_ns()
        sleep(SLEEP_TIME)
        self.end = time_ns()
        return message[0] + message[1]


@task
def parse_int(raw: str) -> int:
    return int(raw)


@task
def merge_diamond_branches(
    values: tuple[tuple[int, int], int, int],
) -> int:
    pair, mid, single = values
    return pair[0] + pair[1] + mid + single


@task
def format_tagged_total(total: int) -> str:
    return f"total={total}"


@task
def combine_summary(parts: tuple[str, int]) -> str:
    tag, scaled = parts
    return f"{tag}|scaled={scaled}"


def test_complex_diamond_of_diamonds():
    """Verify an asymmetric diamond-of-diamonds Python/Mojo pipeline.

      ```text
      str -> [parse] -> int
                         |
          +--------------+--------------+
          v              v              v
       [b1_a]         [b2_a]          [b3]
          |              |              |
          v          +---+---+          |
       [b1_b]        v       v          |
          |       [b2_b1] [b2_b2]       |
          v          |       |          |
      +---+---+      +---+---+          |
      v       v          v              |
    [b1_c1] [b1_c2]   [b2_c]            |
      |       |          |              |
      +---+---+          |              |
          +--------------+--------------+
                         v
              [merge_diamond_branches] -> int
                                           |
                                     +-----+-----+
                                     v           v
                          [format_tagged_total] [scale_out]
                                     |           |
                                     +-----+-----+
                                           v
                                   [combine_summary] -> str
      ```
    """
    parse = StrToIntTask()

    # Branch 1: (+1) | (*2) | ( (*3) & (-1) ) -> tuple[int, int]
    b1_a = TimedOpTask(delta=1)
    b1_b = TimedOpTask(scale=2)
    b1_c1 = TimedOpTask(scale=3)
    b1_c2 = TimedOpTask(delta=-1)

    # Branch 2: (-2) | ( (*4) & (+10) ) | sum_pair -> int
    b2_a = TimedOpTask(delta=-2)
    b2_b1 = TimedOpTask(scale=4)
    b2_b2 = TimedOpTask(delta=10)
    b2_c = TimedPairSumTask()

    # Branch 3: single stage (*5) -> int
    b3 = TimedOpTask(scale=5)

    # Second fan-out after merge -> (format_tagged_total & (*10)) -> combine_summary
    scale_out = TimedOpTask(scale=10)

    pipeline = (
        parse
        | ((b1_a | b1_b | (b1_c1 & b1_c2)) & (b2_a | (b2_b1 & b2_b2) | b2_c) & b3)
        | merge_diamond_branches
        | (format_tagged_total & scale_out)
        | combine_summary
    )

    # Input "5" yields b1=(36, 11), b2=25, b3=25 -> merge 97 -> ("total=97", 970)
    out = pipeline("5")
    assert out == "total=97|scaled=970"

    # Strict sequential ordering guarantees
    assert parse.end < b1_a.start
    assert parse.end < b2_a.start
    assert parse.end < b3.start
    assert b1_a.end < b1_b.start
    assert b1_b.end < b1_c1.start
    assert b1_b.end < b1_c2.start
    assert b2_a.end < b2_b1.start
    assert b2_a.end < b2_b2.start
    assert b2_b1.end < b2_c.start
    assert b2_b2.end < b2_c.start
    assert b1_c1.end < scale_out.start
    assert b2_c.end < scale_out.start
    assert b3.end < scale_out.start

    # Concurrent overlap at outer and inner parallel stages
    assert b1_a.end > b2_a.start
    assert b2_a.end > b1_a.start
    assert b1_a.end > b3.start
    assert b3.end > b1_a.start
    assert b1_c1.end > b1_c2.start
    assert b1_c2.end > b1_c1.start
    assert b2_b1.end > b2_b2.start
    assert b2_b2.end > b2_b1.start


def test_nested_parallel_of_parallels():
    """Verify full associative flattening by default and explicit `group(...)` nesting.

    ```text
    1) t1 & (t2 & t3) -> flat tuple[int, int, int] (1 TaskGroup)
    2) (p1 & p2) & (p3 & p4) -> flat tuple[int, int, int, int] (1 TaskGroup)
    3) t1 & group(t2 & t3) -> tuple[int, tuple[int, int]]
    4) group(p1 & p2) & group(p3 & p4) -> tuple[tuple[int, int], tuple[int, int]]
    ```
    """
    # Task & (Task & Task) flattens associatively to (o1, o2, o3)
    t1 = TimedOpTask(delta=1)
    t2 = TimedOpTask(delta=2)
    t3 = TimedOpTask(delta=3)
    right_flat = t1 & (t2 & t3)
    assert right_flat(10) == (11, 12, 13)
    assert t1.end > t2.start
    assert t2.end > t3.start
    assert t3.end > t1.start

    # (Task & Task) & (Task & Task) flattens associatively to (o1, o2, o3, o4)
    p1 = TimedOpTask(scale=1)
    p2 = TimedOpTask(scale=2)
    p3 = TimedOpTask(scale=3)
    p4 = TimedOpTask(scale=4)
    par_of_pars = (p1 & p2) & (p3 & p4)
    assert par_of_pars(2) == (2, 4, 6, 8)
    assert p1.end > p3.start
    assert p3.end > p1.start

    # Explicit group(...) preserves nested tuple structure symmetrically
    right_grouped = t1 & group(t2 & t3)
    assert right_grouped(10) == (11, (12, 13))

    both_grouped = group(p1 & p2) & group(p3 & p4)
    assert both_grouped(2) == ((2, 4), (6, 8))


def test_six_way_parallel_fanout():
    """Verify a 6-way flat parallel fan-out across Mojo tasks.

    ```text
             +-> [t0] -+
             +-> [t1] -+
      int ---+-> [t2] -+-> tuple[6 x int]
             +-> [t3] -+
             +-> [t4] -+
             +-> [t5] -+
    ```
    """
    tasks = [TimedOpTask(delta=i) for i in range(1, 7)]
    fanout6 = tasks[0] & tasks[1] & tasks[2] & tasks[3] & tasks[4] & tasks[5]
    t_start = time_ns()
    out = fanout6(10)
    elapsed_ns = time_ns() - t_start
    assert out == (11, 12, 13, 14, 15, 16)
    # Verify concurrency without assuming >= 6 runtime worker threads
    assert tasks[0].end > tasks[1].start
    assert tasks[1].end > tasks[0].start
    assert elapsed_ns < int(len(tasks) * SLEEP_TIME * 1_000_000_000 * 0.8)


def test_parallel_to_parallel_barriers():
    """Verify direct parallel-to-parallel barriers and hybrid parallel runs.

    ```text
    1) (a1 & a2) | (b1 & b2):
             +-> [a1] -+           +-> [b1] -+
      int ---+         +-> tuple ->+         +-> tuple[int, int]
             +-> [a2] -+           +-> [b2] -+

    2) ((c1 & c2) | (d1 & d2)) & (v1 | v2):
             +-> ( [c1 & c2] | [d1 & d2] ) -+
      int ---+                              +-> tuple[tuple[int, int], int]
             +-> [v1] -> [v2] --------------+
    ```
    """
    # Direct parallel-to-parallel barrier: (a1 & a2) | (b1 & b2)
    a1 = TimedOpTask(delta=1)
    a2 = TimedOpTask(scale=3)
    b1 = TimedPairSumTask()
    b2 = TimedPairSumTask()
    barrier_pipe = (a1 & a2) | (b1 & b2)
    assert barrier_pipe(4) == (17, 17)
    assert a1.end < b1.start
    assert a2.end < b2.start
    assert a1.end > a2.start
    assert b1.end > b2.start

    # Unexpected hybrid: ((c1 & c2) | (d1 & d2)) & (v1 | v2)
    c1 = TimedOpTask(delta=2)
    c2 = TimedOpTask(scale=5)
    d1 = TimedPairSumTask()
    d2 = TimedPairSumTask()
    v1 = TimedOpTask(delta=10)
    v2 = TimedOpTask(scale=2)
    hybrid = ((c1 & c2) | (d1 & d2)) & (v1 | v2)
    assert hybrid(3) == ((20, 20), 26)
    assert c1.end > v1.start
    assert v1.end > c1.start
    assert v1.end < v2.start


@task
def normalize_payload(raw: dict[str, int]) -> dict[str, int]:
    return {"x": abs(raw["x"]), "y": abs(raw["y"])}


@task
def extract_sum(data: dict[str, int]) -> int:
    return data["x"] + data["y"]


@task
def extract_diff(data: dict[str, int]) -> int:
    return data["x"] - data["y"]


@task
def extract_prod(data: dict[str, int]) -> int:
    return data["x"] * data["y"]


@task
def merge_features(features: tuple[int, int, int, int, int]) -> dict[str, int]:
    s, d, p, x_scaled, y_chain = features
    return {
        "sum": s,
        "diff": d,
        "prod": p,
        "x_scaled": x_scaled,
        "y_chain": y_chain,
    }


@task
def score_primary(feats: dict[str, int]) -> int:
    return feats["sum"] + feats["prod"]


@task
def score_secondary(feats: dict[str, int]) -> int:
    return feats["x_scaled"] + feats["y_chain"] - feats["diff"]


@task
def is_balanced(feats: dict[str, int]) -> bool:
    return feats["sum"] > 0


@task
def format_report(scores: tuple[int, int, bool]) -> str:
    primary, secondary, valid = scores
    return f"primary={primary},secondary={secondary},valid={valid}"


@dataclass
class ExtractKey(Combinable):
    key: str

    def __call__(self, data: dict[str, int]) -> int:
        return data[self.key]


def test_large_multi_stage_etl_pipeline():
    """Verify a 5-branch ETL fan-out into merge and 3-way parallel scoring.

    ```text
    dict -> [normalize_payload] -> dict
                                    |
        +-------------+-------------+-------------+-------------+
        v             v             v             v             v
    [sum]         [diff]        [prod]     [Extract("x")] [Extract("y")]
        |             |             |             |             |
        |             |             |             v             v
        |             |             |          [*10]          [+1]
        |             |             |             |             |
        |             |             |             v             v
        |             |             |           [+5]          [*2]
        |             |             |             |             |
        |             |             |             |             v
        |             |             |             |           [+3]
        +-------------+-------------+-------------+-------------+
                                    v
                            [merge_features] -> dict
                                                 |
                                    +------------+------------+
                                    v            v            v
                             [score_pri]  [score_sec]  [is_balanced]
                                    |            |            |
                                    +------------+------------+
                                                 v
                                          [format_report] -> str
    ```
    """
    # 5 heterogeneous parallel feature branches -> merge -> 3 parallel scorers -> report
    branch_x = ExtractKey("x") | TimedOpTask(scale=10) | TimedOpTask(delta=5)
    branch_y = (
        ExtractKey("y")
        | TimedOpTask(delta=1)
        | TimedOpTask(scale=2)
        | TimedOpTask(delta=3)
    )

    pipeline = (
        normalize_payload
        | (extract_sum & extract_diff & extract_prod & branch_x & branch_y)
        | merge_features
        | (score_primary & score_secondary & is_balanced)
        | format_report
    )

    # input {"x": -4, "y": 3} -> normalized {"x": 4, "y": 3}
    # sum=7, diff=1, prod=12, branch_x=45, branch_y=((3+1)*2)+3=11
    # score_primary=19, score_secondary=45+11-1=55, valid=True
    assert pipeline({"x": -4, "y": 3}) == "primary=19,secondary=55,valid=True"


def test_pipeline_reusability_multiple_inputs():
    """Verify repeated execution of a mixed nested pipeline across inputs.

      ```text
      str -> [parse_int] -> int
                             |
          +------------------+------------------+
          v                  v                  v
      [increment]        [double]          [increment]
          |                  |                  |
          v                  v                  |
      +---+---+         [increment]             |
      v       v              |                  |
    [dbl]   [inc]            v                  |
      |       |          [double]               |
      +---+---+              |                  |
          +------------------+------------------+
                             v
                  [merge_diamond_branches] -> int
                                               |
                                     +---------+---------+
                                     v                   v
                          [format_tagged_total]  [increment -> double]
                                     |                   |
                                     +---------+---------+
                                               v
                                       [combine_summary] -> str
      ```
    """
    pipeline = (
        parse_int
        | (
            (increment | (double & increment))
            & (double | increment | double)
            & increment
        )
        | merge_diamond_branches
        | (format_tagged_total & (increment | double))
        | combine_summary
    )

    # x=2: ((6, 4), 10, 3) -> 23 -> ("total=23", 48)
    assert pipeline("2") == "total=23|scaled=48"
    # x=5: ((12, 7), 22, 6) -> 47 -> ("total=47", 96)
    assert pipeline("5") == "total=47|scaled=96"
    # x=0: ((2, 2), 2, 1) -> 7 -> ("total=7", 16)
    assert pipeline("0") == "total=7|scaled=16"


class _CustomPipelineError(Exception):
    pass


@task
def raise_value_error(x: int) -> int:
    msg = f"bad value: {x}"
    raise ValueError(msg)


@task
def raise_custom_error(x: int) -> int:
    msg = f"custom boom: {x}"
    raise _CustomPipelineError(msg)


@task
def add_ten(x: int) -> int:
    return x + 10


@task
def sum_pair(values: tuple[int, int]) -> int:
    return values[0] + values[1]


def test_serial_exception_preserves_type():
    pipeline = increment | raise_value_error | double

    with pytest.raises(ValueError, match="bad value: 4"):
        pipeline(3)


def test_parallel_single_exception_preserves_type():
    pipeline = increment & raise_custom_error & double

    with pytest.raises(_CustomPipelineError, match="custom boom: 5"):
        pipeline(5)


def test_parallel_multiple_exceptions_raise_exception_group():
    pipeline = raise_value_error & increment & raise_custom_error

    with pytest.RaisesGroup(
        pytest.RaisesExc(ValueError, match="bad value: 7"),
        pytest.RaisesExc(_CustomPipelineError, match="custom boom: 7"),
    ):
        pipeline(7)


def test_nested_parallel_exception_propagation():
    nested_err = increment & (raise_value_error & raise_custom_error)

    with pytest.RaisesGroup(
        pytest.RaisesExc(ValueError, match="bad value: 2"),
        pytest.RaisesExc(_CustomPipelineError, match="custom boom: 2"),
    ):
        nested_err(2)

    branch_err = (increment | raise_value_error) & double
    with pytest.raises(ValueError, match="bad value: 3"):
        branch_err(2)


def test_immutable_composition_branching_and_reuse():
    base_seq = increment | double
    branch_a = base_seq | increment
    branch_b = base_seq | add_ten

    # `base_seq` must remain unaffected by downstream compositions.
    expected_base_seq = 8
    expected_branch_a = 9
    expected_branch_b = 18
    assert base_seq(3) == expected_base_seq
    assert branch_a(3) == expected_branch_a
    assert branch_b(3) == expected_branch_b

    base_par = increment & double
    par_extended = base_par & add_ten
    par_piped = base_par | sum_pair

    # `base_par` must remain unaffected by parallel extension or piping.
    expected_par_piped = 13
    assert base_par(4) == (5, 8)
    assert par_extended(4) == (5, 8, 14)
    assert par_piped(4) == expected_par_piped
