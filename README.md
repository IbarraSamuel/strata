# Strata

**Strata** is a high-performance, composable task graph execution framework for **Mojo** and **Python**, powered by Mojo's native asynchronous runtime (`TaskGroup` / `_asyncrt`).

Strata provides an intuitive, operator-driven API for constructing complex dependency and workflow graphs:
- **`>>` (Serial / Sequential Pipeline)**: Pipes the output of one task directly as the input to the next.
- **`+` (Parallel Fan-Out)**: Dispatches multiple tasks concurrently with the same input, collecting their outputs into a strongly-typed tuple.

---

## Table of Contents

- [Installation](#installation)
- [Features](#features)
- [Project Architecture](#project-architecture)
- [Using Strata from Mojo](#using-strata-from-mojo)
  - [1. Function-Based Pipelines (`generic.Fn`)](#1-function-based-pipelines-genericfn)
  - [2. Struct-Based Tasks (`generic.Callable`)](#2-struct-based-tasks-genericcallable)
  - [3. Combining Sequential and Parallel Stages](#3-combining-sequential-and-parallel-stages)
  - [4. In-Place Mutable Pipelines (`void.mutable`)](#4-in-place-mutable-pipelines-voidmutable)
  - [5. Async Task Execution (`generic.async_fn`)](#5-async-task-execution-genericasync_fn)
- [Using Strata from Python](#using-strata-from-python)
  - [1. Building the Python Extension](#1-building-the-python-extension)
  - [2. Defining Tasks (`Combinable`)](#2-defining-tasks-combinable)
  - [3. Sequential Pipelines (`>>`)](#3-sequential-pipelines-)
  - [4. Parallel Pipelines (`+`)](#4-parallel-pipelines-)
  - [5. Mixed Pipelines & Compilation (`Graph.build`)](#5-mixed-pipelines--compilation-graphbuild)
- [Development and Testing](#development-and-testing)
- [License](#license)

---

## Installation

### Mojo

Clone the repository and let Pixi install the Mojo compiler and build Strata's
Mojo package into the project environment:

```bash
git clone https://github.com/IbarraSamuel/strata.git
cd strata
pixi install
```

Run Mojo commands from the repository with `pixi run mojo ...`. The Pixi package
also declares `mojo-compiler` as a runtime dependency.

To use Strata from another Pixi project, add this GitHub repository as a Pixi
Git dependency. The consuming project needs the same channels and the
`pixi-build` preview enabled so Pixi can build Strata:

```bash
pixi workspace preview add pixi-build
pixi workspace channel add https://prefix.dev/max-nightly https://prefix.dev/conda-forge
pixi add strata --git https://github.com/IbarraSamuel/strata.git
pixi install
```

Then import Strata in Mojo code as usual:

```mojo
from strata import generic
```

By default, Pixi uses the repository's default branch. To pin a branch, tag, or
commit, use `--branch <branch>`, `--tag <tag>`, or `--rev <commit>` with
`pixi add`.

### Python

Install directly from the `python/` subdirectory of this GitHub repository with
either pip or uv:

```bash
python -m pip install "git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
uv pip install "git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

To add it as a dependency to a uv project instead:

```bash
uv add "strata @ git+https://github.com/IbarraSamuel/strata.git#subdirectory=python"
```

These Python install commands build the native Mojo extension during
installation and install Mojo as a Python dependency. Mojo's Linux wheels
require glibc 2.34 or newer.

---

## Features

- **Intuitive Operator Composition**: Chain stages with `>>` and fan-out with `+` for clean, expressive pipeline topologies.
- **Native Mojo Performance**: Zero-overhead generic dispatch backed by compile-time trait conformance and Mojo's multithreaded async runtime.
- **Automatic Tuple Expansion**: Combining parallel outputs flattens results into clean tuples (`Tuple[O1, O2, O3]`), avoiding nested tuple ergonomics.
- **In-Place Mutation Support**: Dedicated `void` pipeline modules for high-throughput zero-copy buffer transformations.
- **Full Python Interoperability**: Write high-level graphs in Python using `@dataclass` and `Combinable` while executing compute stages concurrently in native Mojo with GIL-safe execution.

---

## Project Architecture

```text
strata/
├── src/                          # Mojo source modules
│   ├── generic/                  # Generic, value-returning pipeline runners
│   │   ├── __init__.mojo         # Core Callable trait, Fn, Sequence (>>), Parallel (+)
│   │   ├── async_fn.mojo         # Async function execution via TaskGroup
│   │   └── compt.mojo            # Compile-time task groups and execution
│   ├── void/                     # Void-returning (in-place) pipeline runners
│   │   ├── immutable.mojo        # Read-only void pipelines
│   │   ├── mutable.mojo          # Mutable reference & pointer transformation pipelines
│   │   ├── async_immutable.mojo  # Async immutable task execution
│   │   ├── async_mutable.mojo    # Async mutable task execution
│   │   └── type.mojo             # Type-based void pipelines
│   └── interop/                  # CPython extension module builder
│       └── python_interop.mojo   # Exports TaskGroup to Python (mojo_strata.so)
├── python/                       # Python bindings and package
│   ├── src/strata/               # strata Python package
│   │   ├── graph.py              # Combinable, Task, Graph, and BuildedGraph
│   │   └── mojo_strata.so        # Compiled native extension
│   └── tests/                    # pytest test suite
└── tests/                        # Modular Mojo test suites
```

---

## Using Strata from Mojo

Import `generic` from `strata` to access the core generic pipeline abstractions:

```mojo
from strata import generic
```

### 1. Function-Based Pipelines (`generic.Fn`)

Wrap standard Mojo functions with `generic.Fn` to enable operator composition:

```mojo
from strata import generic

def string_to_int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0

def double_val(x: Int) -> Int:
    return x * 2

def to_string(x: Int) -> String:
    return String(x)

def main() raises:
    var stoi = generic.Fn(string_to_int)
    var dbl = generic.Fn(double_val)
    var tos = generic.Fn(to_string)

    # Chain sequentially with >>
    var pipeline = stoi >> dbl >> tos

    var result = pipeline("21")
    print(result)  # "42"
```

### 2. Struct-Based Tasks (`generic.Callable`)

For stateful tasks or parameterized stages, define a struct conforming to `generic.Callable`:

```mojo
from strata import generic

@fieldwise_init
struct MultiplyTask[factor: Int](generic.Callable):
    comptime I = Int
    comptime O = Int

    def __call__(self, arg: Self.I) -> Self.O:
        return arg * Self.factor

@fieldwise_init
struct AddOffsetTask(generic.Callable):
    comptime I = Int
    comptime O = Int

    var offset: Int

    def __call__(self, arg: Self.I) -> Self.O:
        return arg + self.offset
```

### 3. Combining Sequential and Parallel Stages

Use `+` to run multiple tasks concurrently across threads. When tasks execute in parallel, they receive identical input and their results are bundled into a tuple:

```mojo
from strata import generic

def int_to_float(v: Int) -> Float32:
    return Float32(v)

def int_triple(v: Int) -> Int:
    return v * 3

def sum_results(pair: Tuple[Float32, Int]) -> Float32:
    return pair[0] + Float32(pair[1])

def main() raises:
    var itof = generic.Fn(int_to_float)
    var trip = generic.Fn(int_triple)
    var merge = generic.Fn(sum_results)

    # Fan out in parallel (+), then fan in (>>)
    var graph = (itof + trip) >> merge

    var out = graph(10)
    print(out)  # 10.0 + 30 = 40.0
```

Pipelines can be arbitrarily chained:
```mojo
var complex_pipeline = (
    StringToIntTask()
    >> (IntMulTask[2]() + IntToFloatTask() + IntMulTask[3]())
    >> SumTuple()
    >> FloatToStringTask()
)
```

### 4. In-Place Mutable Pipelines (`void.mutable`)

When operating on large data buffers in-place without copying, use `strata.void.mutable`:

```mojo
from strata.void.mutable import MutRefTask, MutVarTask

# Compose in-place reference mutations sequentially or in parallel
var pipeline = task1 >> task2 + task3
pipeline(data_buffer)
```

### 5. Async Task Execution (`generic.async_fn`)

For asynchronous functions executing concurrently within a Mojo runtime `TaskGroup`:

```mojo
from strata.generic.async_fn import par_fn

__async def fetch_a(id: Int) -> Float32: ...
__async def fetch_b(id: Int) -> Int: ...

def main() raises:
    var results = par_fn[fetch_a, fetch_b](42)
    # results is Tuple[Float32, Int]
```

---

## Using Strata from Python

Strata exposes a native Python interface via `mojo_strata.so`, allowing you to construct and execute task graphs directly in Python while leveraging the Mojo async runtime engine under the hood.

### 1. Building the Python Extension

Installing the Python package from the `python/` directory builds the native
shared library automatically:

```bash
python -m pip install ./python
```

Mojo is installed as a Python dependency and compiles
`src/interop/python_interop.mojo` to `python/src/strata/mojo_strata.so` during
the package build.

### 2. Defining Tasks (`Combinable`)

Inherit from `Combinable` to give any callable task support for `>>` and `+`:

```python
from dataclasses import dataclass
from strata.graph import Combinable

@dataclass
class Multiply(Combinable):
    factor: int

    def __call__(self, value: int) -> int:
        return value * self.factor

@dataclass
class FormatMessage(Combinable):
    prefix: str

    def __call__(self, value: int) -> str:
        return f"{self.prefix}: {value}"
```

### 3. Sequential Pipelines (`>>`)

Pipes output from left to right:

```python
from strata.graph import Graph

step1 = Multiply(3)
step2 = FormatMessage("Calculated")

# Build and execute sequentially
graph = Graph.build(step1 >> step2)
# Alternatively: (step1 >> step2 >> Graph())(10)

result = graph(10)
print(result)  # "Calculated: 30"
```

### 4. Parallel Pipelines (`+`)

Dispatches tasks concurrently via native Mojo threads. Results are packed into a tuple:

```python
from time import sleep
from dataclasses import dataclass
from strata.graph import Combinable, Graph

@dataclass
class FetchPrice(Combinable):
    def __call__(self, ticker: str) -> float:
        sleep(0.1)  # Simulate I/O or work
        return 150.0

@dataclass
class FetchVolume(Combinable):
    def __call__(self, ticker: str) -> int:
        sleep(0.1)
        return 10_000

# Both tasks run concurrently in Mojo's async runtime
parallel_stage = FetchPrice() + FetchVolume()
graph = Graph.build(parallel_stage)

price, volume = graph("AAPL")
print(f"Price: {price}, Volume: {volume}")
```

### 5. Mixed Pipelines & Compilation (`Graph.build`)

Combine sequential and parallel stages seamlessly into a single compiled DAG:

```python
from dataclasses import dataclass
from strata.graph import Combinable, Graph

@dataclass
class ParseInput(Combinable):
    def __call__(self, raw: str) -> int:
        return int(raw)

@dataclass
class ComputeBranchA(Combinable):
    def __call__(self, x: int) -> int:
        return x * 2

@dataclass
class ComputeBranchB(Combinable):
    def __call__(self, x: int) -> int:
        return x + 10

@dataclass
class Aggregate(Combinable):
    def __call__(self, values: tuple[int, int]) -> str:
        a, b = values
        return f"Sum of branches: {a + b}"

# Build the pipeline: Parse -> [BranchA || BranchB] -> Aggregate
pipeline = (
    ParseInput()
    >> (ComputeBranchA() + ComputeBranchB())
    >> Aggregate()
    >> Graph()  # Compile into BuildedGraph
)

print(pipeline("5"))  # "Sum of branches: 20"
```

---

## Development and Testing

The repository uses [Pixi](https://pixi.sh) to manage Mojo and Python development environments.

### Available Tasks

```bash
# Run the complete test suite (Mojo test runners, Python pytest, docs check)
pixi run tests

# Run all Mojo test runners
pixi run test_runners

# Run specific Mojo module tests
pixi run test_generic
pixi run test_generic_compt
pixi run test_generic_async
pixi run test_void_mutable
pixi run test_void_immutable

# Run Python tests (rebuilds mojo_strata.so before pytest)
pixi run python_test

# Validate docstring completeness for all Mojo source files
pixi run test_docs
```

---

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.
