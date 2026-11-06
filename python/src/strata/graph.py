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
    Tasks can inherit from `Combinable` to support `>>` (serial) and `+` (parallel)
    composition operators.
    """

    def __call__(self, msg: I, /) -> O: ...


class SerTaskGroup[I, O]:
    """A series composition of tasks.

    Represents an unbuilt sequential pipeline where each stage passes its output
    to the next stage. Serial groups cannot be called directly; finalize them into a
    `BuildedGraph` using `>> Graph()` or `Graph.build(group)`.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    @overload
    def __rshift__(self, other: Graph) -> BuildedGraph[I, O]: ...
    @overload
    def __rshift__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T],
    ) -> SerTaskGroup[I, T]: ...
    def __rshift__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T] | Graph,
    ) -> SerTaskGroup[I, T] | BuildedGraph[I, O]:
        if isinstance(other, Graph):
            return BuildedGraph(elements=self.inner)
        target = other.inner if isinstance(other, ParTaskGroup) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return cast("SerTaskGroup[I, T]", self)

    def __add__[*Os, T](
        self: SerTaskGroup[I, tuple[*Os]], other: Task[I, T]
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        self.inner.add_task(other, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class ParTaskGroup[I, O]:
    """A parallel composition of tasks.

    Represents an unbuilt parallel stage where tasks receive the same input and produce
    a tuple of results. Parallel groups cannot be called directly; finalize them into a
    `BuildedGraph` using `>> Graph()` or `Graph.build(group)`.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = task

    @overload
    def __rshift__(self, other: Graph) -> BuildedGraph[I, O]: ...
    @overload
    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T]
    ) -> SerTaskGroup[I, T]: ...
    def __rshift__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T] | Graph,
    ) -> SerTaskGroup[I, T] | BuildedGraph[I, O]:
        if isinstance(other, Graph):
            return BuildedGraph(elements=self.inner)
        target = other.inner if isinstance(other, ParTaskGroup) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: ParTaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = other.inner if isinstance(other, SerTaskGroup) else other
        self.inner.add_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class TaskGroup[I, O]:
    """A single-task or intermediate group wrapper.

    Acts as the entrypoint for composition when lifting a single `Task` into a group.
    Task groups cannot be called directly; build them with `>> Graph()`
    or `Graph.build(...)`.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, task: Task[I, O]) -> None:
        self.inner = mojo_strata.TaskGroup(task=task)

    @overload
    def __rshift__(self, other: Graph) -> BuildedGraph[I, O]: ...
    @overload
    def __rshift__[T](
        self, other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T]
    ) -> SerTaskGroup[I, T]: ...
    def __rshift__[T](
        self,
        other: Task[O, T] | ParTaskGroup[O, T] | mojo_strata.TaskGroup[O, T] | Graph,
    ) -> SerTaskGroup[I, T] | BuildedGraph[I, O]:
        if isinstance(other, Graph):
            return BuildedGraph(elements=self.inner)
        target = other.inner if isinstance(other, ParTaskGroup) else other
        self.inner.add_task(target, GroupMode.SERIAL.value)
        return SerTaskGroup[I, T](cast("mojo_strata.TaskGroup[I, T]", self.inner))

    def __add__[*Os, T](
        self: TaskGroup[I, tuple[*Os]],
        other: Task[I, T] | SerTaskGroup[I, T] | mojo_strata.TaskGroup[I, T],
    ) -> ParTaskGroup[I, tuple[*Os, T]]:
        target = other.inner if isinstance(other, SerTaskGroup) else other
        self.inner.add_task(target, GroupMode.PARALLEL.value)
        return ParTaskGroup[I, tuple[*Os, T]](
            cast("mojo_strata.TaskGroup[I, tuple[*Os, T]]", self.inner)
        )


class Graph:
    """Builder and compiler for execution graphs.

    Use `Graph.build(pipeline)` or `pipeline >> Graph()` or `Graph() << pipeline`
    to compile an unbuilt task/group pipeline into a callable `BuildedGraph`.
    """

    @staticmethod
    def __lshift__[In, Out](
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> BuildedGraph[In, Out]:
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)

        return BuildedGraph(elements=other.inner)

    @staticmethod
    def __rshift__[In, Out](
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> BuildedGraph[In, Out]:
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)

        return BuildedGraph(elements=other.inner)

    @staticmethod
    def build[In, Out](
        other: SerTaskGroup[In, Out]
        | ParTaskGroup[In, Out]
        | TaskGroup[In, Out]
        | Task[In, Out],
    ) -> BuildedGraph[In, Out]:
        # It's not a group
        if not isinstance(other, (TaskGroup, SerTaskGroup, ParTaskGroup)):
            other = TaskGroup(other)

        return BuildedGraph(elements=other.inner)


class BuildedGraph[I, O]:
    """An executable, compiled task graph.

    This is the sole execution target. Calling `builded_graph(msg)` runs the underlying
    Mojo async runtime engine and returns the final computation result.
    """

    inner: mojo_strata.TaskGroup[I, O]

    def __init__(self, elements: mojo_strata.TaskGroup[I, O]) -> None:
        self.inner = elements

    def __call__(self, msg: I) -> O:
        return self.inner.call(msg)


class Combinable(Protocol):
    """Protocol / mixin providing pipeline operator overloads (`>>`, `+`) for tasks."""

    def __rshift__[I, O, T](
        self: Task[I, O], other: Task[O, T] | ParTaskGroup[O, T]
    ) -> SerTaskGroup[I, T]:
        group = TaskGroup(self)
        return group >> other

    def __add__[I, O, T](
        self: Task[I, O], other: Task[I, T]
    ) -> ParTaskGroup[I, tuple[O, T]]:
        group = cast("TaskGroup[I, tuple[O]]", TaskGroup(self))
        return group + other


class FnTask[I, O](Combinable, Task[I, O]):
    inner_fn: Callable[[I], O]

    def __init__(self, f: Callable[[I], O]) -> None:
        self.inner_fn = f

    @override
    def __call__(self, v: I, /) -> O:
        return self.inner_fn(v)


def task[I, O](f: Callable[[I], O]) -> FnTask[I, O]:
    return FnTask(f)
