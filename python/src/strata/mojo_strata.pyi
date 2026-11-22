from typing import Literal, Protocol, overload, type_check_only

@type_check_only
class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...

class TaskGroup[I, O]:
    def __init__(self, task: Task[I, O]) -> None: ...
    # Parallel Overload (variadic tuple flattening)
    @overload
    def with_task[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        t: Task[I, T] | TaskGroup[I, T],
        _mode: Literal[1],
    ) -> TaskGroup[I, tuple[*Os, T]]: ...
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
