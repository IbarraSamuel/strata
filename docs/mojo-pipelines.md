# Mojo Pipelines Guide

Strata v2 offers five orthogonal Mojo pipeline engines built around a single unified operator algebra:

- **`|`** — Sequential composition (pipes output of the left stage into the input of the right stage).
- **`&`** — Parallel fan-out (dispatches branches concurrently in **one flat `TaskGroup`** with full associative flattening).
- **`group(...)`** / **`owned_group(...)`** / **`raising_group(...)`** — Explicit opaque grouping when nested tuple output is intentionally desired.

| Module | Best For | Zero-Sized? | Raises? | Async? | Pluggable `Executor`? |
| :--- | :--- | :---: | :---: | :---: | :---: |
| `strata.pipeline` | Runtime borrowed & value-owning graphs, dynamic stages, combinators | No | No | Sync | Yes |
| `strata.pipeline.compt` | Zero-overhead static DAGs, `comptime_run`, static metrics & Mermaid/DOT | Yes | No | Sync | Yes |
| `strata.pipeline.async_fn` | Composing `__async def` coroutines with sync reducers | Yes | No | `__async` | No |
| `strata.pipeline.fallible` | Stages that `raises` with short-circuiting & resilience wrappers | No | Yes | Sync | No |
| `strata.stateful` / `strata.stateful.async_stage` | In-place `mut self` side-effecting pipelines | No | No | Both | No |

---

## 1. Runtime Value-Passing & Unit Pipelines (`strata.pipeline`)

### Borrowed Composition (`Fn`, `UnitFn`, `Stage`, `ComposableStage`)

Borrowed graphs store immutable `Pointer`s to stages with zero heap allocation. Because composition borrows stages immutably, every stage and sub-pipeline can be reused across multiple parent graphs.

```mojo
from strata import pipeline

def parse_int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0

def double_val(x: Int) -> Int:
    return x * 2

def to_float(x: Int) -> Float32:
    return Float32(x)

def merge(pair: Tuple[Int, Float32]) -> String:
    return String(Float32(pair[0]) + pair[1])

def main():
    var parse = pipeline.Fn(parse_int)
    var dbl = pipeline.Fn(double_val)
    var itof = pipeline.Fn(to_float)
    var fmt = pipeline.Fn(merge)

    var graph = parse | (dbl & itof) | fmt
    print(graph("14"))  # "42.0"
```

### Unit / Void Functions (`UnitFn`)

Use `UnitFn` to wrap `def() -> None` functions as `NoneType -> NoneType` stages that compose with the same `|` and `&` operators:

```mojo
from strata.pipeline import UnitFn

def step_a(): print("A")
def step_b(): print("B")
def step_c(): print("C")

def main():
    var a = UnitFn(step_a)
    var b = UnitFn(step_b)
    var c = UnitFn(step_c)

    var workflow = a | (b & c)
    _ = workflow(None)
```

### Full Associative Parallel Flattening & `group(...)`

All `&` compositions flatten symmetrically into a single flat `Tuple` executed inside a single `TaskGroup`:

```mojo
from strata.pipeline import Fn, group

def f1(x: Int) -> Int: return x + 1
def f2(x: Int) -> Int: return x + 2
def f3(x: Int) -> Int: return x + 3
def f4(x: Int) -> Int: return x + 4

def main():
    var a = Fn(f1)
    var b = Fn(f2)
    var c = Fn(f3)
    var d = Fn(f4)

    # All three produce the exact same flat Tuple[Int, Int, Int, Int]:
    var left_flat  = ((a & b) & c) & d
    var right_flat = a & (b & (c & d))
    var both_flat  = (a & b) & (c & d)
    var out = both_flat(10)  # (11, 12, 13, 14)

    # Opt into nested tuple output with group(...):
    var ab = a & b
    var cd = c & d
    var g1 = group(ab)
    var g2 = group(cd)
    var nested = g1 & g2
    var nested_out = nested(10)  # ((11, 12), (13, 14))
```

### Value-Owning Factory Pipelines (`owned`, `owned_group`)

Borrowed graphs tie their lifetime to local stage variables. When you want to build and **return** a pipeline from a factory function, wrap stages with `owned(...)` (and `owned_group(...)` for nested tuples) to transfer ownership by value:

