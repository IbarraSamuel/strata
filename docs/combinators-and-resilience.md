# Dataflow & Resilience Combinators Guide

Strata v2 ships a rich library of composable dataflow and fault-tolerance combinators in both **Mojo** (`strata.pipeline.combinators`, `strata.pipeline.resilience`, and `strata.pipeline.compt`) and **Python** (`strata`). Every combinator conforms to `ComposableStage` / `ComposableFallibleStage` (Mojo) or `Combinable` (Python), so it plugs seamlessly into `|` and `&`.

---

## Quick Reference

| Combinator | Signature / Behavior | Mojo | Python |
| :--- | :--- | :--- | :--- |
| Identity | `T -> T` pass-through | `identity[T]()` / `Id[T]` | `identity()` / `IdTask` |
| Projection | `Tuple[*Ts] -> Ts[Idx]` | `select[Idx, *Ts]()` / `Select` | `select(index)` / `SelectTask` |
| Tuple Unpack | `Tuple[A, B, ...] -> O` | `spread(fn)` / `Spread2..4` | `@spread` / `SpreadTask` |
| Parallel Product | `(I1, I2, ...) -> (O1, O2, ...)` | `zip_stages(s1, s2[, s3])` / `Zip2..3` | `zip_tasks(s1, s2, ...)` / `ZipTask` |
| Dynamic Parallel Map | `List[I] -> List[O]` | `map_stage(s, max_concurrency=0)` / `Map` | `map_task(s, max_concurrency=0)` / `MapTask` |
| Bounded Stream Map | Windowed `O(max_in_flight)` sink | `stream_map(s, items, max_in_flight, sink)` | `pipe.stream(...)` / `pipe.astream(...)` |
| Conditional Branch | Route `I -> O` by predicate | `branch(pred, on_true, on_false)` | `branch(pred, on_true, on_false)` |
| Retry | Retry with exponential backoff | `retry(stage, max_attempts, backoff_secs, backoff_multiplier)` | `retry(stage, max_attempts, backoff, backoff_multiplier, retry_on)` |
| Fallback | Run secondary if primary fails | `fallback(primary, secondary)` | `fallback(primary, secondary, catch)` |
| Timeout | Wall-clock deadline guard | `timeout(stage, timeout_secs)` *(cooperative)* | `timeout(stage, seconds)` *(preemptive thread / asyncio)* |
| Recover | Bridge `FallibleStage` → `ComposableStage` | `recover(stage, handler)` | *(use `fallback`)* |

---

## 1. Dataflow Combinators

### Identity (`identity` / `Id`)

Passes its input through unchanged. Especially useful inside `&` fan-outs when you want to preserve the original value alongside derived results (`(identity & transform)`).

**Mojo:**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import identity

def double_val(x: Int) -> Int: return x * 2

def main():
    var keep = identity[Int]()
    var dbl = Fn(double_val)
    var pipe = keep & dbl
    var out = pipe(7)  # (7, 14)
```

**Python:**
```python
from strata import identity, task

@task
def double(x: int) -> int:
    return x * 2

pipe = identity() & double
assert pipe(7) == (7, 14)
```

---

### Select (`select` / `Select`)

Extracts element `index` from a tuple produced by `&` or `zip_tasks`/`zip_stages`.

**Mojo:**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import select

def inc(x: Int) -> Int: return x + 1
def to_str(x: Int) -> String: return String("v=", x)

def main():
    var s1 = Fn(inc)
    var s2 = Fn(to_str)
    var pick_str = select[1, Int, String]()
    var pipe = (s1 & s2) | pick_str
    print(pipe(9))  # "v=9"
```

**Python:**
```python
from strata import select, task

@task
def inc(x: int) -> int:
    return x + 1

@task
def label(x: int) -> str:
    return f"v={x}"

pipe = (inc & label) | select(1)
assert pipe(9) == "v=9"
```

---

### Spread (`spread` / `Spread2`–`Spread4` / `SpreadTask`)

