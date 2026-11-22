# Strata Design & Architecture

This document describes the internal architecture, type-system encoding, execution model, memory and error-handling invariants, and CPython/C-ABI interoperability of **Strata v2**.

For practical usage instructions and tutorials, see [README.md](README.md) and the topic guides under [`docs/`](docs/).

---

## Table of Contents

1. [Design Goals & Unified Operator Algebra](#1-design-goals--unified-operator-algebra)
2. [Repository & Module Layout](#2-repository--module-layout)
3. [Mojo Pipeline Engines & Memory Model](#3-mojo-pipeline-engines--memory-model)
4. [Pluggable Executors & Zero-Cost Tracing](#4-pluggable-executors--zero-cost-tracing)
5. [Python Extension (`mojo_strata.so`) & Hybrid Execution](#5-python-extension-mojo_strataso--hybrid-execution)
6. [`strata.native_stage.v1` PyCapsule C-ABI Specification](#6-stratanative_stagev1-pycapsule-c-abi-specification)
7. [`asyncio` Integration & Sliding-Window Backpressure](#7-asyncio-integration--sliding-window-backpressure)
8. [Performance & Hybrid Parallelism Benchmarks](#8-performance--hybrid-parallelism-benchmarks)

---

## 1. Design Goals & Unified Operator Algebra

Strata v2 unifies every Mojo and Python execution engine behind three composition primitives:

- **`a | b` (Sequential Pipe)**: Kleisli-like composition where `a.O == b.I` is verified statically (at compile time in Mojo, via PEP 695/646 generics in Python type checkers).
- **`a & b` (Associative Parallel Fan-Out)**: Broadcasts the shared input `I` to all branches inside **one flat `TaskGroup`** and collects outputs into a single flat tuple `(O1, O2, ..., On)`.
  - Associativity holds across left, right, and balanced trees: `((a & b) & c)`, `(a & (b & c))`, and `(a & b) & (c & d)` all collapse into a single `Parallel` node with one `TaskGroup` barrier rather than spawning nested `TaskGroup` trees.
- **`group(stage)` (Explicit Nesting Boundary)**: Wraps any stage in an opaque wrapper (`Group` / `OwnedGroup` / `RaisingGroup` / `AsyncGroup` in Mojo; `GroupedTask` in Python) whose `_IS_PARALLEL` marker is `False`, opting into nested tuple structure (`group(a & b) & group(c & d) -> ((O1, O2), (O3, O4))`) only when explicitly requested.

### How Associative Flattening Works in Mojo

Every stage trait (`Stage`, `FnTrait`, `AsyncFnTrait`, `FallibleStage`, `_MutCall`, `_AsyncMutCall`) defines `comptime _IS_PARALLEL: Bool = False`, overridden to `True` only on the flat variadic `Parallel` struct. Composition traits provide specialized `__and__` overloads:

1. `Stage & Stage -> Parallel[S1, S2]`
2. `Stage & Parallel[*R] -> Parallel[S1, *R]` (via `TypeList._concat`)
3. `Parallel[*L] & Stage -> Parallel[*L, S2]`
4. `Parallel[*L] & Parallel[*R] -> Parallel[*L, *R]`

Because `Group[Inner]` conforms to `ComposableStage` with `_IS_PARALLEL = False`, wrapping `group(a & b)` routes through overload (1), preserving its `Tuple[O1, O2]` output as a single element in outer parallel fan-outs.

---

## 2. Repository & Module Layout

```text
strata/
├── README.md                          # User-facing quickstart and usage guide
├── DESIGN.md                          # Architecture, runtime internals, C-ABI, benchmarks
├── docs/                              # Focused user guides
│   ├── mojo-pipelines.md
│   ├── combinators-and-resilience.md
│   ├── executors-and-introspection.md
│   └── python-hybrid-async-streaming.md
├── src/                               # Mojo package (`strata`)
│   ├── _internal/
│   │   └── runtime.mojo               # Single facade over std.runtime._asyncrt & placement intrinsics
│   ├── executors/
│   │   └── __init__.mojo              # Executor trait, AsyncRTExecutor, SequentialExecutor, BoundedExecutor, TracingExecutor
│   ├── pipeline/                      # Value-passing & unit pipelines
│   │   ├── __init__.mojo              # Stage, ComposableStage, Fn, UnitFn, Sequence, Parallel, Group, Owned*, run_with
│   │   ├── compt.mojo                 # Zero-sized comptime F[fn], Unit[fn], Id, Spread2..4, metrics, to_mermaid/to_dot
│   │   ├── combinators.mojo           # Id, Select, Spread2..4, Zip2..3, Map, OutputSink, stream_map, Branch
│   │   ├── async_fn.mojo              # AF[fn], Sync[fn], AsyncSequence, AsyncParallel, AsyncGroup
│   │   ├── fallible.mojo              # FallibleStage, RaisingFn, RaisingSequence, RaisingParallel, raising_group
│   │   └── resilience.mojo            # Retry, Fallback, Timeout, Recover
│   ├── stateful/                      # In-place `mut self` pipelines
│   │   ├── __init__.mojo              # MutStage, Series, flat Parallel (1 TaskGroup)
│   │   └── async_stage.mojo           # AsyncMutStage, AsyncSeries, flat AsyncParallel (1 TaskGroup)
│   └── interop/
│       ├── native_abi.mojo            # Public Mojo helpers for exporting strata.native_stage.v1 PyCapsules
│       └── python_interop.mojo        # CPython extension (mojo_strata.so): TaskGroup, NativeStage, plan fusion
├── python/                            # Python package (`strata`)
│   ├── hatch_build.py                 # Hatch build hook compiling python_interop.mojo -> mojo_strata.so
│   └── src/strata/
│       ├── graph.py                   # Combinable, Task, FnTask, GroupedTask, SerTaskGroup, ParTaskGroup
│       ├── combinators.py             # identity, select, spread, zip_tasks, map_task, branch, retry, fallback, timeout
│       ├── introspect.py              # GraphStats, to_mermaid, to_dot, SequentialExecutor, TracingExecutor
│       ├── native.py                  # NativeTask, native_stage, native_* kernels, runtime_info, is_gil_enabled
│       ├── async_support.py           # AsyncTask, async_task, native asyncio arun
│       ├── streaming.py               # map_stage, stream_stage, astream_stage with sliding-window backpressure
│       └── mojo_strata.pyi            # PEP 695/646 static type stubs for the native extension
├── examples/                          # Runnable Mojo & hybrid Python benchmark scripts
└── tests/                             # Mojo test suites & `mojo doc` completeness verification
```

### Comparison of Mojo Pipeline Engines

| Module | Representation | Heap Alloc | Ownership | Error Model | Async | `Executor` Support |
| :--- | :--- | :---: | :--- | :--- | :---: | :---: |
| `strata.pipeline` (borrowed) | `Pointer[S, origin]` | Zero | Immutable borrow (`ImmOrigin`) | Infallible | Sync | Yes |
| `strata.pipeline` (`owned`) | By-value structs | Zero | Owned (`Movable`) | Infallible | Sync | Yes |
| `strata.pipeline.compt` | Zero-sized types (ZST) | Zero | Stateless ZST | Infallible | Sync + `comptime` | Yes |
| `strata.pipeline.async_fn` | Zero-sized types (ZST) | Zero | Stateless ZST | Infallible | `__async def` | Direct `TaskGroup` |
| `strata.pipeline.fallible` | `Pointer[S, origin]` | Per-error msg | Immutable borrow (`ImmOrigin`) | `raises Error` | Sync | Direct `TaskGroup` |
| `strata.stateful` / `async_stage` | `_MutTaskRef` or owned | Zero | `MutOrigin` or owned | Infallible | Sync / `__async` | Direct `TaskGroup` |

---

## 3. Mojo Pipeline Engines & Memory Model

### Runtime Isolation (`src/_internal/runtime.mojo`)

Mojo's coroutine scheduler (`std.runtime._asyncrt.TaskGroup` and `_run`) and MLIR placement initialization intrinsic (`__mlir_op.`lit.ownership.mark_initialized``) are private stdlib/compiler surfaces. Strata confines them exclusively to `src/_internal/runtime.mojo` (`TaskGroup`, `run_coro`, and `uninitialized_storage[T]()`) so compiler upgrades never ripple across user-facing modules.

### Inline-Last `TaskGroup` Scheduling

Whenever a flat `Parallel` node with $N \ge 2$ branches executes on `TaskGroup`:

1. Branches $0 \dots N-2$ are spawned onto worker threads via `tg.create_task(...)`.
2. Branch $N-1$ executes **inline on the calling thread** before awaiting `tg`.

This avoids wasting a coroutine spawn and context switch for the final branch and ensures 2-way fan-outs (`a & b`) spawn only a single background task while utilizing both the caller thread and a worker thread concurrently.

### Placement Initialization & Leak-Free Unwinding for Non-Trivial `Movable` Types

Output tuples (`Tuple[*Outputs]`) and `List[O]` buffers in `Parallel`, `OwnedParallel`, `Zip2`/`Zip3`, `Map`, `stream_map`, `compt.Parallel`, `AsyncParallel`, and `RaisingParallel` support arbitrary `Movable & Deinitable` types (such as `String` and `List[T]`), including types that are neither `Defaultable` nor `Copyable`:

- Output storage is allocated uninitialized via `uninitialized_storage[Tuple[...]]()` (or `List[O](unsafe_uninit_length=n)`).
- Each parallel branch writes its result directly into its disjoint output slot via `Pointer(to=slot).unsafe_write(val^)`. Because branch indices are strictly disjoint, concurrent writes require no locks.
- **Exception safety in `RaisingParallel`**: Each branch tracks an initialized-bit flag alongside an optional error string. If one or more branches raise:
  - Every branch runs to completion before `tg` finishes (including catching any error from the inline final branch *before* awaiting `tg`).
  - Before re-raising (`Error` for a single failure, or `"Parallel stage failures (N): ..."` for multiple failures), `RaisingParallel` explicitly destroys (`unsafe_destroy_pointee`) only those tuple slots whose branches succeeded, preventing both double-frees on failed slots and memory leaks on succeeded slots.

### Compile-Time vs Runtime Parity (`strata.pipeline.compt`)

Mojo's compile-time interpreter cannot invoke `_asyncrt` thread-pool FFI calls. `strata.pipeline.compt` solves this by giving every `FnTrait` two execution entry points:

- `run_sequential(val)`: Purely synchronous evaluation used by `comptime_run[value]` and `SequentialExecutor`.
- `exec(val)` / `run(val)`: Concurrent `TaskGroup` evaluation at runtime.

Because stages in `compt` are pure functions, `diamond.comptime_run[x]` evaluates arbitrarily nested parallel diamonds and `group(...)` hierarchies at compile time while `diamond.run(x)` dispatches the exact same type-level DAG concurrently at runtime.

### Non-Blocking Coroutine Composition (`strata.pipeline.async_fn`)

`AsyncFnTrait` defines `@staticmethod __async def exec_async(in_ptr, out_ptr)` taking typed `Pointer`s rather than passing values across nested `run_coro` calls:

- Inner `AsyncParallel` and `AsyncSequence` nodes `cr_await` (`__await`) child coroutines directly on `TaskGroup` worker tasks instead of blocking OS worker threads inside nested synchronous `run_coro` barriers.
- Passing `in_ptr` and writing via `out_ptr.unsafe_write(...)` allows `Sync[fn]` and `AF[fn]` stages to accept and return non-trivial types (`Tuple`, `String`, `List`, custom structs) cleanly across suspension points.

### Dynamic Work-Stealing in `Map` and `stream_map`

- **`Map` (`map_stage`)**: Spawns `min(n, workers)` tasks in a single `TaskGroup` sharing an `Atomic[DType.int64]` cursor (`fetch_add(1)`). Workers dynamically steal items until the cursor reaches `n`, adapting to skewed per-item costs without per-item task-creation overhead.
- **`stream_map`**: Processes an input `List[I]` in bounded windows of size `max_in_flight`, writing each window into reusable slot storage and draining completed items in exact input order into an `OutputSink` (`on_item(mut self, var item: O)`), keeping peak output memory at $O(\text{max\_in\_flight})$.

---

## 4. Pluggable Executors & Zero-Cost Tracing

`strata.executors.Executor` exposes three compile-time constants alongside runtime hooks:

```mojo
trait Executor:
    comptime IS_PARALLEL: Bool
    comptime IS_TRACING: Bool = False
    comptime IS_BOUNDED: Bool = False
    ...
```

- **Compile-Time Dead-Code Elimination**: `Parallel.run_with` and `compt.Parallel.run_with` branch on `comptime if E.IS_PARALLEL`, `comptime if E.IS_TRACING`, and `comptime if E.IS_BOUNDED`. When running under `AsyncRTExecutor` (`IS_TRACING = False`, `IS_BOUNDED = False`), all timestamp calls (`perf_counter_ns()`) and wave-slicing loops compile away completely.
- **Lock-Free Parallel Span Recording**: `Executor` passes `mut exec: E` during sequential traversal, which cannot be mutably aliased across concurrent `TaskGroup` tasks. During parallel fan-out, `TracingExecutor` instead captures `(start_ns, end_ns)` timestamps into a stack/heap per-branch array inside the worker tasks and flushes them sequentially via `exec.record_span(name, start_ns, end_ns)` immediately after `tg.wait()`.
- **Python Executor Traversal**: Python's `SequentialExecutor` and `TracingExecutor` (`introspect.py`) recursively rewrite/instrument composite combinators (`MapTask`, `BranchTask`, `RetryTask`, `FallbackTask`, `TimeoutTask`, `ZipTask`, `GroupedTask`), guaranteeing that `SequentialExecutor` never spawns background threads even inside nested `map_task` or `zip_tasks` nodes.

---

## 5. Python Extension (`mojo_strata.so`) & Hybrid Execution

`src/interop/python_interop.mojo` compiles into the CPython extension module `strata.mojo_strata`.

### Copy-on-Write Immutability & Precomputed Execution Plans

Python `TaskGroup` instances are **strictly immutable**. `with_task(target, mode)` and `TaskGroup.from_tasks(tasks, mode)` construct a new `TaskGroup` and eagerly compile its execution plan once at composition time:

- **Plan Classification**:
  - `_PLAN_ALL_NATIVE`: Every step/branch is a GIL-free `NativeStage` (or fused chain of `NativeStage`s).
  - `_PLAN_ALL_PYTHON`: Every step/branch is a Python callable or nested non-native `TaskGroup`.
  - `_PLAN_HYBRID`: Mixes GIL-free native chains and Python callables in the same graph.
- **Automatic Serial Chain Fusion**: In serial mode (`|`), contiguous `NativeStage`s are merged into a single `_ENTRY_NATIVE_CHAIN` backed by a contiguous array of register-passable `_NativeOp` descriptors (containing raw function pointers and scalar coefficients, with zero `PythonObject` or `String` references).
  - Consecutive stages validate/widen scalar tags in registers (`Int64 -> Float64` widens automatically; `Float64 -> Int64` raises `TypeError` cleanly).
  - A 4-stage serial native chain executes in **~0.16 µs/call** (1 Python unbox, 1 `GILReleased` scope, 4 register-level C-ABI/inline ops, 1 Python box).

### GIL Lifecycle in Parallel & Hybrid Graphs

When a parallel `TaskGroup` (`&`) executes:

1. **All-Native Fast Path (`_PLAN_ALL_NATIVE`)**:
   - Unboxes the Python input once on the caller thread while holding the GIL.
   - Enters `with GILReleased():` and dispatches all native branches (including fused multi-stage native chains) across Mojo's `TaskGroup` worker pool (stack-allocated output buffer up to `_STACK_PAR_LIMIT = 16` branches, heap-allocated above 16).
   - Re-acquires the GIL after `tg` completes and packs results directly into a CPython tuple via `PyTuple_New` / `PyTuple_SetItem`.
2. **Hybrid Path (`_PLAN_HYBRID`)**:
   - Unboxes inputs for all native branches up front on the caller thread, then enters `with GILReleased():` across the Mojo `TaskGroup`.
   - Native branches run 100% GIL-free in parallel on worker threads; Python callable branches acquire `with GILAcquired():` only around their individual CPython call (`PyObject_CallOneArg` cached via `_CAPI_CACHE`).
3. **PEP 654 Exception Aggregation**:
   - Per-branch CPython exceptions are captured via `PyErr_GetRaisedException()` without aborting sibling tasks prematurely.
   - After `tg` synchronization: if 1 branch failed, that exact exception (preserving original traceback) is restored via `PyErr_SetRaisedException`; if $>1$ branches failed, Strata constructs and raises `ExceptionGroup` (or `BaseExceptionGroup` if any failure is a non-`Exception` `BaseException` such as `KeyboardInterrupt`).

### GIL-Free Batch Work-Stealing (`map_list`)

For any single `NativeStage` or any `TaskGroup` where `is_pure_native() == True`, `pipeline.map(...)` and `map_task(...)` bypass Python thread pools completely and invoke `map_list(items, max_concurrency)` in Mojo:

1. Unboxes the input sequence into a contiguous `NativeValue` buffer on the main thread.
2. Releases the GIL (`GILReleased`) and runs atomic work-stealing across `max_concurrency` Mojo `TaskGroup` workers.
3. Re-acquires the GIL and materializes the output Python `list`.

---

## 6. `strata.native_stage.v1` PyCapsule C-ABI Specification

External Mojo, C, C++, or Rust shared libraries can export GIL-free stages to Python Strata without linking against `mojo_strata.so` by returning a `PyCapsule` named `"strata.native_stage.v1"` pointing to a heap-allocated `NativeStageDescriptor`.

### C-Compatible Data Layout

```c
// Capsule name: "strata.native_stage.v1"

enum StrataNativeKind : int32_t {
    STRATA_NATIVE_KIND_INT64         = 0,
    STRATA_NATIVE_KIND_FLOAT64       = 1,
    STRATA_NATIVE_KIND_VALUE         = 2,
    STRATA_NATIVE_KIND_ARROW_FLOAT64 = 3,
    STRATA_NATIVE_KIND_ARROW_INT64   = 4,
};

enum StrataNativeValTag : int32_t {
    STRATA_NATIVE_VAL_INT64   = 0,
    STRATA_NATIVE_VAL_FLOAT64 = 1,
    STRATA_NATIVE_VAL_BOOL    = 2,
};

typedef struct StrataNativeValue {
    int32_t kind;       // StrataNativeValTag
    int32_t _pad;       // Explicit 8-byte alignment padding
    int64_t int_val;    // Used for INT64 and BOOL (0 or 1)
    double  float_val;  // Used for FLOAT64
} StrataNativeValue;    // 24 bytes

typedef int64_t (*StrataNativeIntFn)(int64_t x, void* ctx);
typedef double  (*StrataNativeFloatFn)(double x, void* ctx);
typedef int32_t (*StrataNativeValueFn)(
    const StrataNativeValue* input,
    StrataNativeValue* output,
    void* ctx
);
typedef int32_t (*StrataNativeArrowFloatFn)(
    const double* in_ptr,
    double* out_ptr,
    int64_t length,
    void* ctx
);
typedef int32_t (*StrataNativeArrowIntFn)(
    const int64_t* in_ptr,
    int64_t* out_ptr,
    int64_t length,
    void* ctx
);
typedef void (*StrataNativeCtxDeleter)(void* ctx);

typedef struct StrataNativeStageDescriptor {
    int32_t                kind;         // StrataNativeKind
    int32_t                _pad;         // Explicit 8-byte alignment padding
    void*                  fn_ptr;       // Function pointer matching `kind`
    void*                  ctx;          // Optional opaque user state (may be NULL)
    StrataNativeCtxDeleter ctx_deleter;  // Optional cleanup callback (may be NULL)
} StrataNativeStageDescriptor;
```

### ABI Contracts & Safety Invariants

- **GIL-Free Execution**: `fn_ptr` is invoked with the CPython GIL released, potentially concurrently from multiple Mojo worker threads. Implementations must be thread-safe and **must not** call CPython C-API functions without explicitly acquiring the GIL.
- **Status Codes (`NativeValueFn`)**: Returning `0` signals success; returning `_NATIVE_STATUS_OVERFLOW` (`-4`) raises Python `OverflowError`; any other non-zero status raises Python `RuntimeError`.
- **Strict Input Validation**: `bool` (`True`/`False`) is rejected with `TypeError` for `INT64` and `FLOAT64` stages (even though `bool` subclasses `int` in Python). Built-in integer linear kernels perform checked 64-bit arithmetic and raise `OverflowError` on signed 64-bit overflow.
- **Exception-Safe Capsule Destruction**: `strata.interop.native_abi._destroy_descriptor_capsule` saves and restores any active CPython exception (`PyErr_GetRaisedException` / `PyErr_SetRaisedException`) around `ctx_deleter` and descriptor deallocation so garbage collection during stack unwinding never clobbers an in-flight exception.
- **Apache Arrow C Data Interface (`__arrow_c_array__`) & GPU Device-Resident Chain Fusion**:
  - `mojo_strata.ArrowBuffer` and `strata.ArrowArray` implement the official Apache Arrow PyCapsule protocol (`"arrow_schema"` and `"arrow_array"` pointing to C-ABI `ArrowCSchema` and `ArrowCArray`). Exported `ArrowCArray` descriptors hold a strong `Py_IncRef` on the owning `ArrowBuffer` in `private_data` and release it in the C-ABI `release` callback.
  - On input, `_unbox_for_arrow` downcasts `strata.ArrowArray` / `mojo_strata.ArrowBuffer` in $O(1)$ without capsule allocation, or consumes any external `__arrow_c_array__()` provider (`pyarrow.Array`, `polars.Series`, `nanoarrow`, etc.) directly from `ArrowCArray.buffers[1]` (rejecting `null_count > 0` with `ValueError`).
  - When consecutive GPU float stages (`gpu_arrow_float_linear`, `gpu_arrow_float_poly`) are chained via `|`, `_run_gpu_arrow_float_chain` fuses them onto a single `max.gpu.host.DeviceContext` using two ping-pong `DeviceBuffer`s (`d_a`, `d_b`), copying host $\to$ device once at the start of the run and device $\to$ host once at the end.

---

## 7. `asyncio` Integration & Sliding-Window Backpressure

### Native `asyncio` Runner (`arun`)

`strata.async_support.arun` walks the pipeline AST natively on the caller's `asyncio` event loop:

- `AsyncTask` coroutines are awaited directly on the event loop with zero thread-switching overhead.
- Synchronous tasks and `NativeTask`s run via `asyncio.to_thread(...)` so blocking or CPU-heavy stages never stall the event loop.
- **Subtree Batching**: Any `TaskGroup` subtree containing zero `AsyncTask` descendants (`_contains_async_stage(tg) == False`) is offloaded as a **single** `asyncio.to_thread(tg.call, msg)` call rather than decomposing per stage, preserving Mojo `TaskGroup` concurrency and native serial chain fusion.
- Calling an `@async_task` synchronously (`stage(x)`) when an event loop is already active on the current thread automatically delegates `asyncio.run(...)` to a dedicated daemon worker thread to avoid nested-loop `RuntimeError`s.

### Bounded Sliding-Window Streaming (`stream` / `astream`)

`strata.streaming.stream_stage` and `astream_stage` maintain a strict sliding window of at most `max_in_flight` active items rather than wave barriers:

1. Initial prefill pulls at most `max_in_flight` items from the upstream iterator/generator.
2. Completed outputs are yielded **before** pulling the next upstream item, so an upstream iterator error never discards already-completed work and infinite generators never buffer unboundedly.
3. On early consumer `break` or mid-stream exception:
   - Upstream sync generators (`.close()`) and async generators (`.aclose()`) are closed immediately.
   - Sync thread pools unwind with `shutdown(wait=False, cancel_futures=True)` so slow in-flight threads do not block caller cleanup.
   - Async `astream` cancels and awaits all remaining in-flight `asyncio.Task`s so Python never emits `"Task exception was never retrieved"` warnings.
4. `TimeoutTask` in synchronous mode uses a lazily-initialized isolated daemon `ThreadPoolExecutor` rather than creating a fresh executor per call or sharing worker pools with `stream`/`map` (which could otherwise deadlock under nested timeouts).

---

## 8. Performance & Hybrid Parallelism Benchmarks

Measured with [`examples/benchmark_hybrid.py`](examples/benchmark_hybrid.py) on GIL-enabled CPython 3.15.2 (Apple Silicon, 8 CPUs):

| Workload | Sequential / Baseline | Parallel / Optimized | Speedup / Notes |
| :--- | :---: | :---: | :--- |
| Pure Python 4× 200k mixing iterations (`&`) | 121.33 ms | 119.31 ms | ~1.02× *(serialized by CPython GIL; scales on free-threaded `3.13t+`)* |
| GIL-Free Mojo `NativeStage` 4× 5M iterations (`&`) | 31.24 ms | 8.38 ms | **3.73×** *(true multi-core scaling on GIL-enabled CPython)* |
| Batch 32 items × 1M iterations (`map(max_in_flight=4)`) | 49.99 ms | 13.41 ms | **3.73×** *(GIL-free `map_list` work-stealing)* |
| Low-latency `NativeStage` 4-stage serial (`\|`) | — | **0.16 µs/call** | Single fused `GILReleased` pass over `_NativeOp` plan |
| Low-latency `MapTask` (4-stage native chain, 64 items) | — | **16.5 µs/call** | Single batch unbox + Mojo atomic work-stealing |

Reproduce on your hardware:

```bash
pixi run build_mojo_python
cd python && uv run python ../examples/benchmark_hybrid.py
```
