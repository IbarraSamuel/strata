from __future__ import annotations

from enum import IntEnum
from typing import TYPE_CHECKING, Protocol, cast, override

from strata import mojo_strata

if TYPE_CHECKING:
    from collections.abc import Callable


class GroupMode(IntEnum):
    UNDEFINED = -1
    SERIAL = 0
    PARALLEL = 1


class Task[I, O](Protocol):
    """Protocol representing a single runnable unit of work.

    Classes implementing `Task` must provide a `__call__(self, msg: I, /) -> O` method.
    Tasks can inherit from `Combinable` to support `|` (stream/pipe) and `&` (parallel)
    composition operators.
    """

    def __call__(self, msg: I, /) -> O: ...


class SerTaskGroup[I, O]:
    """A series composition of tasks.

    Represents a sequential pipeline where each stage passes its output
    to the next stage. Pipelines are directly callable.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __call__(self, msg: I, /) -> O:
        return self.inner.call(msg)

    def __or__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | SerTaskGroup[O, T] | TaskGroup[O, T] | mojo_strata.TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]:
        target = other.inner if isinstance(other, (ParTaskGroup, SerTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return cast("SerTaskGroup[I, T]", self)

    def __and__[*Os, T](
        self: SerTaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | ParTaskGroup[I, T] | TaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = other.inner if isinstance(other, (SerTaskGroup, ParTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class ParTaskGroup[I, O]:
    """A parallel composition of tasks.

    Represents a parallel stage where tasks receive the same input and produce
    a tuple of results. Pipelines are directly callable.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __call__(self, msg: I, /) -> O:
        return self.inner.call(msg)

    def __or__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | SerTaskGroup[O, T] | TaskGroup[O, T] | mojo_strata.TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]:
        target = other.inner if isinstance(other, (ParTaskGroup, SerTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __and__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | ParTaskGroup[I, T] | TaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = other.inner if isinstance(other, (SerTaskGroup, ParTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class TaskGroup[I, O]:
    """A single-task or intermediate group wrapper.

    Acts as the entrypoint for composition when lifting a single `Task` into a group.
    Pipelines are directly callable.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: Task[I, O]) -> None:
        self.inner = mojo_strata.TaskGroup(task=task)

    def __call__(self, msg: I, /) -> O:
        return self.inner.call(msg)

    def __or__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | SerTaskGroup[O, T] | TaskGroup[O, T] | mojo_strata.TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]:
        target = other.inner if isinstance(other, (ParTaskGroup, SerTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __and__[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | ParTaskGroup[I, T] | TaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = other.inner if isinstance(other, (SerTaskGroup, ParTaskGroup, TaskGroup)) else other
        self.inner.add_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class Combinable(Protocol):
    """Protocol / mixin providing pipeline operator overloads (`|`, `&`) for tasks."""

    def __or__[I, O, T](
        self: Task[I, O],
        other: Task[O, T] | ParTaskGroup[O, T] | SerTaskGroup[O, T] | TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]:
        group = TaskGroup(self)
        return group | other

    def __and__[I, O, T](
        self: Task[I, O],
        other: Task[I, T] | ParTaskGroup[I, T] | SerTaskGroup[I, T] | TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[O, T]]:
        group = cast("TaskGroup[I, tuple[O]]", TaskGroup(self))
        return group & other


class FnTask[I, O](Combinable, Task[I, O]):
    inner_fn: Callable[[I], O]

    def __init__(self, f: Callable[[I], O]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, v: I, /) -> O:
        return self.inner_fn(v)


def task[I, O](f: Callable[[I], O]) -> FnTask[I, O]:
    return FnTask(f)
