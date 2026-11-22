"""MAX GPU-accelerated Python interoperability extension entrypoint for `mojo_strata`."""

from std.math import ceildiv
from std.python import PythonObject
from std.sys import has_accelerator
from std.sys.info import CompilationTarget
from max.gpu import global_idx
from max.gpu.host import DeviceContext
from src.interop.python_interop import (
    _GPU_BLOCK_SIZE,
    _NATIVE_STATUS_OVERFLOW,
    _NativeOp,
    _OP_ARROW_FLOAT_LINEAR,
    _init_mojo_strata_module,
    _register_gpu_backend,
)


def _gpu_arrow_f32_linear_kernel(
    inp: Pointer[Float32, ImmUntrackedOrigin],
    output: Pointer[Float32, MutUntrackedOrigin],
    scale: Float32,
    bias: Float32,
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        output[unsafe_offset=tid] = inp[unsafe_offset=tid] * scale + bias


def _gpu_arrow_f32_poly_kernel(
    inp: Pointer[Float32, ImmUntrackedOrigin],
    output: Pointer[Float32, MutUntrackedOrigin],
    c0: Float32,
    c1: Float32,
    c2: Float32,
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        var x = inp[unsafe_offset=tid]
        output[unsafe_offset=tid] = (c2 * x + c1) * x + c0


def _gpu_arrow_f64_linear_kernel(
    inp: Pointer[Float64, ImmUntrackedOrigin],
    output: Pointer[Float64, MutUntrackedOrigin],
    scale: Float64,
    bias: Float64,
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        output[unsafe_offset=tid] = inp[unsafe_offset=tid] * scale + bias


def _gpu_arrow_f64_poly_kernel(
    inp: Pointer[Float64, ImmUntrackedOrigin],
    output: Pointer[Float64, MutUntrackedOrigin],
    c0: Float64,
    c1: Float64,
    c2: Float64,
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        var x = inp[unsafe_offset=tid]
        output[unsafe_offset=tid] = (c2 * x + c1) * x + c0


def _gpu_arrow_i64_linear_kernel(
    inp: Pointer[Int64, ImmUntrackedOrigin],
    output: Pointer[Int64, MutUntrackedOrigin],
    scale: Int64,
    bias: Int64,
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        output[unsafe_offset=tid] = inp[unsafe_offset=tid] * scale + bias


def _run_gpu_arrow_float_chain(
    ops_base: Pointer[_NativeOp, ImmUntrackedOrigin],
    run_start: Int,
    run_end: Int,
    data_ptr: Pointer[List[Float64], MutUntrackedOrigin],
) abi("C") -> Int32:
    """Execute one or more consecutive GPU float stages on a single `DeviceContext`."""
    var n = len(data_ptr[])
    if n == 0:
        return 0
    try:
        comptime if has_accelerator():
            var ctx = DeviceContext()
            var grid = ceildiv(n, _GPU_BLOCK_SIZE)
            comptime if CompilationTarget.is_macos():
                var d_a = ctx.enqueue_create_buffer[DType.float32](n)
                var d_b = ctx.enqueue_create_buffer[DType.float32](n)
                with d_a.map_to_host() as h_in:
                    for i in range(n):
                        h_in[i] = Float32(data_ptr[][i])
                var in_is_a = True
                for step in range(run_start, run_end):
                    var step_op = ops_base[unsafe_offset=step]
                    if step_op.op_kind == _OP_ARROW_FLOAT_LINEAR:
                        if in_is_a:
                            ctx.enqueue_function[_gpu_arrow_f32_linear_kernel](
                                d_a,
                                d_b,
                                Float32(step_op.f_p0),
                                Float32(step_op.f_p1),
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                        else:
                            ctx.enqueue_function[_gpu_arrow_f32_linear_kernel](
                                d_b,
                                d_a,
                                Float32(step_op.f_p0),
                                Float32(step_op.f_p1),
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                    else:
                        if in_is_a:
                            ctx.enqueue_function[_gpu_arrow_f32_poly_kernel](
                                d_a,
                                d_b,
                                Float32(step_op.f_p0),
                                Float32(step_op.f_p1),
                                Float32(step_op.f_p2),
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                        else:
                            ctx.enqueue_function[_gpu_arrow_f32_poly_kernel](
                                d_b,
                                d_a,
                                Float32(step_op.f_p0),
                                Float32(step_op.f_p1),
                                Float32(step_op.f_p2),
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                    in_is_a = not in_is_a
                if in_is_a:
                    with d_a.map_to_host() as h_out:
                        for i in range(n):
                            data_ptr[][i] = Float64(h_out[i])
                else:
                    with d_b.map_to_host() as h_out:
                        for i in range(n):
                            data_ptr[][i] = Float64(h_out[i])
            else:
                var d_a = ctx.enqueue_create_buffer[DType.float64](n)
                var d_b = ctx.enqueue_create_buffer[DType.float64](n)
                with d_a.map_to_host() as h_in:
                    for i in range(n):
                        h_in[i] = data_ptr[][i]
                var in_is_a = True
                for step in range(run_start, run_end):
                    var step_op = ops_base[unsafe_offset=step]
                    if step_op.op_kind == _OP_ARROW_FLOAT_LINEAR:
                        if in_is_a:
                            ctx.enqueue_function[_gpu_arrow_f64_linear_kernel](
                                d_a,
                                d_b,
                                step_op.f_p0,
                                step_op.f_p1,
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                        else:
                            ctx.enqueue_function[_gpu_arrow_f64_linear_kernel](
                                d_b,
                                d_a,
                                step_op.f_p0,
                                step_op.f_p1,
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                    else:
                        if in_is_a:
                            ctx.enqueue_function[_gpu_arrow_f64_poly_kernel](
                                d_a,
                                d_b,
                                step_op.f_p0,
                                step_op.f_p1,
                                step_op.f_p2,
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                        else:
                            ctx.enqueue_function[_gpu_arrow_f64_poly_kernel](
                                d_b,
                                d_a,
                                step_op.f_p0,
                                step_op.f_p1,
                                step_op.f_p2,
                                Int64(n),
                                grid_dim=grid,
                                block_dim=_GPU_BLOCK_SIZE,
                            )
                    in_is_a = not in_is_a
                if in_is_a:
                    with d_a.map_to_host() as h_out:
                        for i in range(n):
                            data_ptr[][i] = h_out[i]
                else:
                    with d_b.map_to_host() as h_out:
                        for i in range(n):
                            data_ptr[][i] = h_out[i]
            return 0
    except:
        return 1
    return -1


def _run_gpu_arrow_int_linear(
    scale: Int64,
    bias: Int64,
    data_ptr: Pointer[List[Int64], MutUntrackedOrigin],
) abi("C") -> Int32:
    """Execute an `Int64` linear stage on the GPU after checked overflow validation."""
    var n = len(data_ptr[])
    for i in range(n):
        var acc = Int128(scale) * Int128(data_ptr[][i]) + Int128(bias)
        if acc < Int128(Int64.MIN) or acc > Int128(Int64.MAX):
            return _NATIVE_STATUS_OVERFLOW
    if n == 0:
        return 0
    try:
        comptime if has_accelerator():
            var ctx = DeviceContext()
            var d_in = ctx.enqueue_create_buffer[DType.int64](n)
            var d_out = ctx.enqueue_create_buffer[DType.int64](n)
            with d_in.map_to_host() as h_in:
                for i in range(n):
                    h_in[i] = data_ptr[][i]
            ctx.enqueue_function[_gpu_arrow_i64_linear_kernel](
                d_in,
                d_out,
                scale,
                bias,
                Int64(n),
                grid_dim=ceildiv(n, _GPU_BLOCK_SIZE),
                block_dim=_GPU_BLOCK_SIZE,
            )
            with d_out.map_to_host() as h_out:
                for i in range(n):
                    data_ptr[][i] = h_out[i]
            return 0
    except:
        return 1
    return -1


def _run_gpu_arrow_float_linear_buf(
    in_ptr: Pointer[Float64, ImmUntrackedOrigin],
    out_ptr: Pointer[Float64, MutUntrackedOrigin],
    n: Int,
    scale: Float64,
    bias: Float64,
) abi("C") -> Int32:
    """Execute a pointer-to-pointer `Float64` linear stage on the GPU."""
    if n <= 0:
        return 0
    try:
        comptime if has_accelerator():
            var dev_ctx = DeviceContext()
            var grid = ceildiv(n, _GPU_BLOCK_SIZE)
            comptime if CompilationTarget.is_macos():
                var d_in = dev_ctx.enqueue_create_buffer[DType.float32](n)
                var d_out = dev_ctx.enqueue_create_buffer[DType.float32](n)
                with d_in.map_to_host() as h_in:
                    for i in range(n):
                        h_in[i] = Float32(in_ptr[unsafe_offset=i])
                dev_ctx.enqueue_function[_gpu_arrow_f32_linear_kernel](
                    d_in,
                    d_out,
                    Float32(scale),
                    Float32(bias),
                    Int64(n),
                    grid_dim=grid,
                    block_dim=_GPU_BLOCK_SIZE,
                )
                with d_out.map_to_host() as h_out:
                    for i in range(n):
                        out_ptr[unsafe_offset=i] = Float64(h_out[i])
            else:
                var d_in = dev_ctx.enqueue_create_buffer[DType.float64](n)
                var d_out = dev_ctx.enqueue_create_buffer[DType.float64](n)
                with d_in.map_to_host() as h_in:
                    for i in range(n):
                        h_in[i] = in_ptr[unsafe_offset=i]
                dev_ctx.enqueue_function[_gpu_arrow_f64_linear_kernel](
                    d_in,
                    d_out,
                    scale,
                    bias,
                    Int64(n),
                    grid_dim=grid,
                    block_dim=_GPU_BLOCK_SIZE,
                )
                with d_out.map_to_host() as h_out:
                    for i in range(n):
                        out_ptr[unsafe_offset=i] = h_out[i]
            return 0
    except:
        return 1
    return -1


@export
def PyInit_mojo_strata() abi("C") -> PythonObject:
    """Initialize the CPython extension module for `mojo_strata` with MAX GPU acceleration.

    Returns:
        The initialized Python module object.
    """
    _register_gpu_backend(
        has_accelerator(),
        _run_gpu_arrow_float_chain,
        _run_gpu_arrow_int_linear,
        _run_gpu_arrow_float_linear_buf,
    )
    return _init_mojo_strata_module()
