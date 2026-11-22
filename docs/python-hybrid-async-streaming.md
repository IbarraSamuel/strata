# Python Guide: Hybrid GIL-Free Mojo Stages, `async def`, and Streaming

Strata's Python package (`strata`) lets you compose synchronous functions, `async def` coroutines, and GIL-free native Mojo stages using `|`, `&`, and `group(...)`, with static typing (PEP 695/646), immutable graphs, PEP 654 exception groups, and bounded-backpressure streaming.

---

## 1. Core Composition, Immutability & Error Propagation

### Unified Operators (`|`, `&`, `group`)

```python
from strata import group, spread, task

@task
def parse_int(raw: str) -> int:
    return int(raw)

@task
def double(x: int) -> int:
    return x * 2

@task
def add_ten(x: int) -> int:
    return x + 10

@spread
def summarize(a: int, b: int) -> str:
    return f"double={a}, plus10={b}"

# Directly callable, immutable graph
pipeline = parse_int | (double & add_ten) | summarize
assert pipeline("5") == "double=10, plus10=15"

# Associative parallel flattening:
flat = (double & add_ten) & (double & add_ten)
assert flat(5) == (10, 15, 10, 15)

# Explicit nested tuples via group(...):
nested = group(double & add_ten) & group(double & add_ten)
assert nested(5) == ((10, 15), (10, 15))
```

### Immutability & Sub-Pipeline Reuse

Composing with `|` or `&` never mutates existing stages or pipelines, so a base pipeline can safely branch into multiple derived graphs:

```python
base = parse_int | double
branch_a = base | add_ten
branch_b = base & (parse_int | add_ten)

assert base("5") == 10
assert branch_a("5") == 20
assert branch_b("5") == (10, 15)
```

### Exception Propagation (PEP 654)

- **Sequential (`|`)**: Short-circuits on the first failure and re-raises the original exception type, message, and traceback.
- **Parallel (`&`)**:
  - If **one** branch fails, that exact exception is re-raised directly.
  - If **multiple** branches fail, Strata raises a PEP 654 `ExceptionGroup` (or `BaseExceptionGroup` if any branch raised a non-`Exception` `BaseException`), catchable with `except*`:

```python
try:
    (failing_a & failing_b)(42)
except* ValueError as eg:
    print("ValueErrors:", eg.exceptions)
except* KeyError as eg:
    print("KeyErrors:", eg.exceptions)
```

---

## 2. Hybrid GIL-Free Mojo + Python Pipelines

On standard GIL-enabled CPython, pure Python CPU-bound functions contend on the GIL when run across threads. Strata provides **`NativeTask`** stages that execute **completely without the GIL** across CPU cores, fuse consecutive native stages across `|` into a single native pass, and accelerate batch `.map(...)` / `map_task(...)` calls automatically. (See [DESIGN.md](../DESIGN.md) for plan fusion and C-ABI internals.)

### Built-In GIL-Free Mojo Stages

```python
from strata import (
    native_cpu_work,
    native_float_linear,
    native_float_poly,
    native_int_linear,
    spread,
    task,
)

# Each constructor returns a ready-to-compose native Mojo stage:
scale = native_int_linear(scale=3, bias=1, name="mul3_add1")      # int -> int
shift = native_int_linear(scale=2, bias=-4, name="mul2_sub4")     # int -> int
to_f  = native_float_linear(scale=0.5, bias=1.25, name="to_flt")  # float|int -> float
poly  = native_float_poly(c0=1.0, c1=2.0, c2=3.0, name="quad")    # c2*x^2 + c1*x + c0
heavy = native_cpu_work(iterations=2_000_000, name="hash_mix")    # deterministic CPU mix

# "|" chains consecutive native stages in a single GIL-free pass (5 -> 16 -> 28 -> 15.25):
fused = scale | shift | to_f
assert fused(5) == 15.25

# "&" runs native chains and ordinary Python tasks in the same graph:
@task
def py_tag(x: int) -> str:
    return f"id:{x}"

@spread
def join(a: int, label: str, hashed: int) -> str:
    return f"{label} -> linear={a}, hash={hashed}"

hybrid = ((scale | shift) & py_tag & heavy) | join
print(hybrid(5))
```

