# Python Guide: Hybrid GIL-Free Mojo Stages, `async def`, and Streaming

Strata's Python package (`strata`) runs task graphs on Mojo's native `TaskGroup` (`mojo_strata.so`) with strict PEP 695/646 static typing, immutable composition, exact exception propagation, GIL-free native Mojo kernels, native `asyncio` support, and bounded-backpressure streaming.

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

### Copy-on-Write Immutability

Composing with `|` or `&` never mutates existing task groups, so base pipelines can safely branch into multiple derived graphs:

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
  - If **multiple** branches fail, Strata raises a PEP 654 `ExceptionGroup` (or `BaseExceptionGroup` if any branch raised a `BaseException` subclass), catchable with `except*`:

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

On standard GIL-enabled CPython, pure Python CPU-bound callables contend on the GIL when run across threads. Strata solves this with **`NativeTask`** and the **`strata.native_stage.v1` `PyCapsule` C-ABI**:

1. **Zero-GIL Parallel Execution**: Parallel `NativeTask` branches (and pure-native serial chains like `(n1 | n2) & py_stage & n3`) unbox input once on the main thread, run **100% GIL-free** across CPU cores on Mojo's `asyncrt` thread pool, and re-box outputs after `tg.wait()`.
2. **Automatic Serial Chain Fusion**: Consecutive native stages (`n1 | n2 | n3`) fuse into a **single `GILReleased` pass**, passing unboxed `NativeValue`s directly in Mojo registers with zero intermediate Python boxing (including automatic `int -> float` promotion).

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

# Built-in GIL-free Mojo kernels
scale = native_int_linear(scale=3, bias=1, name="mul3_add1")      # int -> int
shift = native_int_linear(scale=2, bias=-4, name="mul2_sub4")     # int -> int
to_f  = native_float_linear(scale=0.5, bias=1.25, name="to_flt")  # float|int -> float
poly  = native_float_poly(c0=1.0, c1=2.0, c2=3.0, name="quad")    # c2*x^2 + c1*x + c0
heavy = native_cpu_work(iterations=2_000_000, name="hash_mix")    # deterministic CPU mix

# Fused GIL-free serial chain (single GILReleased block, int -> int -> float)
fused = scale | shift | to_f
assert fused(5) == 15.25

# Hybrid parallel diamond mixing native chains, Python tasks, and single native stages
@task
def py_tag(x: int) -> str:
    return f"id:{x}"

@spread
def join(a: int, label: str, hashed: int) -> str:
    return f"{label} -> linear={a}, hash={hashed}"

hybrid = ((scale | shift) & py_tag & heavy) | join
print(hybrid(5))
```

### Exporting Custom GIL-Free Mojo Stages via `strata.native_stage.v1` PyCapsules

External Mojo extensions (or C/Rust shared libraries) can export their own GIL-free stages using `strata.interop.native_abi`:

**In your Mojo extension module:**
```mojo
from std.memory import OpaquePointer
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder
from strata.interop.native_abi import export_float_stage_capsule

def fast_sigmoid_approx(
    x: Float64, _ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
) abi("C") -> Float64:
    return x / (1.0 + abs(x))

def make_my_stage() raises -> PythonObject:
    return export_float_stage_capsule(fast_sigmoid_approx)
```

**In Python:**
```python
from strata import native_stage

# Wrap any "strata.native_stage.v1" PyCapsule (or an object with `as_native_capsule()`)
my_stage = native_stage(my_mojo_ext.make_my_stage(), name="fast_sigmoid")

# Composes directly with | and & and runs 100% GIL-free
pipe = (my_stage & my_stage)
```

You can also implement the `NativeCapsuleProvider` protocol (`def as_native_capsule(self) -> object`) on any Python class so `native_stage(obj)` extracts its capsule automatically.

---

## 3. Python `async def` Tasks & Free-Threaded Python Support

### `@async_task` and `await pipeline.arun(x)`

Wrap `async def` functions with `@async_task` to compose them seamlessly alongside sync `@task` and GIL-free `NativeTask` stages:

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

# Option A: Call synchronously (runs each branch concurrently via Mojo TaskGroup)
print(pipeline(5))  # 112

# Option B: Await natively on an active asyncio event loop
async def main() -> None:
    res = await pipeline.arun(5)  # or: await arun(pipeline, 5)
    print(res)  # 112

asyncio.run(main())
```

How `arun` executes each stage type:
- `AsyncTask`: awaited directly on the caller's event loop (cooperative concurrency, zero thread overhead).
- Sync `@task` and `NativeTask`: offloaded via `asyncio.to_thread(...)` so blocking or compute-heavy work never stalls the event loop.
- Combinators (`group`, `zip_tasks`, `map_task`, `branch`, `retry`, `fallback`, `timeout`): handled natively with `asyncio.Semaphore`, `asyncio.sleep`, and `asyncio.wait_for`.

### Free-Threaded Python (`3.13t` / `3.14t` / `3.15t`) & Runtime Info

Inspect active interpreter and native capabilities with `is_gil_enabled()` and `runtime_info()`:

```python
from strata import is_gil_enabled, runtime_info

info = runtime_info()
print(info)
# RuntimeInfo(python_version='3.15.2', gil_enabled=True, native_gil_free=True, cpu_count=8)
```