Unpacks a tuple emitted by `&` or `zip_*` into positional arguments of a multi-argument function, eliminating boilerplate tuple-indexing glue.

**Mojo (runtime & compile-time):**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import spread

def a(x: Int) -> Int: return x + 1
def b(x: Int) -> Int: return x * 2
def c(x: Int) -> Int: return x * 3
def combine3(x: Int, y: Int, z: Int) -> Int: return x + y + z

def main():
    var f1 = Fn(a)
    var f2 = Fn(b)
    var f3 = Fn(c)
    var merge = spread(combine3)  # Spread3: Tuple[Int, Int, Int] -> Int
    var pipe = (f1 & f2 & f3) | merge
    print(pipe(4))  # 5 + 8 + 12 = 25
```

> **Compile-time variant:** `strata.pipeline.compt` provides zero-sized `Spread2[fn]`, `Spread3[fn]`, and `Spread4[fn]` compatible with `comptime_run` and `to_mermaid()`.

**Python:**
```python
from strata import spread, task

@task
def double(x: int) -> int:
    return x * 2

@task
def add_ten(x: int) -> int:
    return x + 10

@spread
def format_sum(a: int, b: int) -> str:
    return f"{a} + {b} = {a + b}"

pipe = (double & add_ten) | format_sum
assert pipe(5) == "10 + 15 = 25"
```

---

### Parallel Product (`zip_stages` / `zip_tasks`)

Whereas `&` broadcasts the **same** input `I` to all branches (`I -> (O1, O2)`), `zip_*` applies each stage concurrently to its **corresponding element** of an input tuple (`(I1, I2, ...) -> (O1, O2, ...)`).

**Mojo:**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import zip_stages

def square(x: Int) -> Int: return x * x
def shout(s: String) -> String: return s + "!"

def main():
    var s1 = Fn(square)
    var s2 = Fn(shout)
    var zipped = zip_stages(s1, s2)
    var out = zipped((6, String("go")))  # (36, "go!")
```

**Python:**
```python
from strata import task, zip_tasks

@task
def square(x: int) -> int:
    return x * x

@task
def shout(s: str) -> str:
    return f"{s}!"

zipped = zip_tasks(square, shout)
assert zipped((6, "go")) == (36, "go!")
```

---

### Dynamic Parallel Map (`map_stage` / `map_task`)

Lifts a stage `I -> O` into a composable `List[I] -> List[O]` (`Sequence[I] -> list[O]`) stage. In Mojo, `Map` uses a single `TaskGroup` with zero-copy `unsafe_write` storage and atomic work-stealing across `max_concurrency` workers (`0` = unbounded). In Python, `map_task` automatically dispatches pure-native Mojo stages (`NativeTask`, `NativeStage`, pure-native `TaskGroup`) to GIL-free Mojo work-stealing `map_list`, and uses O(N) `TaskGroup.from_tasks` waves for general Python stages.

**Mojo:**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import map_stage

def triple(x: Int) -> Int: return x * 3

def main():
    var s = Fn(triple)
    var mapped = map_stage(s, max_concurrency=4)
    var items: List[Int] = [1, 2, 3, 4, 5, 6]
    var out = mapped(items)  # [3, 6, 9, 12, 15, 18]
```

**Python:**
```python
from strata import map_task, task

@task
def triple(x: int) -> int:
    return x * 3

mapped = map_task(triple, max_concurrency=4)
assert mapped([1, 2, 3, 4, 5, 6]) == [3, 6, 9, 12, 15, 18]
```

### Bounded-Memory Streaming Map in Mojo (`stream_map` & `OutputSink`)

When processing large batches in Mojo where buffering all outputs in one `List[O]` is undesirable, `stream_map` executes windows of at most `max_in_flight` concurrent tasks and delivers completed outputs in input order to an `OutputSink`:

```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import OutputSink, stream_map

def double_val(x: Int) -> Int: return x * 2

struct SumSink(OutputSink):
    comptime Item = Int
    var total: Int

    def __init__(out self):
        self.total = 0

    def on_item(mut self, var item: Int):
        self.total += item

