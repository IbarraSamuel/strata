# Strata

**Strata** is a high-performance, composable task graph execution framework for **Mojo** and **Python**, powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

Strata v2 provides a single, unified operator algebra across every Mojo and Python pipeline:

- **`|` (Pipe / Sequence)**: Executes stages sequentially, passing each stage's output to the next.
- **`&` (Parallel Fan-Out)**: Dispatches stages concurrently in **one flat `TaskGroup`** with full associative flattening (`a & (b & c)` and `(a & b) & (c & d)` both flatten into a single tuple).
- **`group(...)` (Explicit Nesting)**: Wraps a parallel stage as an opaque unit whenever nested tuple output (`group(a & b) & group(c & d) -> ((O1, O2), (O3, O4))`) is intentionally desired.

---

## Documentation Guides

Dive deep into each area of Strata v2 with runnable code examples:

1. **[Mojo Pipelines](docs/mojo-pipelines.md)** — Runtime (`strata.pipeline` borrowed & `owned`), zero-sized compile-time (`strata.pipeline.compt` & `comptime_run`), async (`strata.pipeline.async_fn`), fallible/raising (`strata.pipeline.fallible`), and stateful in-place (`strata.stateful` & `strata.stateful.async_stage`).
2. **[Dataflow & Resilience Combinators](docs/combinators-and-resilience.md)** — `identity`, `select`, `spread`, `zip_stages`/`zip_tasks`, `map_stage`/`map_task`, Mojo `stream_map`, `branch`, `retry`, `fallback`, `timeout`, and `recover`.
3. **[Pluggable Executors & Graph Introspection](docs/executors-and-introspection.md)** — `AsyncRTExecutor`, `SequentialExecutor`, `BoundedExecutor`, `TracingExecutor`, custom `Executor`s, compile-time & runtime `GraphStats`, and `to_mermaid()` / `to_dot()` diagram export.
4. **[Python: Hybrid GIL-Free Mojo, `async def` & Streaming](docs/python-hybrid-async-streaming.md)** — Immutable graphs, PEP 654 exception groups, GIL-free `NativeTask` & `"strata.native_stage.v1"` `PyCapsule` C-ABI, `@async_task` + `arun`, free-threaded Python diagnostics, and sliding-window `map`/`stream`/`astream`.

---

## Feature Highlights

- **Unified `|` and `&` Composition**: Consistent operator semantics across runtime, compile-time, async, fallible, stateful Mojo pipelines, and Python.
- **Full Associative Flattening + `group(...)`**: Chained `&` fan-outs collapse into one flat tuple and one `TaskGroup`; wrap with `group(...)` whenever nested tuple structure is wanted.
- **Compile-Time Safety & Evaluation**: Type mismatches fail at compile time; `strata.pipeline.compt` supports `comptime_run` even across parallel diamonds.
- **Borrowed & Owned Mojo Graphs**: Zero-allocation borrowed graphs (`Stage` / `ComposableStage`) plus value-owning `owned(...)` graphs returnable from factory functions.
- **Native Error Propagation**: Raising Mojo stages (`strata.pipeline.fallible`) and exact Python exception preservation (raising PEP 654 `ExceptionGroup` / `BaseExceptionGroup` on multi-branch parallel failures).
- **Pluggable Executors**: Swap execution policies via `run_with(exec, x)` — `AsyncRTExecutor`, `SequentialExecutor`, `BoundedExecutor`, and `TracingExecutor` (`TraceSpan`, `format_report()`).
- **Dataflow & Resilience Combinators**: `identity`, `select`, `spread`, `zip_stages`/`zip_tasks`, `map_stage`/`map_task`, `stream_map`, `branch`, `retry`, `fallback`, `timeout`, and `recover`.
- **Graph Introspection & Visualization**: Compile-time `STAGE_COUNT`, `MAX_PARALLEL_WIDTH`, `CRITICAL_DEPTH`, Python `pipeline.stats()`, and `to_mermaid()` / `to_dot()` export.
- **Hybrid GIL-Free Mojo + Python Pipelines**: Built-in `NativeTask` kernels and the extensible `strata.native_stage.v1` `PyCapsule` protocol execute native Mojo stages completely GIL-free alongside Python stages, with automatic serial chain fusion.
- **Python `async def` & Sliding-Window Streaming**: `@async_task` + `await pipeline.arun(x)` and bounded-backpressure `pipeline.map(...)`, `pipeline.stream(...)`, and `pipeline.astream(...)`.

---

## Project Architecture

