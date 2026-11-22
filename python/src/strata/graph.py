from __future__ import annotations

from enum import IntEnum
from typing import TYPE_CHECKING, Protocol, cast, overload, override

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

type _NonParStage[I, O] = (
    Task[I, O]
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

    @overload
    def __and__[*Os](
        self, other: ParTaskGroup[I, tuple[*Os]]
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[T](self, other: _NonParStage[I, T]) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__(
        self, other: _Stage[I, object]
    ) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class ParTaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A parallel composition of tasks.

    Represents a flat parallel stage where tasks receive the same input and produce
    a flat tuple of results. Combining with another `ParTaskGroup` via `&` flattens
    associatively into one `TaskGroup`; wrap with `group(...)` to preserve nested
    tuple structure.
    """

    @overload
    def __and__[*Os, T1, T2](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2]]: ...

    @overload
    def __and__[*Os, T1, T2, T3](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2, T3]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2, T3]]: ...

    @overload
    def __and__[*Os, T1, T2, T3, T4](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[T1, T2, T3, T4]],
    ) -> ParTaskGroup[I, tuple[*Os, T1, T2, T3, T4]]: ...

    @overload
    def __and__[*Os](
        self: ParTaskGroup[I, tuple[*Os]],
        other: ParTaskGroup[I, tuple[object, ...]],
    ) -> ParTaskGroup[I, tuple[object, ...]]: ...

    @overload
    def __and__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: _NonParStage[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]: ...

    def __and__(
        self, other: _Stage[I, object]
    ) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class TaskGroup[I, O](_BaseTaskGroup[I, O]):
    """A single-task or intermediate group wrapper.

    Acts as the entrypoint for composition when lifting a single `Task` into a group.
    Pipelines are directly callable and immutable under further composition.
    """

    def __init__(self, task: Task[I, O]) -> None:
        super().__init__(mojo_strata.TaskGroup(task=task))

    @overload
    def __and__[*Os](
        self, other: ParTaskGroup[I, tuple[*Os]]
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[T](self, other: _NonParStage[I, T]) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__(
        self, other: _Stage[I, object]
    ) -> ParTaskGroup[I, tuple[object, ...]]:
        target = _unwrap_target(other)
        next_inner = self.inner.with_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup(
            cast(
                "mojo_strata.TaskGroup[I, tuple[object, ...]]",
                cast("object", next_inner),
            )
        )


class Combinable(Protocol):
    """Protocol / mixin providing pipeline operator overloads (`|`, `&`) for tasks."""

    def __or__[I, O, T](
        self: Task[I, O],
        other: Task[O, T] | ParTaskGroup[O, T] | SerTaskGroup[O, T] | TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]:
        group_stage = TaskGroup(self)
        return group_stage | other

    @overload
    def __and__[I, O, *Os](
        self: Task[I, O],
        other: ParTaskGroup[I, tuple[*Os]],
    ) -> ParTaskGroup[I, tuple[O, *Os]]: ...

    @overload
    def __and__[I, O, T](
        self: Task[I, O],
        other: Task[I, T] | SerTaskGroup[I, T] | TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[O, T]]: ...

    def __and__[I, O](
        self: Task[I, O],
        other: Task[I, object]
        | ParTaskGroup[I, object]
        | SerTaskGroup[I, object]
        | TaskGroup[I, object],
    ) -> ParTaskGroup[I, tuple[object, ...]]:
        group_stage = TaskGroup(self)
        return cast(
            "ParTaskGroup[I, tuple[object, ...]]",
            cast("object", group_stage & other),
        )


class GroupedTask[I, O](Combinable, Task[I, O]):
    """Opaque wrapper preventing `&` from flattening an inner `ParTaskGroup`.

    Use `group(a & b)` when you explicitly want nested tuple output such as
    `group(a & b) & group(c & d)` -> `tuple[tuple[O1, O2], tuple[O3, O4]]`.
    """

    inner_stage: _Stage[I, O]

    def __init__(self, stage: _Stage[I, O]) -> None:
        self.inner_stage = stage

    @override
    def __call__(self, msg: I, /) -> O:
        if isinstance(self.inner_stage, mojo_strata.TaskGroup):
            return cast("O", self.inner_stage.call(msg))
        return self.inner_stage(msg)


def group[I, O](stage: _Stage[I, O]) -> GroupedTask[I, O]:
    """Wrap a stage as an opaque `GroupedTask` so `&` preserves nested tuples.

    Parameters
    ----------
    stage : _Stage[I, O]
        Stage or parallel group to keep nested under `&`.

    Returns
    -------
    GroupedTask[I, O]
        Opaque grouped stage wrapper.
    """
    return GroupedTask(stage)


class FnTask[I, O](Combinable, Task[I, O]):
    inner_fn: Callable[[I], O]

    def __init__(self, f: Callable[[I], O]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, v: I, /) -> O:
        return self.inner_fn(v)


def task[I, O](f: Callable[[I], O]) -> FnTask[I, O]:
    return FnTask(f)