def main():
    var stage = Fn(double_val)
    var items: List[Int] = [1, 2, 3, 4, 5]
    var sink = SumSink()
    stream_map(stage, items, max_in_flight=2, sink=sink)
    print(sink.total)  # 30
```

> For Python's sliding-window `pipeline.stream(...)`, `pipeline.map(...)`, and `pipeline.astream(...)`, see [Python Hybrid, Async & Streaming](python-hybrid-async-streaming.md).

---

### Conditional Branching (`branch` / `Branch` / `BranchTask`)

Evaluates a predicate on the input and routes execution to `on_true` or `on_false` (both must share input type `I` and output type `O`).

**Mojo:**
```mojo
from strata.pipeline import Fn
from strata.pipeline.combinators import branch

def is_even(x: Int) -> Bool: return x % 2 == 0
def halve(x: Int) -> Int: return x // 2
def triple_plus_one(x: Int) -> Int: return 3 * x + 1

def main():
    var even_s = Fn(halve)
    var odd_s = Fn(triple_plus_one)
    var collatz = branch(is_even, even_s, odd_s)
    print(collatz(10), collatz(7))  # 5 22
```

**Python:**
```python
from strata import branch, task

@task
def halve(x: int) -> int:
    return x // 2

@task
def triple_plus_one(x: int) -> int:
    return 3 * x + 1

collatz = branch(lambda x: x % 2 == 0, halve, triple_plus_one)
assert collatz(10) == 5
assert collatz(7) == 22
```

---

## 2. Resilience Combinators

### Retry (`retry` / `Retry` / `RetryTask`)

Retries a failing stage up to `max_attempts` with optional exponential backoff.

**Mojo (`strata.pipeline.resilience`):**
```mojo
from strata.pipeline.fallible import RaisingFn
from strata.pipeline.resilience import retry

def flaky_parse(s: String) raises -> Int:
    return Int(s)

def main() raises:
    var stage = RaisingFn(flaky_parse)
    var safe = retry(stage, max_attempts=3, backoff_secs=0.01, backoff_multiplier=2.0)
    print(safe("42"))
```

**Python (`strata`):**
```python
from strata import retry, task

@task
def call_api(url: str) -> str:
    ...

resilient = retry(
    call_api,
    max_attempts=4,
    backoff=0.05,
    backoff_multiplier=2.0,
    retry_on=(ConnectionError, TimeoutError),
)
```

---

### Fallback (`fallback` / `Fallback` / `FallbackTask`)

Attempts `primary`; if it raises (a matching exception in Python, or any `Error` in Mojo), executes `secondary` on the same input.

**Mojo:**
```mojo
from strata.pipeline.fallible import RaisingFn
from strata.pipeline.resilience import fallback

def primary_parse(s: String) raises -> Int: return Int(s)
def default_zero(s: String) raises -> Int: return 0

def main() raises:
    var p = RaisingFn(primary_parse)
    var s = RaisingFn(default_zero)
    var fb = fallback(p, s)
    print(fb("not-a-number"))  # 0
```

**Python:**
```python
from strata import fallback, task

@task
def parse_strict(s: str) -> int:
    return int(s)

@task
def default_zero(_s: str) -> int:
    return 0

safe_parse = fallback(parse_strict, default_zero, catch=(ValueError,))
assert safe_parse("abc") == 0
```

---

### Timeout (`timeout` / `Timeout` / `TimeoutTask`)

Guards a stage against exceeding a wall-clock deadline.

- **Mojo (`strata.pipeline.resilience.timeout`)**: Cooperative post-execution check — measures elapsed monotonic nanoseconds around `inner(arg)` and raises `Error` if `elapsed_ns > timeout_ns`. (Mojo's `TaskGroup` does not preemptively kill running tasks.)
- **Python (`strata.timeout`)**: Enforces a wall-clock `TimeoutError` using a lazily-initialized isolated daemon `ThreadPoolExecutor` in sync mode (avoiding per-call thread creation and preventing deadlocks with `stream`/`map` pools), or `asyncio.wait_for` inside `arun(...)`.

**Mojo:**
```mojo
from strata.pipeline.fallible import RaisingFn
from strata.pipeline.resilience import timeout

