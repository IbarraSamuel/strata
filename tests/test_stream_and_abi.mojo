"""Tests for Mojo bounded-memory stream_map and native interop ABI structs."""

from std.sys import has_accelerator
from layout import ImmTileTensor, MutTileTensor, TileTensor, row_major
from max.gpu import global_idx
from max.gpu.host import DeviceBuffer, DeviceContext
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
from strata.pipeline.fallible import ComposableFallibleStage
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


comptime _GPU_N = 8
comptime _gpu_layout = row_major[_GPU_N]()


struct _GpuKernels:
    @staticmethod
    def scale_bias(
        inp: ImmTileTensor[
            DType.float32, type_of(_gpu_layout), ImmUntrackedOrigin
        ],
        output: MutTileTensor[
            DType.float32, type_of(_gpu_layout), MutUntrackedOrigin
        ],
        scale: Float32,
        bias: Float32,
    ):
        comptime assert inp.flat_rank == 1 and output.flat_rank == 1
        var tid = global_idx.x
        if tid < _GPU_N:
            output[tid] = inp[tid] * scale + bias


struct _ToDeviceStage(ComposableFallibleStage):
    comptime I = List[Float32]
    comptime O = DeviceBuffer[DType.float32]
    var ctx: DeviceContext[]

    def __init__(out self, ctx: DeviceContext[]):
        self.ctx = ctx

    def __call__(self, arg: List[Float32]) raises -> DeviceBuffer[DType.float32]:
        var buf = self.ctx.enqueue_create_buffer[DType.float32](_GPU_N)
        with buf.map_to_host() as host:
            for i in range(_GPU_N):
                host[i] = arg[i]
        return buf^


struct _GpuLinearStage(ComposableFallibleStage):
    comptime I = DeviceBuffer[DType.float32]
    comptime O = DeviceBuffer[DType.float32]
    var ctx: DeviceContext[]
    var scale: Float32
    var bias: Float32

    def __init__(out self, ctx: DeviceContext[], scale: Float32, bias: Float32):
        self.ctx = ctx
        self.scale = scale
        self.bias = bias

    def __call__(
        self, arg: DeviceBuffer[DType.float32]
    ) raises -> DeviceBuffer[DType.float32]:
        var out_buf = self.ctx.enqueue_create_buffer[DType.float32](_GPU_N)
        var t_in = TileTensor(arg, _gpu_layout)
        var t_out = TileTensor(out_buf, _gpu_layout)
        self.ctx.enqueue_function[_GpuKernels.scale_bias](
            t_in.as_imm(),
            t_out,
            self.scale,
            self.bias,
            grid_dim=1,
            block_dim=_GPU_N,
        )
        return out_buf^


struct _ToHostStage(ComposableFallibleStage):
    comptime I = DeviceBuffer[DType.float32]
    comptime O = List[Float32]

    def __init__(out self):
        pass

    def __call__(
        self, arg: DeviceBuffer[DType.float32]
    ) raises -> List[Float32]:
        var res = List[Float32](length=_GPU_N, fill=0.0)
        with arg.map_to_host() as h:
            for i in range(_GPU_N):
                res[i] = h[i]
        return res^


def test_mojo_gpu_pipeline_execution() raises:
    comptime if has_accelerator():
        var ctx = DeviceContext()
        var upload = _ToDeviceStage(ctx)
        var step1 = _GpuLinearStage(ctx, 2.0, 1.0)
        var step2 = _GpuLinearStage(ctx, 3.0, -1.0)
        var download = _ToHostStage()

        var pipe = upload | step1 | step2 | download
        var inp: List[Float32] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        var out = pipe(inp)
        assert_equal(len(out), _GPU_N)
        for i in range(_GPU_N):
            var x = Float32(i + 1)
            assert_equal(out[i], 3.0 * (2.0 * x + 1.0) - 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
