# Strata

**Strata** is a high-performance, composable task graph execution framework for **Mojo** and **Python**, powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

Strata v2 provides a single, unified operator algebra across every Mojo and Python pipeline:
- **`|` (Pipe / Sequence)**: Executes stages sequentially, passing each stage's output to the next.
- **`&` (Parallel Fan-Out)**: Dispatches stages concurrently in **one flat `TaskGroup`** with full associative flattening (`a & (b & c)` and `(a & b) & (c & d)` both flatten into a single tuple).
- **`group(...)` (Explicit Nesting)**: Wraps a parallel stage as an opaque unit whenever nested tuple output (`group(a & b) & group(c & d) -> ((O1, O2), (O3, O4))`) is desired.

---

## Features

- **Unified `|` and `&` Composition**: Consistent operators across runtime pipelines, zero-sized compile-time pipelines, async pipelines, fallible/raising pipelines, stateful in-place pipelines, and Python.
- **Full Associative Flattening**: Merging parallel groups collapses into a single flat tuple and a single `TaskGroup` with zero nested `TaskGroup` overhead; opt into nested tuples cleanly with `group(...)`.
- **Compile-Time Safety & Evaluation**: Mismatched stage types fail at compile time, and `strata.pipeline.compt` supports `comptime_run` even across parallel diamonds.
- **Borrowed & Owned Pipelines**: Zero-allocation borrowed graphs (`Stage` / `ComposableStage`) plus value-owning `owned(...)` graphs that can be returned cleanly from factory functions.
- **Native Error Propagation**: Raising Mojo stages (`strata.pipeline.fallible`) and exact Python exception preservation (raising PEP 654 `ExceptionGroup` on multi-branch parallel failures).
- **Pluggable Executors**: Swap execution policies via `run_with(exec, x)` — `AsyncRTExecutor` (default), `SequentialExecutor` (deterministic debugging), `BoundedExecutor(max_workers=N)` (wave-capped concurrency), and `TracingExecutor` (per-stage monotonic nanosecond spans).
- **Dataflow & Resilience Combinators**: `identity`, `select`, `spread` (tuple unpacking), `zip_stages` / `zip_tasks` (parallel product `(I1, I2) -> (O1, O2)`), `map_stage` / `map_task` (dynamic parallel map), `branch` (conditional routing), plus `retry`, `fallback`, `timeout`, and `recover`.
- **Graph Introspection & Visualization**: Static topology metrics (`STAGE_COUNT`, `MAX_PARALLEL_WIDTH`, `CRITICAL_DEPTH` / `pipeline.stats()`) and `to_mermaid()` / `to_dot()` diagram export in both Mojo `compt` and Python.
- **Immutable Python Graphs**: Copy-on-write composition so sub-pipelines can be safely branched and reused without side effects.

---

## Project Architecture

```text
strata/
├── src/                               # Mojo source modules (v2.0)
│   ├── _internal/
│   │   └── runtime.mojo               # Single facade over std.runtime._asyncrt & intrinsics
│   ├── executors/
│   │   └── __init__.mojo              # Executor trait, AsyncRTExecutor, SequentialExecutor, BoundedExecutor, TracingExecutor
│   ├── pipeline/                      # Value-passing & unit pipelines
│   │   ├── __init__.mojo              # Stage, ComposableStage, Fn, UnitFn, Sequence, Parallel, Group, Owned*, run_with
│   │   ├── compt.mojo                 # Zero-sized comptime F[fn], Unit[fn], Id, Spread*, metadata, to_mermaid/to_dot
│   │   ├── combinators.mojo           # Id, Select, Spread*, Zip*, Map, Branch
│   │   ├── async_fn.mojo              # AF[fn], Sync[fn], AsyncSequence, AsyncParallel, AsyncGroup
│   │   ├── fallible.mojo              # FallibleStage, RaisingFn, RaisingSequence, RaisingParallel, raising_group
│   │   └── resilience.mojo            # Retry, Fallback, Timeout, Recover
│   ├── stateful/                      # In-place `mut self` pipelines (unified `|` and `&`)
│   │   ├── __init__.mojo              # MutStage, Series, flat Parallel (1 TaskGroup)
│   │   └── async_stage.mojo           # AsyncMutStage, AsyncSeries, flat AsyncParallel (1 TaskGroup)
│   └── interop/
│       └── python_interop.mojo        # CPython extension (mojo_strata.so)
├── python/                            # Python bindings and package
│   ├── src/strata/
│   │   ├── graph.py                   # Combinable, Task, FnTask, task, GroupedTask, group, *TaskGroup
│   │   ├── combinators.py             # identity, select, spread, zip_tasks, map_task, branch, retry, fallback, timeout
│   │   ├── introspect.py              # GraphStats, to_mermaid, to_dot, SequentialExecutor, TracingExecutor
│   │   └── mojo_strata.pyi            # PEP 695/646 type stubs
│   └── tests/                         # pytest test suite
├── examples/                          # Runnable pipeline examples
└── tests/                             # Mojo test suites & docstring completeness check
```