def work(x: Int) raises -> Int: return x * 2

def main() raises:
    var s = RaisingFn(work)
    var guarded = timeout(s, timeout_secs=0.5)
    print(guarded(21))  # 42
```

**Python:**
```python
from strata import task, timeout

@task
def slow_query(key: str) -> str:
    ...

guarded = timeout(slow_query, seconds=1.5)
```

---

### Recover (`recover` / `Recover` — Mojo Only)

Bridges any `FallibleStage` (`strata.pipeline.fallible` / `strata.pipeline.resilience`) into an infallible `ComposableStage` (`strata.pipeline`), allowing fallible sub-pipelines to compose directly with non-raising stages via `|` and `&`.

```mojo
from strata.pipeline import Fn
from strata.pipeline.fallible import RaisingFn
from strata.pipeline.resilience import recover, retry

def parse_int(s: String) raises -> Int:
    return Int(s)

def on_error(raw: String, err_msg: String) -> Int:
    return -1

def double_val(x: Int) -> Int:
    return x * 2

def main():
    var parser = RaisingFn(parse_int)
    var retried = retry(parser, max_attempts=2)
    var safe = recover(retried, on_error)
    var dbl = Fn(double_val)

    # `safe` is now a standard infallible ComposableStage!
    var pipe = safe | dbl
    print(pipe("21"))   # 42
    print(pipe("bad"))  # -2
```

---

## Edge Cases & Behavioral Guarantees

- **`Map` / `MapTask` & `stream_map` boundaries**:
  - Empty inputs (`n = 0`) return an empty list / invoke zero sink callbacks; single-element inputs (`n = 1`) bypass `TaskGroup` creation.
  - `max_concurrency = 1` (or `max_in_flight <= 1` in `stream_map`) uses a fast sequential path.
  - `max_concurrency > len(items)` executes in a single parallel wave; non-divisible wave sizes handle the partial final wave while preserving exact input order.
- **`ZipTask` (Python)**: Rejects 0 stages with `ValueError`; supports 1 stage (`(x,) -> (f(x),)`), 2, 3, and 4+ stages. Input length is strictly validated (`len(seq) == len(stages)` -> `ValueError` on mismatch) before dispatching or creating coroutines, preventing silent truncation and unawaited coroutine warnings.
- **`Retry` / `RetryTask`**:
  - `max_attempts <= 0` clamps to `1` (a single attempt with no retries); `max_attempts = 1` never retries.
  - Succeeding on the exact final attempt returns that result cleanly.
  - Both Mojo and Python cap exponential retry delay at `86_400.0` seconds (24 hours) to prevent `sleep(+inf)` overflow. Python rejects non-finite (`NaN` / `±inf`) `backoff` or `backoff_multiplier` with `ValueError`.
  - In Python, exceptions not matching `retry_on` are re-raised immediately without retrying.
- **`Fallback` / `FallbackTask`**:
  - When `primary` succeeds, `secondary` is guaranteed **not** to be called.
  - When both `primary` and `secondary` fail, `secondary`'s error propagates.
  - In Python, exceptions not matching `catch` bypass `secondary` and propagate immediately.
- **`Timeout` / `TimeoutTask`**:
  - In Mojo, `timeout_secs <= 0`, `-inf`, and `NaN` clamp `timeout_ns` to `0` (raising on any non-zero elapsed execution time), while values `>= 9_223_372_036.0` (including `+inf`) clamp safely to `Int.MAX` (no `fptosi` UB).
  - In Python, non-finite (`NaN` / `±inf`) or `<= 0` `seconds` raises `ValueError` at construction time. Non-timeout exceptions raised by the inner stage propagate cleanly.
- **`Recover` (Mojo)**: Passes `(input, error_message)` to `handler` only when the wrapped `FallibleStage` raises; bypasses `handler` completely on success.

