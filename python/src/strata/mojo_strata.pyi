from typing import Literal, Protocol, overload, type_check_only

@type_check_only
class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...

class TaskGroup[I, O]:
    def __init__(self, task: Task[I, O]) -> None: ...
    # Parallel Overload
    @overload
    def add_task[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        t: Task[I, T] | TaskGroup[I, T],
        _mode: Literal[1],
    ) -> None: ...
    # Sequential Overload
    @overload
    def add_task[T](
        self, t: Task[O, T] | TaskGroup[O, T], _mode: Literal[0]
    ) -> None: ...
    def call(self, v: I) -> O: ...