---

## Installation

### Mojo

```bash
git clone https://github.com/IbarraSamuel/strata.git
cd strata
pixi install
```

Or add Strata as a Pixi Git dependency:

```bash
pixi workspace preview add pixi-build
pixi workspace channel add https://prefix.dev/max-nightly https://prefix.dev/conda-forge
pixi add strata --git https://github.com/IbarraSamuel/strata.git
pixi install
```

### Python

```bash
python -m pip install "git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
uv add "strata @ git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

---

## Using Strata from Mojo

### 1. Runtime Pipelines (`strata.pipeline`)

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
    print(graph("14"))  # 42.0
```

Parallel stages flatten associatively (`(a & b) & (c & d) -> Tuple[O1, O2, O3, O4]`) and remain reusable. Wrap with `pipeline.group(...)` for explicit nesting, or use `pipeline.owned(...)` to build factory-returnable pipelines by value.

### 2. Zero-Sized Compile-Time Pipelines (`strata.pipeline.compt`)

```mojo
from strata.pipeline.compt import F, group

def add_one(x: Int) -> Int: return x + 1
def mul_two(x: Int) -> Int: return x * 2
def mul_three(x: Int) -> Int: return x * 3
def sum_pair(v: Tuple[Int, Int]) -> Int: return v[0] + v[1]

comptime diamond = F[add_one] | (F[mul_two] & F[mul_three]) | F[sum_pair]

# Evaluate at compile time OR run concurrently at runtime:
comptime ct_val = diamond.comptime_run[4]  # 25
var rt_val = diamond.run(4)                # 25
```

### 3. Fallible / Raising Pipelines (`strata.pipeline.fallible`)

```mojo
from strata.pipeline.fallible import RaisingFn

def parse_strict(s: String) raises -> Int:
    return Int(s)

def check_positive(x: Int) raises -> Int:
    if x <= 0:
        raise Error("must be positive")
    return x

def main() raises:
    var pipe = RaisingFn(parse_strict) | RaisingFn(check_positive)
    print(pipe("42"))
```

### 4. Async Pipelines (`strata.pipeline.async_fn`)

```mojo
from strata.pipeline.async_fn import AF, Sync

__async def fetch_a(x: Int) -> Int: return x * 2
__async def fetch_b(x: Int) -> Float32: return Float32(x)
def combine(v: Tuple[Int, Float32]) -> Float32: return Float32(v[0]) + v[1]

comptime graph = (AF[fetch_a] & AF[fetch_b]) | Sync[combine]
var out = graph.run(10)  # 30.0
```

### 5. Stateful In-Place Mutable Pipelines (`strata.stateful`)

```mojo
from strata import stateful

# Compose mutable stateful stages with unified `|` (series) and `&` (flat parallel)
var graph = init | ((branch1_a | branch1_b) & branch2) | finalize
graph()
```

---

## Using Strata from Python

```python
from strata import group, task

@task
def parse_int(raw: str) -> int:
    return int(raw)

@task
def double(x: int) -> int:
    return x * 2

@task
def add_ten(x: int) -> int:
    return x + 10

@task
def merge(pair: tuple[int, int]) -> str:
    return f"sum={pair[0] + pair[1]}"

# Immutable, directly callable pipeline
pipeline = parse_int | (double & add_ten) | merge
print(pipeline("5"))  # "sum=25"

# Associative flattening by default, explicit nesting via `group(...)`:
flat = (double & add_ten) & (double & add_ten)           # -> tuple[int, int, int, int]
nested = group(double & add_ten) & group(double & add_ten)  # -> tuple[tuple[int, int], tuple[int, int]]
```

---

## Development and Testing

```bash
# Run the complete suite (all Mojo suites, Python pytest, docs check)
pixi run tests

# Run individual Mojo suites
pixi run test_pipeline
pixi run test_pipeline_compt
pixi run test_pipeline_async
pixi run test_pipeline_fallible
pixi run test_stateful
pixi run test_stateful_async
pixi run test_executors
pixi run test_combinators
pixi run test_resilience
pixi run test_introspect

# Run Python tests, example, and docstring validation
pixi run python_test
pixi run generic_pipeline_example
pixi run test_docs
```

---

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.
