from __future__ import annotations

from enum import IntEnum
from typing import Protocol, cast

from strata import mojo_strata


class GroupMode(IntEnum):
    UNDEFINED = -1
    SERIAL = 0
    PARALLEL = 1


class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...


class SerTaskGroup[I, O]:
    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        if isinstance(other, ParTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.SERIAL.value)
        return cast("SerTaskGroup[I, T]", self)

    def __add__[*Os, T](
        self: SerTaskGroup[I, tuple[*Os]], other: Task[O, T]
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        self.inner.add_task(other, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class ParTaskGroup[I, O]:
    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __rshift__[T](self, other: Task[O, T]) -> SerTaskGroup[I, T]:
        self.inner.add_task(other, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        if isinstance(other, SerTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.PARALLEL.value)  # ty: ignore[no-matching-overload]
        return cast("ParTaskGroup[I, tuple[*Os, T]]", self)


class TaskGroup[I, O]:
    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: Task[I, O]) -> None:
        self.inner = mojo_strata.TaskGroup(task=task)

    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        if isinstance(other, ParTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        if isinstance(other, SerTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.PARALLEL.value)  # ty: ignore[no-matching-overload]
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class Graph[I = object, O = object]:
    @staticmethod
    def __lshift__[In, Out](
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> BuildedGraph[In, Out]:
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)  # ty: ignore[invalid-argument-type]

        return BuildedGraph(elements=other.inner)  # ty: ignore[invalid-return-type]

    @classmethod
    def build[In, Out](
        cls,
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> BuildedGraph[In, Out]:
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)  # ty: ignore[invalid-argument-type]

        return BuildedGraph(elements=other.inner)  # ty: ignore[invalid-return-type]


class BuildedGraph[I = object, O = object]:
    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, elements: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = elements

    def __call__(self, msg: I) -> O:
        return self.inner.call(msg)


class Combinable(Protocol):
    def __rshift__[I, O, T](
        self: Task[I, O], other: Task[O, T] | ParTaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        return TaskGroup(self) >> other

    def __add__[I, O, T](
        self: Task[I, O], other: Task[I, T]
    ) -> ParTaskGroup[I, tuple[O, T]]:
        group = cast("TaskGroup[I, tuple[O]]", TaskGroup(self))
        return group.__add__(other)


from dataclasses import dataclass  # noqa: E402
from time import sleep, time_ns  # noqa: E402


@dataclass
class MyTask:
    value: int = 0

    def __call__(self, message: int) -> int:
        self.value += message
        return self.value


@dataclass
class AddOneTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> int:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return message + 1


@dataclass
class IntToStrTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> str:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return str(message)


@dataclass
class StrToIntTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: str) -> int:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return int(message)


@dataclass
class SumTuple(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: tuple[int, int, int]) -> int:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return sum(message)


str_to_int = StrToIntTask()
add_one_task_1 = AddOneTask()
add_one_task_2 = AddOneTask()
add_one_task_3 = AddOneTask()
sum_tuple = SumTuple()
int_to_str = IntToStrTask()

graph = Graph() << (
    str_to_int
    >> (add_one_task_1 + add_one_task_2 + add_one_task_3)
    >> sum_tuple
    >> int_to_str
)

graph2 = Graph.build(
    str_to_int
    >> (add_one_task_1 + add_one_task_2 + add_one_task_3)
    >> sum_tuple
    >> int_to_str
)
res = graph("4")
print(res)
