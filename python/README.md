# Strata (Python)

Composable pipeline and parallel task-graph library for Python, backed by Mojo's multithreaded runtime (`mojo_strata.so`).

- **`a | b` (Pipe / Sequence)**: Passes the output of `a` into `b`.
- **`a & b` (Parallel Fan-Out)**: Runs `a` and `b` concurrently on the same input and returns a flat tuple `(out_a, out_b)`.
- **`group(a & b)` (Explicit Nesting)**: Preserves nested tuple output (`group(a & b) & group(c & d)` -> `((o1, o2), (o3, o4))`).

## Installation

```bash
python -m pip install .
# or from Git:
uv add "strata @ git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

Installing compiles `mojo_strata.so` automatically using Mojo as a build dependency (Linux requires glibc 2.34+).

For local development:

```bash
uv sync --no-install-project --group dev --group test
uv run --no-build-isolation --reinstall-package strata --group dev --group test pytest
uv run --group dev ruff check src tests
uv run --group dev ty check src tests
```

---

## Usage

### 1. Tasks, Operators & Immutability

```python
from strata import Combinable, group, spread, task

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

# Parallel fan-outs flatten associatively; wrap with `group(...)` for nested tuples:
flat = (double & add_ten) & (double & add_ten)              # (10, 15, 10, 15)
nested = group(double & add_ten) & group(double & add_ten)  # ((10, 15), (10, 15))
```

### 2. Combinators & Fault Tolerance

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

assert (identity() & dbl)(7) == (7, 14)
assert ((inc & dbl) | select(1))(5) == 10
assert zip_tasks(inc, dbl)((3, 4)) == (4, 8)
assert branch(lambda x: x % 2 == 0, dbl, inc)(4) == 8
assert map_task(dbl, max_concurrency=4)([1, 2, 3, 4]) == [2, 4, 6, 8]

safe = fallback(retry(timeout(inc, seconds=1.0), max_attempts=3, backoff=0.01), dbl)
assert safe(10) == 11
```

### 3. GIL-Free Native Mojo Stages

Mix Python tasks with GIL-free Mojo stages that scale across CPU cores and fuse automatically across `|`:

```python
from strata import native_cpu_work, native_int_linear, spread, task

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

### 4. `async def` Tasks & Sliding-Window Streaming

```python
import asyncio
from strata import async_task

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

# Batch & bounded-backpressure streaming:
results = pipeline.map(["1", "2", "3", "4"], max_in_flight=4)
for item in pipeline.stream(["1", "2", "3", "4"], max_in_flight=4, ordered=False):
    print(item)
```

### 5. Introspection, Diagrams & Tracing

```python
from strata import SequentialExecutor, TracingExecutor

print(pipeline.stats())        # GraphStats(stage_count=4, max_parallel_width=2, critical_depth=3)
print(pipeline.to_mermaid())   # Mermaid flowchart
print(pipeline.to_dot())       # Graphviz DOT

assert SequentialExecutor().run(pipeline, "5") == "Branch 1: 10, Branch 2: 15"

tracer = TracingExecutor(sequential=False)
_ = tracer.run(pipeline, "5")
print(tracer.format_report())
```

---

## Further Reading

- [Root Usage Guide (`README.md`)](../README.md)
- [Python Hybrid, Async & Streaming Guide](../docs/python-hybrid-async-streaming.md)
- [Combinators & Resilience Guide](../docs/combinators-and-resilience.md)
- [Executors & Introspection Guide](../docs/executors-and-introspection.md)
- [Mojo Pipelines Guide](../docs/mojo-pipelines.md)
- [Design & Architecture (`DESIGN.md`)](../DESIGN.md)
