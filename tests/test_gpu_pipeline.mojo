"""Tests for Mojo GPU device-resident pipeline execution (requires optional `max` dependency)."""

from std.sys import has_accelerator
from std.testing import TestSuite, assert_equal
from layout import ImmTileTensor, MutTileTensor, TileTensor, row_major
from max.gpu import global_idx
from max.gpu.host import DeviceBuffer, DeviceContext
from strata.pipeline.fallible import ComposableFallibleStage

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
