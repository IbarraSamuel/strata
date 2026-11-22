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
- Python classes can also implement the `NativeCapsuleProvider` protocol (`def as_native_capsule(self) -> object`) so `native_stage(obj)` extracts the capsule automatically.

### GPU-Backed Custom Stage Example (Advanced)

`export_value_stage_capsule` can also drive accelerator APIs (`max.gpu`) and report device or type errors via a non-zero status code instead of returning a sentinel float.

> **Note:** The v1 capsule ABI passes scalar `NativeValue`s (`Int64`, `Float64`, `Bool`), not tensors. The example below launches a 1-element GPU kernel purely to illustrate end-to-end `DeviceContext` + status-code integration; real GPU workloads should amortize launch/transfer overhead over batched buffers and store persistent device resources in the capsule's `ctx` pointer.

Requires an environment with `max` GPU support, a supported GPU, and Strata's Mojo package on `-I`:

```mojo
from std.memory import OpaquePointer
from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder

from layout import ImmTileTensor, MutTileTensor, TileTensor, row_major
from max.gpu import global_idx
from max.gpu.host import DeviceContext
from strata.interop.native_abi import (
    NATIVE_VAL_FLOAT64,
    NativeValue,
    export_value_stage_capsule,
)

comptime count = 1
comptime layout = row_major[count]()

def double_one(
    input: ImmTileTensor[DType.float32, type_of(layout), ImmUntrackedOrigin],
    output: MutTileTensor[DType.float32, type_of(layout), MutUntrackedOrigin],
):
    comptime assert input.flat_rank == 1 and output.flat_rank == 1
    var idx = global_idx.x
    if idx < count:
        output[idx] = input[idx] * 2

def gpu_double(
    input: Pointer[NativeValue, ImmUntrackedOrigin],
    output: Pointer[NativeValue, MutUntrackedOrigin],
    _ctx: Optional[OpaquePointer[MutUntrackedOrigin]],
) abi("C") -> Int32:
    if input[].kind != NATIVE_VAL_FLOAT64:
        return 2

    try:
        var ctx = DeviceContext()
        var host_input = ctx.enqueue_create_host_buffer[DType.float32](count)
        var host_output = ctx.enqueue_create_host_buffer[DType.float32](count)
        ctx.synchronize()
        host_input[0] = Float32(input[].float_val)

        var device_input = ctx.enqueue_create_buffer[DType.float32](count)
        var device_output = ctx.enqueue_create_buffer[DType.float32](count)
        ctx.enqueue_copy(dst_buf=device_input, src_buf=host_input)

        var input_tensor = TileTensor(device_input, layout)
        var output_tensor = TileTensor(device_output, layout)
        ctx.enqueue_function[double_one](
            input_tensor.as_imm(),
            output_tensor,
            grid_dim=1,
            block_dim=1,
        )
        ctx.enqueue_copy(dst_buf=host_output, src_buf=device_output)
        ctx.synchronize()

        output[] = NativeValue.from_float(Float64(host_output[0]))
        return 0
    except:
        return 1

def make_gpu_double_stage() raises -> PythonObject:
    return export_value_stage_capsule(gpu_double)

@export
def PyInit_gpu_stage() abi("C") -> PythonObject:
    try:
        var module = PythonModuleBuilder("gpu_stage")
        module.def_function[make_gpu_double_stage](
            "make_gpu_double_stage",
            "Create a GPU-backed float-doubling stage.",
        )
        return module.finalize()
    except e:
        abort(String("error creating gpu_stage module:", e))
```

Build and call from Python:

```bash
mojo build -I /path/to/strata/package gpu_stage.mojo --emit shared-lib -o gpu_stage.so
```

```python
from gpu_stage import make_gpu_double_stage
from strata import native_stage

double_on_gpu = native_stage(make_gpu_double_stage(), name="gpu_double")
assert double_on_gpu(3.5) == 7.0
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