```text
strata/
├── docs/                              # In-depth user guides
│   ├── mojo-pipelines.md
│   ├── combinators-and-resilience.md
│   ├── executors-and-introspection.md
│   └── python-hybrid-async-streaming.md
├── src/                               # Mojo source modules (v2.0)
│   ├── _internal/
│   │   └── runtime.mojo               # Single facade over std.runtime._asyncrt & intrinsics
│   ├── executors/
│   │   └── __init__.mojo              # Executor trait, AsyncRTExecutor, SequentialExecutor, BoundedExecutor, TracingExecutor
│   ├── pipeline/                      # Value-passing & unit pipelines
│   │   ├── __init__.mojo              # Stage, ComposableStage, Fn, UnitFn, Sequence, Parallel, Group, Owned*, run_with
│   │   ├── compt.mojo                 # Zero-sized comptime F[fn], Unit[fn], Id, Spread*, metadata, to_mermaid/to_dot
│   │   ├── combinators.mojo           # Id, Select, Spread*, Zip*, Map, OutputSink, stream_map, Branch
│   │   ├── async_fn.mojo              # AF[fn], Sync[fn], AsyncSequence, AsyncParallel, AsyncGroup
│   │   ├── fallible.mojo              # FallibleStage, RaisingFn, RaisingSequence, RaisingParallel, raising_group
│   │   └── resilience.mojo            # Retry, Fallback, Timeout, Recover
│   ├── stateful/                      # In-place `mut self` pipelines (unified `|` and `&`)
│   │   ├── __init__.mojo              # MutStage, Series, flat Parallel (1 TaskGroup)
│   │   └── async_stage.mojo           # AsyncMutStage, AsyncSeries, flat AsyncParallel (1 TaskGroup)
│   └── interop/
│       ├── native_abi.mojo            # Public Mojo C-ABI helpers for exporting strata.native_stage.v1 PyCapsules
│       └── python_interop.mojo        # CPython extension (mojo_strata.so) with GIL-free NativeStage & chain fusion
├── python/                            # Python bindings and package
│   ├── src/strata/
│   │   ├── graph.py                   # Combinable, Task, FnTask, task, GroupedTask, group, *TaskGroup
│   │   ├── combinators.py             # identity, select, spread, zip_tasks, map_task, branch, retry, fallback, timeout
│   │   ├── introspect.py              # GraphStats, to_mermaid, to_dot, SequentialExecutor, TracingExecutor
│   │   ├── native.py                  # NativeTask, native_stage, native_* kernels, runtime_info, is_gil_enabled
│   │   ├── async_support.py           # AsyncTask, async_task, native asyncio arun
│   │   ├── streaming.py               # stream_stage, map_stage, astream_stage with sliding-window backpressure
│   │   └── mojo_strata.pyi            # PEP 695/646 type stubs
│   └── tests/                         # pytest test suite
├── examples/                          # Runnable Mojo & hybrid Python benchmark examples
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

## Quickstart

### Mojo

```mojo
from strata import pipeline
from strata.executors import TracingExecutor
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

def merge(a: Int, b: Float32) -> String:
    return String(Float32(a) + b)

def main():
    var parse = pipeline.Fn(parse_int)
    var dbl = pipeline.Fn(double_val)
    var itof = pipeline.Fn(to_float)
    var fmt = spread(merge)

    var graph = parse | (dbl & itof) | fmt
    print(graph("14"))  # "42.0"

    # Run with tracing enabled
    var tracer = TracingExecutor()
    _ = graph.run_with(tracer, "14")
    print(tracer.format_report())
```

### Python (Hybrid Mojo + Python + Async + Streaming)

```python
import asyncio
from strata import (
    async_task,
    group,
    native_int_linear,
    spread,
    task,
)

@task
def parse_int(raw: str) -> int:
    return int(raw)

# GIL-free native Mojo stages
mul_two = native_int_linear(scale=2, bias=0, name="mul_two")
add_ten = native_int_linear(scale=1, bias=10, name="add_ten")

@spread
def merge(a: int, b: int) -> str:
    return f"sum={a + b}"

# Immutable, directly callable hybrid pipeline
pipeline = parse_int | (mul_two & add_ten) | merge
print(pipeline("5"))  # "sum=25"

# Bounded sliding-window streaming across a batch
print(list(pipeline.stream(["1", "2", "3", "4"], max_in_flight=4)))

# Export Mermaid topology
print(pipeline.to_mermaid())

# Async stages compose with the exact same operators and run natively via arun()
@async_task
async def fetch_value(x: int) -> int:
    await asyncio.sleep(0.01)
    return x * 3

async_pipe = (fetch_value & mul_two) | merge
print(asyncio.run(async_pipe.arun(4)))  # "sum=20"

# Explicit nested grouping when desired:
nested = group(mul_two & add_ten) & group(mul_two & add_ten)
print(nested(5))  # ((10, 15), (10, 15))
```

---

## Hybrid Parallelism Benchmark

Measured with [`examples/benchmark_hybrid.py`](examples/benchmark_hybrid.py) on GIL-enabled CPython 3.15.2 (8 CPUs):

| Workload | Sequential | Parallel (`&` / `stream`) | Speedup |
| :--- | :---: | :---: | :---: |
| Pure Python 4× 200k mixing iters | 121.33 ms | 119.31 ms | 1.02× *(GIL-bound)* |
| GIL-Free Mojo `NativeStage` 4× 5M iters | 33.53 ms | 10.77 ms | **3.11×** *(true multi-core)* |
| Streaming 32 items × 1M iters (`max_in_flight=4`) | 52.18 ms | 16.01 ms | **3.26×** |

---

## Development and Testing

```bash
# Run the complete suite (all Mojo suites, Python pytest, docs check)
pixi run tests

# Run individual Mojo test suites
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
pixi run test_stream_and_abi
pixi run test_edge_cases

# Run Python tests, examples, benchmark, linters, and docstring validation
pixi run python_test
pixi run generic_pipeline_example
pixi run test_docs
cd python && uv run --group dev ruff check src tests && uv run --group dev ty check src tests
cd python && uv run python ../examples/benchmark_hybrid.py
```

---

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.
