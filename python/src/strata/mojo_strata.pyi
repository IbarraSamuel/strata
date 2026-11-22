from collections.abc import Iterable
from typing import Any, Literal, Protocol, overload, type_check_only

@type_check_only
class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...

class NativeStage[I, O]:
    def call(self, v: I, /) -> O: ...
    def __call__(self, v: I, /) -> O: ...
    def get_name(self, /) -> str: ...
    def get_kind(self, /) -> str: ...
    def is_gil_free(self, /) -> bool: ...
    def map_list(self, items: Iterable[I], max_concurrency: int, /) -> list[O]: ...

def native_from_capsule(
    capsule: object, name: str, /
) -> NativeStage[object, object]: ...
def native_int_linear(scale: int, bias: int, name: str, /) -> NativeStage[int, int]: ...
def native_float_linear(
    scale: float, bias: float, name: str, /
) -> NativeStage[float, float]: ...
def native_float_poly(
    c0: float, c1: float, c2: float, name: str, /
) -> NativeStage[float, float]: ...
def native_cpu_work(iterations: int, name: str, /) -> NativeStage[int, int]: ...
def make_int_linear_capsule(scale: int, bias: int, /) -> object: ...

class TaskGroup[I, O]:
    @overload
    def __init__(
        self, task: Task[I, O] | TaskGroup[I, O] | NativeStage[I, O]
    ) -> None: ...
    @overload
    def __init__(self: TaskGroup[object, object], task: object) -> None: ...
    # Parallel Overload (flattening RHS parallel into LHS parallel, arities 2..4)
    @overload
    def with_task[*Os, T1, T2](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2]],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[*Os, T1, T2]]: ...
    @overload
    def with_task[*Os, T1, T2, T3](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2, T3]],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[*Os, T1, T2, T3]]: ...
    @overload
    def with_task[*Os, T1, T2, T3, T4](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2, T3, T4]],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[*Os, T1, T2, T3, T4]]: ...
    # Parallel Overload (left parallel + single stage)
    @overload
    def with_task[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        t: Task[I, T] | TaskGroup[I, T] | NativeStage[I, T],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[*Os, T]]: ...
    # Parallel Overload (single stage + right-hand parallel flattening)
    @overload
    def with_task[*Os](
        self,
        t: TaskGroup[I, tuple[*Os]],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[O, *Os]]: ...
    # Parallel Overload (pair)
    @overload
    def with_task[T](
        self,
        t: Task[I, T] | TaskGroup[I, T] | NativeStage[I, T],
        _mode: Literal[1],
        /,
    ) -> TaskGroup[I, tuple[O, T]]: ...
    # Sequential Overload
    @overload
    def with_task[T](
        self,
        t: Task[O, T] | TaskGroup[O, T] | NativeStage[O, T],
        _mode: Literal[0],
        /,
    ) -> TaskGroup[I, T]: ...
    def call(self, v: I, /) -> O: ...
    def get_mode(self, /) -> int: ...
    def get_tasks(self, /) -> list[object]: ...
    def is_pure_native(self, /) -> bool: ...
    def map_list(self, items: Iterable[I], max_concurrency: int, /) -> list[O]: ...
    @staticmethod
    def from_tasks(tasks: Iterable[object], mode: int, /) -> TaskGroup[Any, Any]: ...
