from __future__ import annotations

from enum import IntEnum
from typing import Any, Literal, Protocol, cast, overload

from strata import (
    mojo_strata,  # pyright: ignore[reportUnknownVariableType, reportAttributeAccessIssue]
)


class GroupMode(IntEnum):
    UNDEFINED = -1
    SERIAL = 0
    PARALLEL = 1


class MojoGraph[I, O](Protocol):
    def __init__(self) -> None: ...

    def call_task(self, msg: I, /) -> O: ...

    def capture_elems(self, task: MojoTaskGroup[I, O], /) -> None: ...


def flatten_tuple[A, B, C](t: tuple[A, tuple[B, C]]) -> tuple[A, B, C]:
    return (t[0], t[1][0], t[1][1])


class MojoTaskGroup[I, O](Protocol):
    def from_single_task(self, task: Task[I, O]) -> None: ...
    @overload
    def add_task[*Os, T](
        self: MojoTaskGroup[I, tuple[*Os]],
        task: Task[I, T] | MojoTaskGroup[I, T],
        mode: Literal[GroupMode.PARALLEL],
        /,
    ) -> None: ...
    @overload
    def add_task[T](
        self, task: Task[O, T] | MojoTaskGroup[O, T], mode: Literal[GroupMode.SERIAL], /
    ) -> None: ...
    def add_task[T](
        self,
        task: Task[Any, T] | MojoTaskGroup[Any, T],  # pyright: ignore[reportExplicitAny]
        mode: Literal[GroupMode.SERIAL, GroupMode.PARALLEL],
        /,
    ) -> None: ...


class Task[I, O](Protocol):
    def __call__(self, msg: I, /) -> O: ...


class SerTaskGroup[I, O]:
    inner: MojoTaskGroup[I, O]

    def __init__(self, task: MojoTaskGroup[I, O]) -> None:
        self.inner = task

    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | MojoTaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        if isinstance(other, ParTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.SERIAL)
        return cast("SerTaskGroup[I, T]", self)

    def __add__[*Os, T](
        self: SerTaskGroup[I, tuple[*Os]], other: Task[O, T]
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        self.inner.add_task(other, GroupMode.PARALLEL)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("MojoTaskGroup[I, tuple[*Os, T]]", self.inner)  # ty: ignore[redundant-cast]
        )


class ParTaskGroup[I, O]:
    inner: MojoTaskGroup[I, O]

    def __init__(self, task: MojoTaskGroup[I, O]) -> None:
        self.inner = task

    def __rshift__[T](self, other: Task[O, T]) -> SerTaskGroup[I, T]:
        self.inner.add_task(other, GroupMode.SERIAL)
        return SerTaskGroup[I, T](cast("MojoTaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | MojoTaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        if isinstance(other, SerTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.PARALLEL)  # ty: ignore[no-matching-overload]
        return cast("ParTaskGroup[I, tuple[*Os, T]]", self)


class TaskGroup[I, O]:
    inner: MojoTaskGroup[I, O]

    def __init__(self, task: Task[I, O]) -> None:
        self.inner = cast("MojoTaskGroup[I, O]", mojo_strata.TaskGroup())  # pyright: ignore[reportUnknownMemberType]
        self.inner.from_single_task(task)

    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | MojoTaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        if isinstance(other, ParTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.SERIAL)
        return SerTaskGroup[I, T](cast("MojoTaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | MojoTaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        if isinstance(other, SerTaskGroup):
            other = other.inner
        self.inner.add_task(other, GroupMode.PARALLEL)  # ty: ignore[no-matching-overload]
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("MojoTaskGroup[I, tuple[*Os, T]]", self.inner)  # ty: ignore[redundant-cast]
        )


class Graph[I = object, O = object]:
    inner: MojoGraph[I, O]

    def __init__(self) -> None:
        self.inner = cast("MojoGraph[I, O]", mojo_strata.Graph())  # pyright: ignore[reportUnknownMemberType]

    @staticmethod
    def __lshift__[In, Out](
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> Graph[In, Out]:
        graph = Graph[In, Out]()
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)  # ty: ignore[invalid-argument-type]

        graph.inner.capture_elems(other.inner)
        return graph

    def __call__(self, msg: I) -> O:
        return self.inner.call_task(msg)


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
my_task_1 = AddOneTask()
my_task_2 = AddOneTask()
my_task_3 = AddOneTask()
sum_tuple = SumTuple()
int_to_str = IntToStrTask()

serial_task = Graph() << (
    str_to_int >> my_task_1 + my_task_2 + my_task_3 >> sum_tuple >> int_to_str
)

res = serial_task("4")
print(res)
