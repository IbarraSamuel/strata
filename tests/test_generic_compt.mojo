"""Tests for generic comptime pipeline runners."""

from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata.generic.compt import F

comptime TIME = 0.001


def test_generic_comptime_parallel() raises:
    def comptime_parallel(v: NoneType) -> Tuple[Int, Int]:
        var start = monotonic()
        sleep(TIME)
        var end = monotonic()
        return start, end

    comptime _graph = (
        F[comptime_parallel] & F[comptime_parallel] & F[comptime_parallel]
    )

    var p1, p2, p3 = _graph.run(None)

    assert_true(p1[0] < p1[1])
    assert_true(p1[0] < p2[1])
    assert_true(p1[0] < p3[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p2[1])
    assert_true(p3[0] < p2[1])
    assert_true(p3[0] < p3[1])
    assert_true(p3[0] < p3[1])


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def int_to_int(v: Int) -> Int:
    return v


def sum_tuple(v: Tuple[Float32, Int]) -> Int:
    return Int(v[0] + Float32(v[1]))


def test_generic_comptime_two_parallels() raises:
    comptime graph = (
        (F[int_to_float] & F[int_to_int]) | (F[sum_tuple] & F[sum_tuple])
    )

    var r1, r2 = graph.run(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


def string_to_int(str: String) -> Int:
    sleep(TIME)
    try:
        return Int(str)
    except:
        return 0


def int_mul[by: Int](value: Int) -> Int:
    sleep(TIME)
    return value * by


def sum_tuple_g(value: Tuple[Int, Float32, Int]) -> Float32:
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


struct FloatToString:
    @staticmethod
    def call(value: Float32) -> String:
        sleep(TIME)
        return String(value)


def sum_tuple3(value: Tuple[Int, Float32, Int]) -> Float32:
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


def test_generic_comptime_examples() raises:
    comptime final_g = (
        F[string_to_int]
        | F[int_mul[2]] & F[int_to_float] & F[int_mul[3]]
        | F[sum_tuple3]
        | F[FloatToString.call]
    )

    var final_result_f = final_g.F("32")
    assert_equal(final_result_f, "192.0")


def test_generic_comptime_explicit() raises:
    def stoi(v: String) -> Int:
        try:
            return Int(v)
        except:
            return 0

    def int_m[q: Int](v: Int) -> Int:
        return q * v

    def itof(v: Int) -> Float32:
        return Float32(v)

    def sumtp(v: Tuple[Int, Float32, Int]) -> Float32:
        return Float32(v[0]) + v[1] + Float32(v[2])

    def ftos(v: Float32) -> String:
        return String(v)

    comptime explicit_graph = (
        F[stoi] | F[int_m[2]] & F[itof] & F[int_m[3]] | F[sumtp] | F[ftos]
    )

    var s_runt_result = explicit_graph.run("32")
    assert_equal(s_runt_result, "192.0")


def double_it(x: Int) -> Int:
    return x * 2


def triple_it(x: Int) -> Int:
    return x * 3


def test_comptime_run() raises:
    # Test F runtime and comptime_run
    comptime single_f = F[double_it]
    # Check at runtime
    assert_equal(single_f.run(5), 10)
    # Check comptime_run:
    comptime compt_res = single_f.comptime_run[5]
    assert_equal(compt_res, 10)

    # Test FG runtime and comptime_run
    comptime par_fg = F[double_it] & F[triple_it]
    # NOTE: change to comptime_run -> asyncrt cannot run at comptime:w
    var res_pair = par_fg.F(4)
    assert_equal(res_pair[0], 8)
    assert_equal(res_pair[1], 12)
    # Check comptime_run (causes miscompilation at comptime due to TaskGroup asyncrt external call):
    # comptime par_compt_res = par_fg.comptime_run[4]
    # assert_equal(par_compt_res[0], 8)
    # assert_equal(par_compt_res[1], 12)


@fieldwise_init
struct Input:
    var val: Int
    var string: String

    def __init__(out self, v: Int):
        self.val = v
        self.string = "*" * v


def test_complex_workflow() raises:
    """Verify a compile-time symmetric two-branch diamond pipeline.

    Pipeline topology:
    ```text
    Int -> [generate_input] -> Input
                                 |
        +------------------------+------------------------+
        v                                                 v
    [extract_numeric] -> [multiply_value[2]] -> [cast_to_float]
                                 |                        |
        [extract_text] -> [check_length] -> [pow2]        |
        |                                     |           |
        +-------------------------------------+-----------+
                                 v
                        [calculate_result] -> Float64
    ```
    """

    def generate_input(seed: Int) -> Input:
        return Input(seed)

    def extract_numeric(v: Input) -> Int:
        return v.val

    def multiply_value[V: Int](v: Int) -> Int:
        return v * V

    def cast_to_float(v: Int) -> Float64:
        return Float64(v)

    def extract_text(v: Input) -> String:
        return v.string

    def check_length(v: String) -> Int:
        return v.byte_length()

    def pow2(v: Int) -> Int:
        return v**2

    def calculate_result(v: Tuple[Float64, Int]) -> Float64:
        return v[0] + Float64(v[1])

    comptime complex = (
        F[generate_input]
        | (
            (F[extract_numeric] | F[multiply_value[2]] | F[cast_to_float])
            & (F[extract_text] | F[check_length] | F[pow2])
        )
        | F[calculate_result]
    )

    var result = complex.run(3)
    assert_equal(result, 15.0)


@fieldwise_init
struct Record(Copyable, Movable):
    var label: String
    var base: Int
    var weight: Float64


def test_heavy_multi_stage_pipeline() raises:
    """Verify a multi-stage comptime pipeline with Record/String and 4 branches.

      Pipeline topology:
      ```text
      String -> [make_record] -> Record
                                   |
          +------------+-----------+-------------+-------------+
          v            v                         v             v
      [get_base]  [get_label]               [get_weight]  [get_base]
          |            |                         |             |
          v            v                         v             v
      [add_n[2]]  [shout_label]            [scale_weight]  [add_n[1]]
          |            |                         |             |
          v            v                         |             v
      +---+---+    +---+---+                     |         [mul_n[4]]
      v       v    v       v                     |             |
    [mul3]  [sq] [len] [shout]                   |             v
      |       |    |       |                     |         [add_n[3]]
      +---+---+    +---+---+                     |             |
          v            v                         |             |
    [combine_pair] [summarize_b2]                |             |
          |            |                         |             |
          +------------+-------------------------+-------------+
                                   v
                             [merge_four] -> Record
                                               |
                                      +--------+--------+
                                      v                 v
                                 [tag_total]      [half_weight]
                                      |                 |
                                      +--------+--------+
                                               v
                                         [final_format] -> String
      ```
    """

    def make_record(raw: String) -> Record:
        try:
            var n = Int(raw)
            return Record(
                label=String("item-", n), base=n, weight=Float64(n) * 1.5
            )
        except:
            return Record(label="item-0", base=0, weight=0.0)

    def get_base(r: Record) -> Int:
        return r.base

    def get_label(r: Record) -> String:
        return r.label.copy()

    def get_weight(r: Record) -> Float64:
        return r.weight

    def add_n[n: Int](v: Int) -> Int:
        return v + n

    def mul_n[n: Int](v: Int) -> Int:
        return v * n

    def square_i(v: Int) -> Int:
        return v * v

    def combine_pair(v: Tuple[Int, Int]) -> Int:
        return v[0] + v[1]

    def str_len(s: String) -> Int:
        return s.byte_length()

    def shout_label(s: String) -> String:
        return String(s, "!")

    def summarize_branch2(v: Tuple[Int, String]) -> String:
        return String(v[1], ":", v[0])

    def scale_weight(w: Float64) -> Float64:
        return w * 2.0 + 0.5

    def merge_four(v: Tuple[Int, String, Float64, Int]) -> Record:
        var total = v[0] + Int(v[2]) + v[3]
        return Record(label=v[1].copy(), base=total, weight=v[2])

    def tag_total(r: Record) -> String:
        return String(r.label, "|total=", r.base)

    def half_weight(r: Record) -> Float64:
        return r.weight / 2.0

    def final_format(v: Tuple[String, Float64]) -> String:
        return String(v[0], "|w=", v[1])

    # Branch 1: base -> +2 -> (mul3 & square) -> sum
    comptime b1 = F[get_base] | F[add_n[2]] | (F[mul_n[3]] & F[square_i]) | F[
        combine_pair
    ]
    # Branch 2: label -> shout -> (str_len & shout) -> summarize
    comptime b2 = F[get_label] | F[shout_label] | (
        F[str_len] & F[shout_label]
    ) | F[summarize_branch2]
    # Branch 3: weight -> scale_weight
    comptime b3 = F[get_weight] | F[scale_weight]
    # Branch 4: chained Sequence | Sequence (4 sequential steps)
    comptime b4 = (F[get_base] | F[add_n[1]]) | (F[mul_n[4]] | F[add_n[3]])

    comptime heavy = (
        F[make_record]
        | (b1 & b2 & b3 & b4)
        | F[merge_four]
        | (F[tag_total] & F[half_weight])
        | F[final_format]
    )

    # For input "4":
    # Record("item-4", 4, 6.0)
    # b1: 4 -> 6 -> (18, 36) -> 54
    # b2: "item-4" -> "item-4!" -> (7, "item-4!!") -> "item-4!!:7"
    # b3: 6.0 -> 12.5
    # b4: 4 -> 5 -> 20 -> 23
    # merge_four: total = 54 + 12 + 23 = 89, label = "item-4!!:7", weight = 12.5
    # final: "item-4!!:7|total=89|w=6.25"
    assert_equal(heavy.run("4"), "item-4!!:7|total=89|w=6.25")
    assert_equal(heavy.run("0"), "item-0!!:7|total=17|w=0.25")


def test_unexpected_parallel_compositions() raises:
    """Verify unexpected comptime Sequence/Parallel operator combinations.

    Pipeline topologies:
    ```text
    1) (Parallel & Parallel) -> Reducer:
       Int -> ((+1 & *2) & (+3 & *4)) -> Tuple[Int, Int, Tuple[Int, Int]] -> [sum_nested_par]

    2) Parallel | Parallel barrier:
       Int -> (*3 & +2) -> Tuple[Int, Int] -> ([sum2] & [diff2]) -> Tuple[Int, Int]

    3) Function | Sequence  &  Sequence | Sequence:
       Int -> +1 | (*2 | +3)
       Int -> (+1 | *2) | (+3 | *5)

    4) Function & Sequence  &  Sequence & Sequence:
       Int -> (*2) & (+1 | *3)
       Int -> (+1 | *2) & (*3 | +4)

    5) 6-way fan-out -> Reducer:
       Int -> (*1 & *2 & *3 & *4 & *5 & *6) -> [sum6]

    6) 6-stage pure sequence (comptime_run & runtime run):
       Int -> +1 -> *2 -> +5 -> *3 -> -3 -> [to_str] -> String
    ```
    """

    def add_k[k: Int](x: Int) -> Int:
        return x + k

    def mul_k[k: Int](x: Int) -> Int:
        return x * k

    def sum2(v: Tuple[Int, Int]) -> Int:
        return v[0] + v[1]

    def diff2(v: Tuple[Int, Int]) -> Int:
        return v[0] - v[1]

    def sum_nested_par(v: Tuple[Int, Int, Tuple[Int, Int]]) -> Int:
        return v[0] + v[1] + v[2][0] + v[2][1]

    def sum6(v: Tuple[Int, Int, Int, Int, Int, Int]) -> Int:
        return v[0] + v[1] + v[2] + v[3] + v[4] + v[5]

    def to_str(x: Int) -> String:
        return String("res=", x)

    # 1. Parallel & Parallel -> nested tuple
    comptime p_of_p = (F[add_k[1]] & F[mul_k[2]]) & (F[add_k[3]] & F[mul_k[4]])
    comptime p_of_p_red = p_of_p | F[sum_nested_par]
    # x=5 -> (6, 10, (8, 20)) -> 44
    assert_equal(p_of_p_red.run(5), 44)

    # 2. Parallel directly piped into Parallel: (a & b) | (c & d)
    comptime par_to_par = (F[mul_k[3]] & F[add_k[2]]) | (F[sum2] & F[diff2])
    var p2p_a, p2p_b = par_to_par.run(4)
    # (12, 6) -> (18, 6)
    assert_equal(p2p_a, 18)
    assert_equal(p2p_b, 6)

    # 3. Function | Sequence and Sequence | Sequence
    comptime fn_pipe_seq = F[add_k[1]] | (F[mul_k[2]] | F[add_k[3]])
    comptime seq_pipe_seq = (F[add_k[1]] | F[mul_k[2]]) | (
        F[add_k[3]] | F[mul_k[5]]
    )
    assert_equal(fn_pipe_seq.run(4), 13)
    assert_equal(seq_pipe_seq.run(4), 65)

    # 4. Function & Sequence and Sequence & Sequence
    comptime fn_and_seq = F[mul_k[2]] & (F[add_k[1]] | F[mul_k[3]])
    var fas_a, fas_b = fn_and_seq.run(5)
    assert_equal(fas_a, 10)
    assert_equal(fas_b, 18)

    comptime seq_and_seq = (F[add_k[1]] | F[mul_k[2]]) & (
        F[mul_k[3]] | F[add_k[4]]
    )
    var sas_a, sas_b = seq_and_seq.run(5)
    assert_equal(sas_a, 12)
    assert_equal(sas_b, 19)

    # 5. 6-way parallel fan-out -> reducer
    comptime fanout6 = (
        F[mul_k[1]]
        & F[mul_k[2]]
        & F[mul_k[3]]
        & F[mul_k[4]]
        & F[mul_k[5]]
        & F[mul_k[6]]
    ) | F[sum6]
    # 2 * (1+2+3+4+5+6) = 42
    assert_equal(fanout6.run(2), 42)

    # 6. Deep 6-stage pure sequence evaluated at comptime AND runtime
    comptime deep_seq = (
        F[add_k[1]]
        | F[mul_k[2]]
        | F[add_k[5]]
        | F[mul_k[3]]
        | F[add_k[-3]]
        | F[to_str]
    )
    comptime ct_val = deep_seq.comptime_run[4]
    assert_equal(ct_val, "res=42")
    assert_equal(deep_seq.run(4), "res=42")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
