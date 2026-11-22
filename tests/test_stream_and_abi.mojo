"""Tests for Mojo bounded-memory stream_map and native interop ABI structs."""

from strata.interop.native_abi import (
    ARROW_ARRAY_CAPSULE_NAME,
    ARROW_SCHEMA_CAPSULE_NAME,
    NATIVE_KIND_ARROW_FLOAT64,
    NATIVE_KIND_ARROW_INT64,
    NATIVE_KIND_FLOAT64,
    NATIVE_KIND_INT64,
    NATIVE_STAGE_CAPSULE_NAME,
    NATIVE_VAL_BOOL,
    NATIVE_VAL_FLOAT64,
    NATIVE_VAL_INT64,
    ArrowCArray,
    ArrowCSchema,
    NativeStageDescriptor,
    NativeValue,
)
from strata.pipeline import Fn
from strata.pipeline.combinators import OutputSink, stream_map
from std.testing import TestSuite, assert_equal, assert_true


def double_int(x: Int) -> Int:
    return x * 2


def add_ten(x: Int) -> Int:
    return x + 10


struct ListSink(OutputSink):
    comptime Item = Int
    var collected: List[Int]

    def __init__(out self):
        self.collected = List[Int]()

    def on_item(mut self, var item: Int):
        self.collected.append(item)


def test_stream_map_preserves_order_with_window() raises:
    var s1 = Fn(double_int)
    var s2 = Fn(add_ten)
    var pipe = s1 | s2

    var items = List[Int]()
    for i in range(15):
        items.append(i)

    var sink = ListSink()
    stream_map(pipe, items, max_in_flight=4, sink=sink)

    assert_equal(len(sink.collected), 15)
    for i in range(15):
        assert_equal(sink.collected[i], i * 2 + 10)


def test_stream_map_sequential_and_empty() raises:
    var s1 = Fn(double_int)
    var empty = List[Int]()
    var sink_empty = ListSink()
    stream_map(s1, empty, max_in_flight=4, sink=sink_empty)
    assert_equal(len(sink_empty.collected), 0)

    var items: List[Int] = [1, 2, 3, 4]
    var sink_seq = ListSink()
    stream_map(s1, items, max_in_flight=1, sink=sink_seq)
    assert_equal(len(sink_seq.collected), 4)
    assert_equal(sink_seq.collected[0], 2)
    assert_equal(sink_seq.collected[3], 8)


def test_native_abi_value_and_descriptor() raises:
    var vi = NativeValue.from_int(42)
    assert_equal(vi.kind, NATIVE_VAL_INT64)
    assert_equal(vi.int_val, 42)

    var vf = NativeValue.from_float(3.5)
    assert_equal(vf.kind, NATIVE_VAL_FLOAT64)
    assert_equal(vf.float_val, 3.5)

    var vb = NativeValue.from_bool(True)
    assert_equal(vb.kind, NATIVE_VAL_BOOL)
    assert_equal(vb.int_val, 1)

    var d = NativeStageDescriptor()
    assert_equal(d.kind, NATIVE_KIND_INT64)
    assert_true(not d.ctx_deleter)
    assert_true(NATIVE_KIND_FLOAT64 != NATIVE_KIND_INT64)
    assert_true(NATIVE_KIND_ARROW_FLOAT64 != NATIVE_KIND_ARROW_INT64)
    assert_equal(String(NATIVE_STAGE_CAPSULE_NAME), "strata.native_stage.v1")
    assert_equal(String(ARROW_SCHEMA_CAPSULE_NAME), "arrow_schema")
    assert_equal(String(ARROW_ARRAY_CAPSULE_NAME), "arrow_array")

    var schema = ArrowCSchema()
    assert_equal(schema.flags, 0)
    assert_true(not schema.release)

    var arr = ArrowCArray()
    assert_equal(arr.length, 0)
    assert_equal(arr.null_count, 0)
    assert_true(not arr.release)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
