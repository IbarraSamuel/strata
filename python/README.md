# Strata (Python)

Python bindings for **Strata**, a high-performance composable task graph runner powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

## Installation / Build

Install the Python package from this directory:

```bash
python -m pip install .
```

The package build installs Mojo as a Python build dependency and compiles
`mojo_strata.so` from the repository's Mojo sources during installation. Mojo is
also installed as a runtime dependency.
On Linux, the Mojo wheels require glibc 2.34 or newer.

For development, run the tests with the build tools available in the active
environment:

```bash
uv run --no-build-isolation --reinstall-package strata --group dev --group test pytest
```

## Quickstart

Pipelines are directly callable—no graph compiler or wrapper needed:

```python
from dataclasses import dataclass
from strata.graph import Combinable

@dataclass
class ParseInput(Combinable):
    def __call__(self, text: str) -> int:
        return int(text)

@dataclass
class Multiply(Combinable):
    factor: int

    def __call__(self, x: int) -> int:
        return x * self.factor

@dataclass
class Add(Combinable):
    offset: int

    def __call__(self, x: int) -> int:
        return x + self.offset

@dataclass
class Merge(Combinable):
    def __call__(self, pair: tuple[int, int]) -> str:
        return f"Branch 1: {pair[0]}, Branch 2: {pair[1]}"

# Pipeline: Parse -> (Multiply || Add) -> Merge
pipeline = (
    ParseInput()
    | (Multiply(2) & Add(10))
    | Merge()
)

# Pipelines are directly callable!
print(pipeline("5"))  # "Branch 1: 10, Branch 2: 15"
```

## Composition Operators

- **`|` (Pipe / Stream)**: Pipes output from left task into input of right task.
- **`&` (Parallel Fan-Out)**: Dispatches tasks concurrently across threads with the same input, collecting outputs into a tuple.

See the root [README.md](../../README.md) for full project documentation and Mojo usage.
