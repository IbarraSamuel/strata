# Strata (Python)

Python bindings for **Strata v2**, a high-performance composable task graph runner powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

## Installation / Build

```bash
python -m pip install .
```

The package build installs Mojo as a Python build dependency and compiles `mojo_strata.so` automatically during installation. On Linux, Mojo wheels require glibc 2.34+.

For development:

```bash
uv sync --no-install-project --group dev --group test
uv run --no-build-isolation --reinstall-package strata --group dev --group test pytest
```

## Quickstart

Pipelines are immutable, strictly typed (PEP 695/646), and directly callable:

```python
from strata import group, task

@task
def parse_int(text: str) -> int:
    return int(text)

@task
def double(x: int) -> int:
    return x * 2

@task
def add_ten(x: int) -> int:
    return x + 10

@task
def merge(pair: tuple[int, int]) -> str:
    return f"Branch 1: {pair[0]}, Branch 2: {pair[1]}"

pipeline = parse_int | (double & add_ten) | merge
print(pipeline("5"))  # "Branch 1: 10, Branch 2: 15"

# Parallel fan-outs flatten associatively; use `group(...)` for nested tuples:
flat = (double & add_ten) & (double & add_ten)              # (10, 15, 10, 15)
nested = group(double & add_ten) & group(double & add_ten)  # ((10, 15), (10, 15))
```

## Composition Operators & Error Propagation

- **`|` (Pipe / Sequence)**: Pipes output from left stage into input of right stage without mutating existing stages.
- **`&` (Parallel Fan-Out)**: Dispatches tasks concurrently in a single flat `TaskGroup`, flattening associatively into a flat tuple.
- **`group(...)`**: Wraps a parallel stage to preserve nested tuple structure under `&`.
- **Exception Propagation**: Single-branch failures re-raise the exact original Python exception and traceback; multi-branch parallel failures raise a PEP 654 `ExceptionGroup`.

See the root [README.md](../README.md) for Mojo usage and architecture details.
