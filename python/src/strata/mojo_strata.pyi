from typing import Literal, Protocol, overload, type_check_only

@type_check_only
class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...

class TaskGroup[I, O]:
    def __init__(self, task: Task[I, O]) -> None: ...
    # Parallel Overload (flattening RHS parallel into LHS parallel, arities 2..4)
    @overload
    def with_task[*Os, T1, T2](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2]],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[*Os, T1, T2]]: ...
    @overload
    def with_task[*Os, T1, T2, T3](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2, T3]],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[*Os, T1, T2, T3]]: ...
    @overload
    def with_task[*Os, T1, T2, T3, T4](
        self: TaskGroup[I, tuple[*Os]],
        t: TaskGroup[I, tuple[T1, T2, T3, T4]],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[*Os, T1, T2, T3, T4]]: ...
    # Parallel Overload (left parallel + single stage)
    @overload
    def with_task[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        t: Task[I, T] | TaskGroup[I, T],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[*Os, T]]: ...
    # Parallel Overload (single stage + right-hand parallel flattening)
    @overload
    def with_task[*Os](
        self,
        t: TaskGroup[I, tuple[*Os]],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[O, *Os]]: ...
    # Parallel Overload (pair)
    @overload
    def with_task[T](
        self,
        t: Task[I, T] | TaskGroup[I, T],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[O, T]]: ...
    # Sequential Overload
    @overload
    def with_task[T](
        self, t: Task[O, T] | TaskGroup[O, T], _mode: Literal[0]
    ) -> TaskGroup[I, T]: ...
    def call(self, v: I) -> O: ...
