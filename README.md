# Strata

**Strata** is a composable pipeline and parallel task-graph library for **Mojo** and **Python**. Build sequential workflows and concurrent fan-out graphs with two operators:

- **`a | b` (Pipe / Sequence)**: Runs `a`, then passes its output as the input to `b`.
- **`a & b` (Parallel Fan-Out)**: Runs `a` and `b` concurrently on the same input and returns their outputs as a flat tuple `(out_a, out_b)`. Chaining more branches (`a & b & c` or `(a & b) & (c & d)`) keeps the result flat: `(out_a, out_b, out_c, out_d)`.
- **`group(a & b)` (Explicit Nesting)**: Keeps a parallel group wrapped when you want nested tuples (`group(a & b) & group(c & d)` -> `((o1, o2), (o3, o4))`).

---

## Table of Contents

- [Installation](#installation)
- [Using Strata in Mojo](#using-strata-in-mojo)
  - [1. Sequential & Parallel Function Pipelines](#1-sequential--parallel-function-pipelines)
  - [2. Custom Stage Structs & Returning Pipelines from Functions](#2-custom-stage-structs--returning-pipelines-from-functions)
  - [3. Compile-Time Pipelines (`strata.pipeline.compt`)](#3-compile-time-pipelines-stratapipelinecompt)
  - [4. Dataflow Combinators](#4-dataflow-combinators)
  - [5. Error Handling & Resilience](#5-error-handling--resilience)
  - [6. Async & Stateful Mutable Pipelines](#6-async--stateful-mutable-pipelines)
  - [7. Executors, Tracing & Visualization](#7-executors-tracing--visualization)
  - [8. GPU Pipelines (`max.gpu` & Device-Resident Stages)](#8-gpu-pipelines-maxgpu--device-resident-stages)
- [Using Strata in Python](#using-strata-in-python)
  - [1. Defining Tasks & Composing Pipelines](#1-defining-tasks--composing-pipelines)
  - [2. Handling Errors in Pipelines](#2-handling-errors-in-pipelines)
  - [3. Dataflow & Resilience Combinators](#3-dataflow--resilience-combinators)
  - [4. Async Tasks (`@async_task` & `arun`)](#4-async-tasks-async_task--arun)
  - [5. Batch & Streaming Execution (`map`, `stream`, `astream`)](#5-batch--streaming-execution-map-stream-astream)
  - [6. GIL-Free Native & GPU Stages (Scalars & Arrow Data)](#6-gil-free-native--gpu-stages-scalars--arrow-data)
  - [7. Introspection, Visualization & Tracing](#7-introspection-visualization--tracing)
- [Documentation & Architecture](#documentation--architecture)
- [Development & Testing](#development--testing)
- [License](#license)

---

## Installation

### Mojo

Clone the repository and install the Pixi environment:

```bash
git clone https://github.com/IbarraSamuel/strata.git
cd strata
pixi install
```

To add Strata as a dependency in another Pixi project:

```bash
pixi workspace preview add pixi-build
pixi workspace channel add https://prefix.dev/max-nightly https://prefix.dev/conda-forge
pixi add strata --git https://github.com/IbarraSamuel/strata.git
pixi install
```

### Python

Install from the `python/` subdirectory with `pip` or `uv` (this automatically builds the native Mojo extension; Linux requires glibc 2.34+):

```bash
python -m pip install "git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
# or in a uv project:
uv add "strata @ git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

---

## Using Strata in Mojo

### 1. Sequential & Parallel Function Pipelines

Wrap plain functions with `pipeline.Fn` (or `UnitFn` for `def() -> None` functions), chain steps with `|`, fan out in parallel with `&`, and unpack tuple outputs cleanly with `spread`:

```mojo
from strata import pipeline
from strata.pipeline import Fn, UnitFn, group
from strata.pipeline.combinators import spread

def parse_int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0

def double_val(x: Int) -> Int:
    return x * 2

def to_float(x: Int) -> Float32:
    return Float32(x)

def format_sum(a: Int, b: Float32) -> String:
    return String(Float32(a) + b)

def main():
    var parse = Fn(parse_int)
    var dbl = Fn(double_val)
    var itof = Fn(to_float)
    var merge = spread(format_sum)  # unpacks Tuple[Int, Float32] -> (Int, Float32)

    # Sequential (|) + parallel fan-out (&)
    var graph = parse | (dbl & itof) | merge
    print(graph("14"))  # "42.0"

    # Chained `&` flattens automatically; use `group(...)` for nested tuples:
    var flat = (dbl & dbl) & (dbl & dbl)
    var flat_out = flat(5)  # (10, 10, 10, 10)

    var g1 = dbl & dbl
    var g2 = dbl & dbl
    var nested = group(g1) & group(g2)
    var nested_out = nested(5)  # ((10, 10), (10, 10))
    print(flat_out[0], nested_out[0][0])
```

For zero-argument/void workflows, wrap functions with `UnitFn`:

```mojo
from strata.pipeline import UnitFn

def step_a(): print("prepare")
def step_b(): print("branch 1")
def step_c(): print("branch 2")

def main():
    var a = UnitFn(step_a)
    var b = UnitFn(step_b)
    var c = UnitFn(step_c)
    var workflow = a | (b & c)
    _ = workflow(None)
```

### 2. Custom Stage Structs & Returning Pipelines from Functions

Implement `ComposableStage` on any struct to create parameterized stages. By default, `|` and `&` borrow local stage variables; wrap stages with `owned(...)` (and `owned_group(...)`) when you want to return a self-contained pipeline from a function:

```mojo
from strata.pipeline import (
    ComposableStage,
    Fn,
    OwnedParallel,
    OwnedSequence,
    owned,
)

@fieldwise_init
struct Scale(ComposableStage, Copyable, Movable):
    comptime I = Int
    comptime O = Int
    var factor: Int

    def __call__(self, arg: Int) -> Int:
        return arg * self.factor

def add_one(x: Int) -> Int: return x + 1
def sum_pair(pair: Tuple[Int, Int]) -> Int: return pair[0] + pair[1]

def make_scorer(
    factor: Int,
) -> OwnedSequence[
    OwnedSequence[Fn[Int, Int], OwnedParallel[Scale, Fn[Int, Int]]],
    Fn[Tuple[Int, Int], Int],
]:
    var branches = owned(Scale(factor)) & Fn(add_one)
    return owned(Fn(add_one)) | branches^ | Fn(sum_pair)

def main():
    var scorer = make_scorer(3)
    print(scorer(4))  # ((4 + 1) * 3) + ((4 + 1) + 1) = 21
```

### 3. Compile-Time Pipelines (`strata.pipeline.compt`)

When every stage is a compile-time known function, `strata.pipeline.compt` builds zero-sized pipelines that can run **either** at compile time (`comptime_run`) or concurrently at runtime (`.run(x)`):

```mojo
from strata.pipeline.compt import F, Id, Spread2

def add_one(x: Int) -> Int: return x + 1
def mul_two(x: Int) -> Int: return x * 2
def mul_three(x: Int) -> Int: return x * 3
def add_pair(a: Int, b: Int) -> Int: return a + b

comptime diamond = F[add_one] | (F[mul_two] & F[mul_three]) | Spread2[add_pair]

def main():
    comptime ct_val = diamond.comptime_run[4]  # evaluated at compile time: 25
    var rt_val = diamond.run(4)                # executed concurrently at runtime: 25
    print(ct_val, rt_val)

    # Keep original input alongside a transformed value:
    comptime keep_and_double = Id[Int] & F[mul_two]
    var pair = keep_and_double.run(7)          # (7, 14)
    print(pair[0], pair[1])
```

### 4. Dataflow Combinators

`strata.pipeline.combinators` provides reusable building blocks that compose directly with `|` and `&`:

```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import (
    OutputSink,
    branch,
    identity,
    map_stage,
    select,
    stream_map,
    zip_stages,
)

def inc(x: Int) -> Int: return x + 1
def dbl(x: Int) -> Int: return x * 2
def is_even(x: Int) -> Bool: return x % 2 == 0

struct SumSink(OutputSink):
    comptime Item = Int
    var total: Int
    def __init__(out self): self.total = 0
    def on_item(mut self, var item: Int): self.total += item

def main():
    var s_inc = Fn(inc)
    var s_dbl = Fn(dbl)

    # Keep input + transform, then project index 1:
    var keep = identity[Int]()
    var pick_second = select[1, Int, Int]()
    var projected = (keep & s_dbl) | pick_second
    print(projected(6))  # 12

    # Apply different stages to each element of a tuple: (I1, I2) -> (O1, O2)
    var zipped = zip_stages(s_inc, s_dbl)
    var z = zipped((3, 4))  # (4, 8)
    print(z[0], z[1])

    # Conditional routing by predicate:
    var router = branch(is_even, s_dbl, s_inc)
    print(router(10), router(7))  # 20 8

    # Parallel map over a List[Int] -> List[Int]:
    var batch = map_stage(s_dbl, max_concurrency=4)
    var items: List[Int] = [1, 2, 3, 4]
    var mapped = batch(items)  # [2, 4, 6, 8]
    print(len(mapped))

    # Bounded-memory streaming map into an OutputSink:
    var sink = SumSink()
    stream_map(s_dbl, items, max_in_flight=2, sink=sink)
    print(sink.total)  # 20
```

### 5. Error Handling & Resilience

Use `strata.pipeline.fallible` for stages that `raises`, and wrap them with `retry`, `fallback`, `timeout`, or `recover` (`strata.pipeline.resilience`):

```mojo
from strata.pipeline import Fn
from strata.pipeline.fallible import RaisingFn
from strata.pipeline.resilience import fallback, recover, retry, timeout

def parse_positive(s: String) raises -> Int:
    var v = Int(s)
    if v <= 0:
        raise Error("expected positive integer")
    return v

def default_one(s: String) raises -> Int:
    return 1

def on_error(raw: String, err_msg: String) -> Int:
    return 0

def double_val(x: Int) -> Int:
    return x * 2

def main() raises:
    var parser = RaisingFn(parse_positive)
    var fb_one = RaisingFn(default_one)

    # Retry up to 3 times, enforce a 0.5s deadline, or fall back to default_one:
    var guarded = timeout(parser, timeout_secs=0.5)
    var retried = retry(guarded, max_attempts=3, backoff_secs=0.01)
    var resilient = fallback(retried, fb_one)
    print(resilient("21"))   # 21
    print(resilient("-5"))   # 1 (via fallback)

    # Or bridge a fallible stage into a non-raising pipeline with `recover`:
    var infallible = recover(parser, on_error)
    var dbl = Fn(double_val)
    var pipe = infallible | dbl
    print(pipe("21"), pipe("bad"))  # 42 0
```

### 6. Async & Stateful Mutable Pipelines

Compose `__async def` functions with `strata.pipeline.async_fn`, or mutate stage fields in place (`mut self`) with `strata.stateful` (and `strata.stateful.async_stage`):

```mojo
from strata.pipeline.async_fn import AF, Sync
from strata.stateful import MutStage

__async def fetch_a(x: Int) -> Int: return x * 10
__async def fetch_b(x: Int) -> Int: return x + 2
def sum_pair(p: Tuple[Int, Int]) -> Int: return p[0] + p[1]

comptime async_pipe = (AF[fetch_a] & AF[fetch_b]) | Sync[sum_pair]

struct Counter(MutStage, Movable):
    var count: Int
    def __init__(out self, start: Int = 0): self.count = start
    def __call__(mut self): self.count += 1

def main():
    print(async_pipe.run(4))  # 46

    var c1 = Counter(0)
    var c2 = Counter(10)
    var c3 = Counter(20)
    var mut_graph = c1 | (c2 & c3)
    mut_graph()
    print(c1.count, c2.count, c3.count)  # 1 11 21
```

### 7. Executors, Tracing & Visualization

Control concurrency and record per-stage latency without changing your pipeline using `run_with`, and export static Mermaid or Graphviz DOT diagrams from `compt` pipelines:

```mojo
from strata.executors import BoundedExecutor, SequentialExecutor, TracingExecutor
from strata.pipeline.compt import F, Spread2

def step_a(x: Int) -> Int: return x + 1
def left(x: Int) -> Int: return x * 2
def right(x: Int) -> Int: return x * 3
def merge(a: Int, b: Int) -> Int: return a + b

comptime pipe = F[step_a] | (F[left] & F[right]) | Spread2[merge]

def main():
    var seq = SequentialExecutor()
    print(pipe.run_with(seq, 4))      # 25 (single-threaded)

    var bounded = BoundedExecutor(max_workers=2)
    print(pipe.run_with(bounded, 4))  # 25 (at most 2 branches per wave)

    var tracer = TracingExecutor()
    _ = pipe.run_with(tracer, 4)
    print(tracer.format_report())

    # Static topology metadata and Mermaid / Graphviz DOT diagrams:
    print("Stages:", pipe.STAGE_COUNT, "Width:", pipe.MAX_PARALLEL_WIDTH)
    print(pipe.to_mermaid())
```

### 8. GPU Pipelines (`max.gpu` & Device-Resident Stages)

Mojo pipelines work directly with `max.gpu` (`DeviceContext`, `DeviceBuffer`, `TileTensor`). Because `DeviceBuffer[dtype]` conforms to `Movable & Deinitable`, stages in `strata.pipeline.fallible` (`ComposableFallibleStage`) can pass GPU buffers directly from kernel to kernel without copying back to host memory between stages:

```mojo
from std.sys import has_accelerator
from layout import ImmTileTensor, MutTileTensor, TileTensor, row_major
from max.gpu import global_idx
from max.gpu.host import DeviceBuffer, DeviceContext
from strata.pipeline.fallible import ComposableFallibleStage

comptime N = 8
comptime layout = row_major[N]()

def scale_bias_kernel(
    inp: ImmTileTensor[DType.float32, type_of(layout), ImmUntrackedOrigin],
    output: MutTileTensor[DType.float32, type_of(layout), MutUntrackedOrigin],
    scale: Float32,
    bias: Float32,
):
    comptime assert inp.flat_rank == 1 and output.flat_rank == 1
    var tid = global_idx.x
    if tid < N:
        output[tid] = inp[tid] * scale + bias

struct ToDevice(ComposableFallibleStage):
    comptime I = List[Float32]
    comptime O = DeviceBuffer[DType.float32]
    var ctx: DeviceContext[]

    def __init__(out self, ctx: DeviceContext[]):
        self.ctx = ctx

    def __call__(self, arg: List[Float32]) raises -> DeviceBuffer[DType.float32]:
        var buf = self.ctx.enqueue_create_buffer[DType.float32](N)
        with buf.map_to_host() as host:
            for i in range(N):
                host[i] = arg[i]
        return buf^

struct GpuLinear(ComposableFallibleStage):
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
        var out_buf = self.ctx.enqueue_create_buffer[DType.float32](N)
        var t_in = TileTensor(arg, layout)
        var t_out = TileTensor(out_buf, layout)
        self.ctx.enqueue_function[scale_bias_kernel](
            t_in.as_imm(),
            t_out,
            self.scale,
            self.bias,
            grid_dim=1,
            block_dim=N,
        )
        return out_buf^

struct ToHost(ComposableFallibleStage):
    comptime I = DeviceBuffer[DType.float32]
    comptime O = List[Float32]

    def __init__(out self):
        pass

    def __call__(self, arg: DeviceBuffer[DType.float32]) raises -> List[Float32]:
        var res = List[Float32](length=N, fill=0.0)
        with arg.map_to_host() as host:
            for i in range(N):
                res[i] = host[i]
        return res^

def main() raises:
    comptime if has_accelerator():
        var ctx = DeviceContext()
        var upload = ToDevice(ctx)
        var step1 = GpuLinear(ctx, 2.0, 1.0)
        var step2 = GpuLinear(ctx, 3.0, -1.0)
        var download = ToHost()

        # Upload once -> run both GPU kernels on device memory -> download once:
        var gpu_pipe = upload | step1 | step2 | download
        var inp: List[Float32] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        var out = gpu_pipe(inp)
        print(out[0], out[1], out[7])  # 8.0 14.0 50.0
```

---

## Using Strata in Python

### 1. Defining Tasks & Composing Pipelines

Decorate functions with `@task` (or `@spread` to unpack tuple inputs), or subclass `Combinable` for stateful tasks. Pipelines are **immutable** and directly callable:

```python
from dataclasses import dataclass
from strata import Combinable, group, spread, task

@task
def parse_int(raw: str) -> int:
    return int(raw)

@dataclass
class Linear(Combinable):
    scale: int
    bias: int = 0

    def __call__(self, x: int) -> int:
        return x * self.scale + self.bias

@spread
def summarize(a: int, b: int) -> str:
    return f"left={a}, right={b}"

double = Linear(scale=2)
plus_ten = Linear(scale=1, bias=10)

# Compose sequentially (|) and in parallel (&)
pipeline = parse_int | (double & plus_ten) | summarize
print(pipeline("5"))  # "left=10, right=15"

# Pipelines are immutable — reusing `base` never mutates it:
base = parse_int | double
branch_a = base | plus_ten
assert base("5") == 10 and branch_a("5") == 20

# Associative flattening vs explicit `group(...)` nesting:
flat = (double & plus_ten) & (double & plus_ten)
assert flat(5) == (10, 15, 10, 15)

nested = group(double & plus_ten) & group(double & plus_ten)
assert nested(5) == ((10, 15), (10, 15))
```

### 2. Handling Errors in Pipelines

- **Sequential (`|`)**: Stops immediately on the first exception and re-raises it with its original traceback.
- **Parallel (`&`)**: Re-raises the exact exception if a single branch fails, or raises a standard Python `ExceptionGroup` (catchable with `except*`) if multiple branches fail simultaneously:

```python
from strata import task

@task
def fail_value(_x: int) -> int:
    raise ValueError("bad value")

@task
def fail_key(_x: int) -> int:
    raise KeyError("missing key")

try:
    (fail_value & fail_key)(1)
except* ValueError as eg:
    print("Caught ValueError:", eg.exceptions)
except* KeyError as eg:
    print("Caught KeyError:", eg.exceptions)
```

### 3. Dataflow & Resilience Combinators

```python
from strata import (
    branch,
    fallback,
    identity,
    map_task,
    retry,
    select,
    task,
    timeout,
    zip_tasks,
)

@task
def inc(x: int) -> int:
    return x + 1

@task
def dbl(x: int) -> int:
    return x * 2

# Keep input alongside a transformed result, or pick one tuple element:
assert (identity() & dbl)(7) == (7, 14)
assert ((inc & dbl) | select(1))(5) == 10

# Apply stages concurrently to respective tuple elements: (I1, I2) -> (O1, O2)
assert zip_tasks(inc, dbl)((3, 4)) == (4, 8)

# Conditional routing:
collatz_step = branch(lambda x: x % 2 == 0, task(lambda x: x // 2), task(lambda x: 3 * x + 1))
assert collatz_step(10) == 5 and collatz_step(7) == 22

# Parallel list map with bounded concurrency:
assert map_task(dbl, max_concurrency=4)([1, 2, 3, 4]) == [2, 4, 6, 8]

# Fault tolerance: timeout, retry with exponential backoff, and fallback:
resilient = fallback(
    retry(timeout(inc, seconds=1.0), max_attempts=3, backoff=0.02),
    dbl,
    catch=(TimeoutError, RuntimeError),
)
assert resilient(10) == 11
```

### 4. Async Tasks (`@async_task` & `arun`)

Decorate `async def` coroutines with `@async_task` and mix them freely with regular `@task` and native stages. Run from synchronous code via `pipeline(x)` or await natively on an event loop via `await pipeline.arun(x)`:

```python
import asyncio
from strata import async_task, spread, task

@async_task
async def fetch_user(user_id: int) -> str:
    await asyncio.sleep(0.01)
    return f"user-{user_id}"

@async_task
async def fetch_score(user_id: int) -> int:
    await asyncio.sleep(0.01)
    return user_id * 100

@spread
def render(name: str, score: int) -> str:
    return f"{name}: {score}"

profile_pipe = (fetch_user & fetch_score) | render

async def main() -> None:
    print(await profile_pipe.arun(7))  # "user-7: 700"

asyncio.run(main())
```

### 5. Batch & Streaming Execution (`map`, `stream`, `astream`)

Every task and pipeline provides `.map(...)`, `.stream(...)`, and `.astream(...)` (also available as standalone `map_stage`, `stream_stage`, `astream_stage`) with bounded `max_in_flight` backpressure:

```python
import asyncio

# 1. Eager ordered batch across inputs:
results = pipeline.map(["1", "2", "3", "4"], max_in_flight=4)

# 2. Lazy sliding-window stream (safe on large or infinite iterators):
for out in pipeline.stream((str(i) for i in range(20)), max_in_flight=4, ordered=True):
    if out.startswith("left=10"):
        break  # cleanly cancels remaining work and closes upstream generator

# 3. Unordered completion-order streaming (lowest latency when item times vary):
fast_first = list(pipeline.stream(["1", "2", "3", "4"], max_in_flight=4, ordered=False))

# 4. Async streaming over sync or async iterables:
async def consume() -> list[str]:
    return [item async for item in profile_pipe.astream(range(5), max_in_flight=3)]

print(asyncio.run(consume()))
```

### 6. GIL-Free Native & GPU Stages (Scalars & Arrow Data)

On standard GIL-enabled Python, CPU-bound Python functions contend on the GIL across threads. Strata includes built-in **GIL-free Mojo stages** for both **scalars** and **Arrow-compatible columnar data** (with GPU acceleration):

#### Scalar GIL-Free Stages

```python
from strata import (
    native_cpu_work,
    native_float_linear,
    native_int_linear,
    runtime_info,
    spread,
    task,
)

print(runtime_info())  # inspects Python version, GIL state, CPU count, and gpu_available

mul3_add1 = native_int_linear(scale=3, bias=1, name="mul3_add1")     # int -> int
to_float = native_float_linear(scale=0.5, bias=0.25, name="to_flt")  # int|float -> float
heavy_mix = native_cpu_work(iterations=1_000_000, name="mix")        # int -> int

@task
def label(x: int) -> str:
    return f"item-{x}"

@spread
def combine(val: float, tag: str, digest: int) -> str:
    return f"{tag}: {val} (digest={digest})"

# Native branches run GIL-free alongside Python tasks:
hybrid = ((mul3_add1 | to_float) & label & heavy_mix) | combine
print(hybrid(5))
```

#### Arrow Columnar Data & GPU Execution (`ArrowArray`, `gpu_arrow_*`)

Pass Arrow-like columnar data (`strata.ArrowArray`, `pyarrow.Array`, `polars.Series`, or any object implementing `__arrow_c_array__()`, as well as 1D numeric sequences) into GPU-accelerated or GIL-free CPU Mojo stages. Consecutive GPU stages chained with `|` fuse on device memory (uploading once and downloading once), and return a `strata.ArrowArray` implementing `__arrow_c_array__()`:

```python
from strata import (
    ArrowArray,
    gpu_arrow_float_linear,
    gpu_arrow_float_poly,
    gpu_arrow_int_linear,
    has_gpu,
    native_arrow_float_linear,
    spread,
)

print("GPU available:", has_gpu())

# Create an Arrow-compatible columnar array (or pass a pyarrow.Array / polars.Series directly)
col = ArrowArray([1.0, 2.0, 3.0, 4.0])

# GPU-accelerated stages (automatically fuse on device memory across `|`):
scale_gpu = gpu_arrow_float_linear(scale=2.0, bias=1.0, name="scale_gpu")
poly_gpu = gpu_arrow_float_poly(c0=1.0, c1=2.0, c2=3.0, name="poly_gpu")
cpu_shift = native_arrow_float_linear(scale=0.5, bias=10.0, name="cpu_shift")

@spread
def merge_columns(gpu_out: ArrowArray[float], cpu_out: ArrowArray[float]) -> ArrowArray[float]:
    return ArrowArray([g + c for g, c in zip(gpu_out, cpu_out, strict=True)])

arrow_pipe = ((scale_gpu | poly_gpu) & cpu_shift) | merge_columns
result = arrow_pipe(col)

print(result)            # ArrowArray(dtype='float64', length=4, values=[44.5, 108.0, 207.5, 343.0])
print(result.to_list())  # [44.5, 108.0, 207.5, 343.0]

# Zero-copy export to PyArrow / Polars via the Apache Arrow C Data Interface (__arrow_c_array__):
schema_capsule, array_capsule = result.__arrow_c_array__()
# Or directly: pa_array = result.to_pyarrow()
```

Need a custom GIL-free Mojo CPU or GPU kernel for scalars or Arrow columns? Export a `"strata.native_stage.v1"` `PyCapsule` using `export_arrow_float_stage_capsule` / `export_arrow_int_stage_capsule` (or `export_float_stage_capsule` / `export_int_stage_capsule` / `export_value_stage_capsule`) and wrap it with `native_stage(...)` — see the [Python Hybrid, Async & Streaming Guide](docs/python-hybrid-async-streaming.md).

### 7. Introspection, Visualization & Tracing

Inspect pipeline metrics, export Mermaid or Graphviz DOT diagrams, or capture per-stage execution timings:

```python
from strata import SequentialExecutor, TracingExecutor

print(pipeline.stats())
# GraphStats(stage_count=4, max_parallel_width=2, critical_depth=3)

print(pipeline.to_mermaid())                  # Mermaid flowchart (`direction="LR"` or `"TD"`)
print(pipeline.to_dot(name="OrderPipeline"))  # Graphviz DOT

# Run deterministically on a single thread for debugging:
assert SequentialExecutor().run(pipeline, "5") == "left=10, right=15"

# Record per-stage latency spans:
tracer = TracingExecutor(sequential=False)
_ = tracer.run(pipeline, "5")
print(tracer.format_report())
```

---

## Documentation & Architecture

- **[Mojo Pipelines Guide](docs/mojo-pipelines.md)** — Detailed walkthrough of runtime, compile-time (`compt`), `__async`, fallible (`raises`), and stateful (`mut self`) Mojo pipelines.
- **[Dataflow & Resilience Combinators Guide](docs/combinators-and-resilience.md)** — Reference and examples for `identity`, `select`, `spread`, `zip_*`, `map_*`, `stream_map`, `branch`, `retry`, `fallback`, `timeout`, and `recover`.
- **[Executors & Introspection Guide](docs/executors-and-introspection.md)** — Custom Mojo `Executor`s, `BoundedExecutor`, `TracingExecutor`, static/runtime `GraphStats`, and Mermaid/DOT export.
- **[Python Hybrid, Async & Streaming Guide](docs/python-hybrid-async-streaming.md)** — Custom GIL-free Mojo `PyCapsule` extensions (CPU & GPU), `@async_task` / `arun`, free-threaded Python, and sliding-window streaming.
- **[Design & Architecture (`DESIGN.md`)](DESIGN.md)** — Internal module layout, associative `&` flattening, single-`TaskGroup` memory/exception model, `mojo_strata.so` precomputed plan fusion, C-ABI layout specification, and benchmarks.

---

## Development & Testing

```bash
# Run the full test suite (all Mojo suites, Python pytest, and docstring checks)
pixi run tests

# Run Mojo suites, Python tests, or docstring checks individually
pixi run test_runners
pixi run python_test
pixi run test_docs

# Lint and type-check the Python package
cd python && uv run --group dev ruff check src tests && uv run --group dev ty check src tests

# Run hybrid parallelism & low-latency benchmarks
cd python && uv run python ../examples/benchmark_hybrid.py
```

---

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
