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


type _Stage[I, O] = (
    Task[I, O]
    | ParTaskGroup[I, O]
    | SerTaskGroup[I, O]
    | TaskGroup[I, O]
    | mojo_strata.TaskGroup[I, O]
)


def _unwrap_target[I, O](
    other: _Stage[I, O],
) -> Task[I, O] | mojo_strata.TaskGroup[I, O]:
    if isinstance(other, _BaseTaskGroup):
        return cast("mojo_strata.TaskGroup[I, O]", other.inner)
    return other


class _BaseTaskGroup[I, O]:
    """Shared base wrapper around an immutable `mojo_strata.TaskGroup`."""

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    def __call__(self, msg: I, /) -> O:
        return self.inner.call(msg)

    def __or__[T](self, other: _Stage[O, T]) -> SerTaskGroup[I, T]:
        target = _unwrap_target(other)
        return SerTaskGroup[I, T](
            self.inner.with_task(target, GroupMode.SERIAL.value)
        )


class SerTaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A series composition of tasks.

    Represents a sequential pipeline where each stage passes its output
    to the next stage. Pipelines are directly callable and immutable under
    further composition.
    """

    def __and__[T](self, other: _Stage[I, T]) -> ParTaskGroup[I, tuple[O, T]]:
        target = _unwrap_target(other)
        return ParTaskGroup[I, tuple[O, T]](
            self.inner.with_task(target, GroupMode.PARALLEL.value)
        )


class ParTaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A parallel composition of tasks.

    Represents a parallel stage where tasks receive the same input and produce
    a tuple of results. Pipelines are directly callable and immutable under
    further composition.
    """

    def __and__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: _Stage[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = _unwrap_target(other)
        return ParTaskGroup[I, tuple[*Os, T]](
            self.inner.with_task(target, GroupMode.PARALLEL.value)
        )


class TaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A single-task or intermediate group wrapper.

    Acts as the entrypoint for composition when lifting a single `Task` into a group.
    Pipelines are directly callable and immutable under further composition.
    """

    def __init__(self, task: Task[I, O]) -> None:
        super().__init__(mojo_strata.TaskGroup(task=task))

    def __and__[T](self, other: _Stage[I, T]) -> ParTaskGroup[I, tuple[O, T]]:
        target = _unwrap_target(other)
        return ParTaskGroup[I, tuple[O, T]](
            self.inner.with_task(target, GroupMode.PARALLEL.value)
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
        group = TaskGroup(self)
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