On free-threaded CPython builds (`gil_enabled=False`), even pure-Python `&` branches scale across cores via Mojo's `TaskGroup`; on GIL-enabled builds (`gil_enabled=True`), `NativeTask` stages still achieve full multi-core parallelism. Run `cd python && uv run python ../examples/benchmark_hybrid.py` to measure speedup on your machine.

---

## 4. Streaming & Software-Pipelined Batch Execution

Every single stage (`Combinable`) and composed pipeline (`_BaseTaskGroup`) exposes three batch/streaming methods (also available as standalone functions `map_stage`, `stream_stage`, `astream_stage`):

### Eager Concurrent Batch (`pipeline.map`)

```python
results = pipeline.map(range(100), max_in_flight=8)
```

- Preserves input order.
- `max_in_flight=0` (default) picks a CPU-scaled default (`min(32, cpu_count + 4)`).

### Lazy Sliding-Window Streaming (`pipeline.stream`)

```python
# Ordered streaming with strict O(max_in_flight) backpressure (safe for infinite generators!)
for result in pipeline.stream(infinite_generator(), max_in_flight=4, ordered=True):
    process(result)
    if done():
        break  # Pending futures are cancelled cleanly on generator close

# Unordered completion-order streaming for lower tail latency
for result in pipeline.stream(items, max_in_flight=8, ordered=False):
    process(result)
```

Unlike wave-barrier batching, `stream` maintains a true **sliding window** of at most `max_in_flight` active items:
- Upstream iterators are never pulled more than `max_in_flight` items ahead of active/buffered work.
- With `ordered=False`, fast items yield immediately without waiting behind slow items.
- With `max_in_flight=1`, executes via a fast zero-thread sequential path.

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

## Edge Cases & Behavioral Guarantees

### Composition, Immutability & Exceptions
- **Single-stage `TaskGroup`**: `TaskGroup(stage)(x)` delegates directly to `stage(x)` without wrapping in a tuple.
- **Exact traceback & short-circuiting**: A middle-stage exception in a serial `|` chain short-circuits downstream stages immediately and preserves the exact exception type and original traceback frames.
- **`ExceptionGroup` vs `BaseExceptionGroup` (PEP 654)**:
  - Single parallel branch failure (including `BaseException` subclasses like `KeyboardInterrupt` or custom `BaseException`s) re-raises that exact exception with its original traceback.
  - Multi-branch parallel failures raise `ExceptionGroup` when all failures subclass `Exception`, and `BaseExceptionGroup` (not an `ExceptionGroup`) when any branch raises a non-`Exception` `BaseException`.

### Hybrid GIL-Free `NativeStage` & `PyCapsule`
- **Integer boundaries & overflow (`native_int_linear`)**: Supports negative numbers, zero, and full signed 64-bit bounds (`-2**63` to `2**63 - 1`, including `-1`); out-of-range Python `int`s raise `OverflowError` cleanly.
- **Float inputs & IEEE-754 special values (`native_float_linear`, `native_float_poly`)**: Accept both Python `int` and `float` inputs, preserve `NaN`, `+inf`, and `-inf`, and raise `TypeError` on non-numeric inputs (e.g., `str`).
- **Fused native chain coercion**: Contiguous native stages automatically widen `int -> float` (`native_int_linear | native_float_linear`), while incompatible narrowing (`native_float_linear | native_int_linear`) raises `TypeError("Incompatible types between consecutive fused NativeStages")`.
- **Raw `PyCapsule` interop**: A `"strata.native_stage.v1"` `PyCapsule` can be passed directly into `TaskGroup(...)`, `|`, `&`, fused native chains, and `arun(...)` even without wrapping in `native_stage(...)`.
- **`native_cpu_work`**: `iterations=0` and negative counts clamp to `0` and return a deterministic non-negative 63-bit integer.
- **Hybrid parallel errors**: Native unboxing or fused-chain `TypeError`s combine cleanly with Python branch exceptions (e.g., `ValueError`) into a single PEP 654 `ExceptionGroup`.

### `AsyncTask`, `arun` & Streaming (`map` / `stream` / `astream`)
- **Calling `@async_task` synchronously inside an active event loop**: Calling `async_stage(x)` synchronously while an asyncio loop is already running on the current thread automatically delegates to a worker thread running `asyncio.run(...)` instead of raising a nested-loop `RuntimeError`.
- **`arun` coverage**: Works uniformly on single `AsyncTask`, single sync `@task`, single `NativeTask`, raw `PyCapsule`, empty `map_task`, `RetryTask`, `FallbackTask` (primary success short-circuit & non-matching `catch`), and `TimeoutTask`.
- **Streaming boundaries & error cleanup**:
  - `map`, `stream`, and `astream` handle empty and single-element iterables, `max_in_flight=1` (zero-thread / sequential fast path), and `max_in_flight > len(items)`.
  - `max_in_flight < 1` raises `ValueError`.
  - Mid-stream exceptions (in both `ordered=True` and `ordered=False` modes) shut down thread pools cleanly without hanging and cancel/await all remaining in-flight `asyncio.Task`s (preventing `"Task exception was never retrieved"` warnings).

