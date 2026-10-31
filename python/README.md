# Strata (Python)

Python bindings for **Strata**, a high-performance composable task graph runner powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

## Installation / Build

The native extension is built from Mojo sources using Pixi:

```bash
# Build the native C-extension
pixi run build_mojo_python
pixi run prepare_python
```

This places `mojo_strata.so` inside `src/strata/`.

## Quickstart

```python
from dataclasses import dataclass
from strata.graph import Combinable, Graph

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
    >> (Multiply(2) + Add(10))
    >> Merge()
    >> Graph()
)

print(pipeline("5"))  # "Branch 1: 10, Branch 2: 15"
```

## Composition Operators

- **`>>` (Serial)**: Pipes output from left task into input of right task.
- **`+` (Parallel)**: Dispatches tasks concurrently across threads with the same input, collecting outputs into a tuple.
- **`Graph.build(...)` / `... >> Graph()`**: Compiles unbuilt task groups into a callable `BuildedGraph`.

See the root [README.md](../../README.md) for full project documentation and Mojo usage.