Here `fused(5)` computes `3*5 + 1 = 16`, `2*16 - 4 = 28`, and `0.5*28 + 1.25 = 15.25` with automatic `int -> float` widening, while `hybrid` mixes a fused native chain, a Python `@task`, and `native_cpu_work` in parallel before unpacking all three outputs into `join`.

### Writing Custom GIL-Free Mojo Stages (`strata.native_stage.v1`)

When you need custom native logic beyond the built-in stages, a Mojo extension module can export a `"strata.native_stage.v1"` `PyCapsule` using `strata.interop.native_abi`. Because callbacks run without the GIL across worker threads, they must be thread-safe and must not touch Python objects.

Create `my_mojo_ext.mojo`:

```mojo
from std.memory import OpaquePointer
from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder
from strata.interop.native_abi import export_float_stage_capsule

def fast_sigmoid_approx(
    x: Float64, _ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
) abi("C") -> Float64:
    return x / (1.0 + abs(x))

def make_my_stage() raises -> PythonObject:
    # Optional `ctx` and `ctx_deleter` manage custom heap state across the capsule's lifetime
    return export_float_stage_capsule(
        fast_sigmoid_approx, ctx=None, ctx_deleter=None
    )

@export
def PyInit_my_mojo_ext() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("my_mojo_ext")
        module.def_function[make_my_stage](
            "make_my_stage",
            "Create a GIL-free fast sigmoid approximation stage.",
        )
        return module.finalize()
    except e:
        abort(String("error creating my_mojo_ext:", e))
```

