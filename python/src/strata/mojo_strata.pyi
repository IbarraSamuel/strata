from typing import Literal, Protocol, overload, type_check_only

@type_check_only
class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...

class Graph[I, O]:
    def __init__(self) -> None: ...
    def call_task(self, msg: I, /) -> O: ...
    def capture_elems(self, task: TaskGroup[I, O], /) -> None: ...

class TaskGroup[I, O]:
    def from_single_task(self, task: Task[I, O]) -> None: ...
    @overload
    def add_task[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        task: Task[I, T] | TaskGroup[I, T],
        mode: Literal[1],
        /,
    ) -> None: ...
    @overload
    def add_task[T](
        self, task: Task[O, T] | TaskGroup[O, T], mode: Literal[0], /
    ) -> None: ...
