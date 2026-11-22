# Strata (Python)

Python bindings for **Strata v2**, a high-performance composable task graph execution framework powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

## Installation / Build

```bash
python -m pip install .
# or from Git:
uv add "strata @ git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

The package build installs Mojo as a Python build dependency and compiles `mojo_strata.so` automatically during installation. On Linux, Mojo wheels require glibc 2.34+.

For development:

```bash
uv sync --no-install-project --group dev --group test
uv run --no-build-isolation --reinstall-package strata --group dev --group test pytest
uv run --group dev ruff check src tests
uv run --group dev ty check src tests
```

---

## Quickstart

Pipelines are immutable, strictly typed (PEP 695/646), and directly callable:

```python
from strata import group, spread, task

@task
def parse_int(text: str) -> int:
    return int(text)

@task
def double(x: int) -> int:
    return x * 2

@task
def add_ten(x: int) -> int:
    return x + 10

@spread
def merge(a: int, b: int) -> str:
    return f"Branch 1: {a}, Branch 2: {b}"

pipeline = parse_int | (double & add_ten) | merge
print(pipeline("5"))  # "Branch 1: 10, Branch 2: 15"

# Parallel fan-outs flatten associatively; use `group(...)` for nested tuples:
flat = (double & add_ten) & (double & add_ten)              # (10, 15, 10, 15)
nested = group(double & add_ten) & group(double & add_ten)  # ((10, 15), (10, 15))
```

---

## Feature Showcase

### Hybrid GIL-Free Mojo Stages & PyCapsule Protocol

Mix pure Python tasks with GIL-free Mojo stages in the same `|` / `&` graph. Consecutive native stages automatically fuse into a single `GILReleased` pass, and parallel native branches scale across CPU cores even with the GIL enabled:

```python
from strata import native_cpu_work, native_int_linear, native_stage, spread, task

scale = native_int_linear(scale=3, bias=1, name="scale")
heavy = native_cpu_work(iterations=1_000_000, name="mix")

@task
def tag(x: int) -> str:
    return f"item-{x}"

@spread
def format_row(scaled: int, label: str, digest: int) -> str:
    return f"{label}: {scaled} ({digest})"

hybrid = (scale & tag & heavy) | format_row
print(hybrid(7))
```

### Dataflow & Resilience Combinators

```python
from strata import (
    branch,
    fallback,
    identity,
    map_task,
    retry,
    select,
    spread,
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

# Parallel product: (I1, I2) -> (O1, O2)
assert zip_tasks(inc, dbl)((3, 4)) == (4, 8)

# Conditional routing
router = branch(lambda x: x % 2 == 0, dbl, inc)
assert router(4) == 8 and router(5) == 6

# Dynamic parallel map with bounded wave concurrency
assert map_task(dbl, max_concurrency=4)([1, 2, 3, 4]) == [2, 4, 6, 8]

# Resilience: retry, fallback, timeout
safe = fallback(retry(timeout(inc, 1.0), max_attempts=3, backoff=0.01), dbl)
```

### Native `asyncio` (`@async_task` & `arun`)

```python
import asyncio
from strata import arun, async_task

@async_task
async def fetch_a(x: int) -> int:
    await asyncio.sleep(0.01)
    return x + 1

@async_task
async def fetch_b(x: int) -> int:
    await asyncio.sleep(0.01)
    return x * 2

pipe = fetch_a & fetch_b
print(asyncio.run(pipe.arun(5)))  # (6, 10)
```

### Sliding-Window Streaming (`map`, `stream`, `astream`)

```python
# Eager ordered batch
results = pipeline.map(["1", "2", "3", "4"], max_in_flight=4)

# Lazy streaming with O(max_in_flight) backpressure (ordered or completion order)
for item in pipeline.stream(["1", "2", "3", "4"], max_in_flight=4, ordered=False):
    print(item)
```

### Introspection, Visualization & Executors

```python
from strata import SequentialExecutor, TracingExecutor

print(pipeline.stats())          # GraphStats(stage_count=4, max_parallel_width=2, critical_depth=3)
print(pipeline.to_mermaid())     # Mermaid flowchart
print(pipeline.to_dot())         # Graphviz DOT

seq = SequentialExecutor()
assert seq.run(pipeline, "5") == "Branch 1: 10, Branch 2: 15"

tracer = TracingExecutor(sequential=False)
_ = tracer.run(pipeline, "5")
print(tracer.format_report())
```

---

## Detailed Guides

- [Root README](../README.md)
- [Python Hybrid, Async & Streaming Guide](../docs/python-hybrid-async-streaming.md)
- [Combinators & Resilience Guide](../docs/combinators-and-resilience.md)
- [Executors & Introspection Guide](../docs/executors-and-introspection.md)
- [Mojo Pipelines Guide](../docs/mojo-pipelines.md)