Build the shared library (including Strata's precompiled `package/` directory on `-I` if building outside a Pixi workspace where `strata` is installed):

```bash
mojo build -I /path/to/strata/package my_mojo_ext.mojo --emit shared-lib -o my_mojo_ext.so
```

Then wrap the capsule in Python with `native_stage`:

```python
import my_mojo_ext
from strata import native_stage

my_stage = native_stage(my_mojo_ext.make_my_stage(), name="fast_sigmoid")
pipe = my_stage & my_stage
print(pipe(1.0))  # (0.5, 0.5)
```

- Use `export_int_stage_capsule` for `Int64 -> Int64` callbacks.
- Use `export_float_stage_capsule` for `Float64 -> Float64` callbacks.
- Use `export_value_stage_capsule` for tagged `NativeValue -> NativeValue` callbacks (`Int64`, `Float64`, `Bool`) that return `0` on success or a non-zero status code to raise an exception in Python.
- Use `export_arrow_float_stage_capsule` and `export_arrow_int_stage_capsule` for columnar `(in_ptr, out_ptr, length, ctx) -> status` callbacks over Arrow-compatible data.
- Python classes can also implement the `NativeCapsuleProvider` protocol (`def as_native_capsule(self) -> object`) so `native_stage(obj)` extracts the capsule automatically.

### Arrow Columnar Data & GPU Execution (`ArrowArray`, `gpu_arrow_*`, `export_arrow_*`)

For high-throughput columnar and GPU workloads, Strata supports **Arrow-like data** via the Apache Arrow C Data Interface PyCapsule protocol (`__arrow_c_array__`):

- **Inputs accepted**: `strata.ArrowArray`, `pyarrow.Array`, `polars.Series`, `nanoarrow`, any object implementing `__arrow_c_array__()`, or 1D Python numeric sequences (`list`, `tuple`, `array.array`, `memoryview`).
- **Outputs returned**: `strata.ArrowArray` (backed by a contiguous Mojo buffer), which implements `__arrow_c_array__()`, `.to_list()`, `.to_pyarrow()`, `.dtype` (`"float64"` or `"int64"`), `.nbytes`, `.data_ptr()`, indexing, and slicing.
- **Built-in GPU & CPU Arrow stages**:
  - `gpu_arrow_float_linear(scale, bias)` / `native_arrow_float_linear(scale, bias, use_gpu=False)`
  - `gpu_arrow_float_poly(c0, c1, c2)` / `native_arrow_float_poly(c0, c1, c2, use_gpu=False)`
  - `gpu_arrow_int_linear(scale, bias)` / `native_arrow_int_linear(scale, bias, use_gpu=False)`
  - Consecutive GPU float stages chained with `|` (`gpu_arrow_float_linear(...) | gpu_arrow_float_poly(...)`) automatically fuse on a single `DeviceContext` using ping-pong `DeviceBuffer`s — uploading to the GPU once and downloading back to host once.

```python
from strata import (
    ArrowArray,
    gpu_arrow_float_linear,
    gpu_arrow_float_poly,
    has_gpu,
)

print("GPU accelerator available:", has_gpu())

col = ArrowArray([1.0, 2.0, 3.0, 4.0])
pipe = gpu_arrow_float_linear(scale=2.0, bias=1.0) | gpu_arrow_float_poly(
    c0=1.0, c1=2.0, c2=3.0
)
out = pipe(col)
assert out == [34.0, 86.0, 162.0, 262.0]

# Export zero-copy Arrow C Data Interface PyCapsules ("arrow_schema", "arrow_array"):
schema_cap, array_cap = out.__arrow_c_array__()
```

#### Exporting a Custom GPU Arrow Stage (`export_arrow_float_stage_capsule`)

External Mojo extensions can process an entire Arrow column on the GPU in a single kernel launch using `export_arrow_float_stage_capsule`:

```mojo
from std.math import ceildiv
from std.memory import OpaquePointer
from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder
from max.gpu import global_idx
from max.gpu.host import DeviceContext
from strata.interop.native_abi import export_arrow_float_stage_capsule

comptime BLOCK_SIZE = 256

def gpu_double_kernel(
    inp: Pointer[Float32, ImmUntrackedOrigin],
    output: Pointer[Float32, MutUntrackedOrigin],
    n: Int64,
):
    var tid = global_idx.x
    if tid < Int(n):
        output[unsafe_offset=tid] = inp[unsafe_offset=tid] * 2.0

def gpu_double_arrow(
    in_ptr: Pointer[Float64, ImmUntrackedOrigin],
    out_ptr: Pointer[Float64, MutUntrackedOrigin],
    length: Int64,
    _ctx: Optional[OpaquePointer[MutUntrackedOrigin]],
) abi("C") -> Int32:
    var n = Int(length)
    if n <= 0:
        return 0
    try:
        var ctx = DeviceContext()
        var d_in = ctx.enqueue_create_buffer[DType.float32](n)
        var d_out = ctx.enqueue_create_buffer[DType.float32](n)
        with d_in.map_to_host() as h_in:
            for i in range(n):
                h_in[i] = Float32(in_ptr[unsafe_offset=i])
        ctx.enqueue_function[gpu_double_kernel](
            d_in,
            d_out,
            length,
            grid_dim=ceildiv(n, BLOCK_SIZE),
            block_dim=BLOCK_SIZE,
        )
        with d_out.map_to_host() as h_out:
            for i in range(n):
                out_ptr[unsafe_offset=i] = Float64(h_out[i])
        return 0
    except:
        return 1

def make_gpu_double_arrow_stage() raises -> PythonObject:
    return export_arrow_float_stage_capsule(gpu_double_arrow)

@export
def PyInit_gpu_arrow_stage() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("gpu_arrow_stage")
        module.def_function[make_gpu_double_arrow_stage](
            "make_gpu_double_arrow_stage",
            "Create a GPU-backed Arrow float64 doubling stage.",
        )
        return module.finalize()
    except e:
        abort(String("error creating gpu_arrow_stage module:", e))
```

---

## 3. Python `async def` Tasks & Free-Threaded Python

### `@async_task` and `await pipeline.arun(x)`

Wrap `async def` functions with `@async_task` to compose them alongside sync `@task` and `NativeTask` stages:

```python
import asyncio
from strata import arun, async_task, native_int_linear, task

@async_task
async def fetch_a(x: int) -> int:
    await asyncio.sleep(0.01)
    return x + 1

@async_task
async def fetch_b(x: int) -> int:
    await asyncio.sleep(0.01)
    return x * 10

@task
def combine(pair: tuple[int, int]) -> int:
    return pair[0] + pair[1]

double_native = native_int_linear(scale=2, bias=0, name="double")
pipeline = (fetch_a & fetch_b) | combine | double_native

# Option A: Call synchronously (works even if an event loop is already running)
print(pipeline(5))  # 112

# Option B: Await natively on an active asyncio event loop
async def main() -> None:
    res = await pipeline.arun(5)  # or: await arun(pipeline, 5)
    print(res)  # 112

asyncio.run(main())
```

Inside `arun(...)`, `@async_task` stages are awaited directly on your event loop while synchronous and native stages are automatically offloaded to worker threads so they never block the loop.

### Free-Threaded Python (`3.13t+`) & Runtime Diagnostics

Inspect active interpreter and native capabilities with `is_gil_enabled()` and `runtime_info()`:

```python
from strata import is_gil_enabled, runtime_info

print(runtime_info())
# RuntimeInfo(python_version='3.15.2', gil_enabled=True, native_gil_free=True, cpu_count=8)
```

On free-threaded CPython builds (`gil_enabled=False`), even pure-Python `&` branches run across cores simultaneously; on GIL-enabled builds (`gil_enabled=True`), `NativeTask` stages still achieve full multi-core parallelism.

---

## 4. Batch & Sliding-Window Streaming

Every stage (`Combinable`) and composed pipeline exposes `.map(...)`, `.stream(...)`, and `.astream(...)` (also available as standalone `map_stage`, `stream_stage`, `astream_stage`):

### Eager Concurrent Batch (`pipeline.map`)

```python
results = pipeline.map(range(100), max_in_flight=8)
```

- Always returns results in input order.
- `max_in_flight=0` (default) picks a CPU-scaled concurrency limit (`min(32, cpu_count + 4)`); negative values raise `ValueError`.

### Lazy Sliding-Window Streaming (`pipeline.stream`)

```python
# Ordered streaming with O(max_in_flight) backpressure (safe on infinite generators)
for result in pipeline.stream(infinite_generator(), max_in_flight=4, ordered=True):
    process(result)
    if done():
        break  # cancels pending work and closes upstream generator cleanly

# Unordered completion-order streaming for lower tail latency
for result in pipeline.stream(items, max_in_flight=8, ordered=False):
    process(result)
```

- Requires `max_in_flight >= 1` (`max_in_flight=1` runs sequentially without spawning threads).
- Pulls at most `max_in_flight` items ahead of active/buffered work and yields ready outputs before pulling the next upstream item.

### Asynchronous Streaming (`pipeline.astream`)

Accepts either a synchronous `Iterable[I]` or an `AsyncIterable[I]`:

```python
async def source():
    for i in range(50):
        await asyncio.sleep(0.001)
        yield i

async def main() -> None:
    async for out in pipeline.astream(source(), max_in_flight=6, ordered=True):
        print(out)
```

---

## Input Validation & Error Guarantees

- **Native numeric validation**:
  - `bool` (`True` / `False`) is rejected with `TypeError` by integer and float native stages and constructors.
  - `native_int_linear` checks 64-bit bounds on inputs and intermediate arithmetic, raising `OverflowError` on overflow rather than wrapping silently.
  - `native_float_linear` and `native_float_poly` accept Python `int` or `float` inputs and preserve IEEE-754 `NaN`, `+inf`, and `-inf`.
  - Chaining `native_int_linear | native_float_linear` widens `int -> float` automatically; narrowing `native_float_linear | native_int_linear` raises `TypeError`.
  - `native_cpu_work(iterations=...)` clamps `iterations <= 0` to `0` and returns a deterministic non-negative 63-bit integer.
- **Stream cleanup**: Breaking out of `stream` or `astream` early (or raising mid-stream) closes upstream sync/async generators and cancels pending work cleanly without leaked tasks or warnings.