```mojo
from strata.pipeline import (
    Fn,
    OwnedParallel,
    OwnedSequence,
    owned,
    owned_group,
)

def add_one(x: Int) -> Int: return x + 1
def mul_two(x: Int) -> Int: return x * 2
def mul_three(x: Int) -> Int: return x * 3
def sum_pair(v: Tuple[Int, Int]) -> Int: return v[0] + v[1]

def make_pipeline() -> OwnedSequence[
    OwnedSequence[Fn[Int, Int], OwnedParallel[Fn[Int, Int], Fn[Int, Int]]],
    Fn[Tuple[Int, Int], Int],
]:
    var branches = owned(Fn(mul_two)) & Fn(mul_three)
    return owned(Fn(add_one)) | branches^ | Fn(sum_pair)

def main():
    var pipe = make_pipeline()
    print(pipe(4))  # ((4 + 1) * 2) + ((4 + 1) * 3) = 25
```

### Custom Stateful/Parameterized `ComposableStage` Structs

Any struct conforming to `ComposableStage` (declaring `comptime I`, `comptime O`, and `def __call__(self, arg: Self.I) -> Self.O`) plugs straight into `|`, `&`, `owned(...)`, combinators, and `run_with(...)`:

```mojo
from strata.pipeline import ComposableStage, Fn

@fieldwise_init
struct Scale(ComposableStage, Copyable, Movable):
    comptime I = Int
    comptime O = Int
    var factor: Int

    def __call__(self, arg: Int) -> Int:
        return arg * self.factor

def add_five(x: Int) -> Int: return x + 5

def main():
    var s = Scale(3)
    var inc = Fn(add_five)
    var pipe = s | inc
    print(pipe(10))  # 35
```

---

## 2. Zero-Sized Compile-Time Pipelines (`strata.pipeline.compt`)

`strata.pipeline.compt` encodes the entire pipeline DAG directly into the Mojo type system. Stages are zero-sized types (`F[fn]`, `Unit[fn]`, `Id[T]`, `Spread2[fn]`–`Spread4[fn]`, `group(...)`), enabling:

- Zero runtime memory overhead for the graph structure.
- Compile-time evaluation via `comptime_run[value]` — **even on graphs containing parallel diamonds** (internally falls back to `run_sequential` at comptime, then runs concurrently via `TaskGroup` at runtime).
- Compile-time topology metrics (`STAGE_COUNT`, `MAX_PARALLEL_WIDTH`, `CRITICAL_DEPTH`) and Mermaid/Graphviz DOT rendering (see [Executors & Introspection](executors-and-introspection.md)).

```mojo
from strata.pipeline.compt import F, Id, Spread2, Unit, group

def add_one(x: Int) -> Int: return x + 1
def mul_two(x: Int) -> Int: return x * 2
def mul_three(x: Int) -> Int: return x * 3
def add_pair(a: Int, b: Int) -> Int: return a + b

comptime diamond = F[add_one] | (F[mul_two] & F[mul_three]) | Spread2[add_pair]

def main():
    # Evaluate completely at compile time:
    comptime compile_time_result = diamond.comptime_run[4]  # 25

    # Or execute concurrently at runtime:
    var runtime_result = diamond.run(4)                     # 25

    # Identity pass-through in parallel fan-outs (keep original input + transformed):
    comptime keep_and_double = Id[Int] & F[mul_two]
    var pair = keep_and_double.run(7)                       # (7, 14)

    # Explicit nested grouping:
    comptime nested = group(F[mul_two] & F[mul_three]) & F[add_one]
    var nested_out = nested.run(5)                          # ((10, 15), 6)
```

---

## 3. Asynchronous Function Pipelines (`strata.pipeline.async_fn`)

`strata.pipeline.async_fn` composes Mojo `__async def` coroutines (`AF[async_fn]`) alongside synchronous reducers (`Sync[sync_fn]`) using `|`, `&`, and `group(...)`.

- **`AsyncParallel` + `Sync` composition**: Fan-out diamonds like `(AF[a] & AF[b]) | Sync[merge]` compose directly, and `Sync` accepts any input type (including tuples, `String`, and custom structs).

```mojo
from strata.pipeline.async_fn import AF, Sync, group, par_fn, par_fns

__async def fetch_score(id: Int) -> Int:
    return id * 10

__async def fetch_weight(id: Int) -> Float32:
    return Float32(id) * 0.5

def weighted_sum(v: Tuple[Int, Float32]) -> Float32:
    return Float32(v[0]) + v[1]

comptime workflow = (AF[fetch_score] & AF[fetch_weight]) | Sync[weighted_sum]

def main():
    print(workflow.run(4))  # 42.0

    # Standalone parallel helper for two async functions:
    var pair = par_fn[fetch_score, fetch_weight](4)  # (40, 2.0)
```

---

## 4. Fallible / Raising Pipelines (`strata.pipeline.fallible`)

`strata.pipeline.fallible` enables Mojo stages whose `__call__` can `raises` to compose cleanly without swallowing exceptions:

- **`|`** (`RaisingSequence`): Short-circuits immediately on the first error; downstream stages are never invoked.
- **`&`** (`RaisingParallel`): Runs all branches concurrently in one flat `TaskGroup`, captures per-branch errors safely across async tasks, and re-raises after `tg.wait()` (joining messages when multiple branches fail).
- **`raising_group(...)`**: Preserves nested tuple output under `&`.
- Connects directly to resilience wrappers (`retry`, `fallback`, `timeout`, `recover`) in [Combinators & Resilience](combinators-and-resilience.md).

```mojo
from strata.pipeline.fallible import RaisingFn, raising_group

def parse_int(s: String) raises -> Int:
    return Int(s)

def require_positive(x: Int) raises -> Int:
    if x <= 0:
        raise Error("value must be positive")
    return x

def double_checked(x: Int) raises -> Int:
    return x * 2

def main() raises:
    var p = RaisingFn(parse_int)
    var pos = RaisingFn(require_positive)
    var dbl = RaisingFn(double_checked)

    var pipe = p | (pos & dbl)
    var res = pipe("21")   # (21, 42)
    print(res[0], res[1])
```

---

## 5. Stateful In-Place Mutable Pipelines (`strata.stateful` & `strata.stateful.async_stage`)

When stages mutate internal state in place (`def __call__(mut self)` or `__async def __call__(mut self)`), conform your structs to `MutStage` or `AsyncMutStage`. Both use unified `|` (series) and `&` (flat parallel in a single `TaskGroup`) and support both borrowed and owned stage values.

### Synchronous Mutable Stages (`strata.stateful`)

```mojo
from strata.stateful import MutStage

struct Incrementer(MutStage, Movable):
    var count: Int

    def __init__(out self, start: Int = 0):
        self.count = start

    def __call__(mut self):
        self.count += 1

def main():
    var a = Incrementer(0)
    var b = Incrementer(10)
    var c = Incrementer(20)

    var graph = a | (b & c)
    graph()
    print(a.count, b.count, c.count)  # 1 11 21
```

### Asynchronous Mutable Stages (`strata.stateful.async_stage`)

```mojo
from strata.stateful.async_stage import AsyncMutStage

struct AsyncWorker(AsyncMutStage, Movable):
    var done: Bool

    def __init__(out self):
        self.done = False

    __async def __call__(mut self):
        self.done = True

def main():
    var w1 = AsyncWorker()
    var w2 = AsyncWorker()
    var w3 = AsyncWorker()

    var graph = w1 | (w2 & w3)
    graph.run()  # Blocks until the async graph finishes
```

---

## 6. GPU Pipelines (`max.gpu` & Device-Resident `DeviceBuffer` Stages)

Because `max.gpu.host.DeviceBuffer[dtype]` conforms to `Movable & Deinitable` and `DeviceContext` operations are `raises`, GPU stages integrate directly with `strata.pipeline.fallible` (`ComposableFallibleStage`):

- **Device-resident sequential chains (`|`)**: Upload host data to a `DeviceBuffer` in the first stage, pass `DeviceBuffer`s directly between intermediate GPU kernel stages on the same `DeviceContext[]` without host round-trips, and map back to host (`map_to_host()`) once at the end.
- **Parallel GPU fan-outs (`&`)**: When running parallel GPU branches across `TaskGroup` threads, give each concurrent branch its own `DeviceContext()` stream (since a single `DeviceContext` represents a single execution stream).

See Section 8 of [README.md](../README.md#8-gpu-pipelines-maxgpu--device-resident-stages) for a complete runnable example.

---

## Behavioral Notes

- **Associative flattening vs `group(...)`**: Chained `&` fan-outs (`((a & b) & c) & d`, `a & (b & (c & d))`, `(a & b) & (c & d)`) always produce the same flat `Tuple`. Wrap with `group(...)` (`owned_group(...)`, `raising_group(...)`) whenever nested tuples are wanted.
- **Reusability & ownership**: Borrowed pipelines hold immutable references so stages and sub-pipelines can be reused across multiple graphs; `owned(...)` moves stages by value so pipelines can be returned from helper functions.
- **Compile-time parity (`strata.pipeline.compt`)**: `comptime_run[value]` evaluates parallel diamonds, `group(...)`, `Id[T]`, and `Spread2`–`Spread4` at compile time with results identical to runtime `.run(value)`.
- **Heap-owning `Movable` outputs**: All pipeline engines safely handle non-trivial `Movable` types such as `String` and `List`.
- **Fallible error semantics**: Sequential `|` stops on the first raised error without running downstream stages; parallel `&` runs all branches, propagating the exact error when one branch fails or a combined `Error("Parallel stage failures (N): ...")` when multiple branches fail.

For internal `TaskGroup` scheduling, placement initialization, and unwinding details, see [DESIGN.md](../DESIGN.md).

