from __future__ import annotations

from typing import Protocol, cast, override

from strata import (
    old_mojo_strata as mojo_strata,  # pyright: ignore[reportUnknownVariableType, reportAttributeAccessIssue]
)


class HasTask[I, O](Protocol):
    def __call__(self, message: I) -> O: ...


class MojoTask[I, O](HasTask[I, O], Protocol):
    def __init__(self) -> None:
        pass

    def build(self, task: HasTask[I, O]) -> None:
        pass

    @override
    def __call__(self, message: I) -> O: ...


class MojoParTaskPair[I, O1, O2](HasTask[I, tuple[O1, O2]], Protocol):
    def __init__(self) -> None: ...

    def build(self, task_1: HasTask[I, O1], task_2: HasTask[I, O2]) -> None: ...

    @override
    def __call__(self, message: I) -> tuple[O1, O2]: ...


class MojoSerTaskPair[I, O1, O2](HasTask[I, O2], Protocol):
    def __init__(self) -> None: ...

    def build(self, task_1: HasTask[I, O1], task_2: HasTask[O1, O2]) -> None: ...

    @override
    def __call__(self, message: I) -> O2: ...


class Parallelizable(Protocol):
    def __add__[I, O1, O2](
        self: HasTask[I, O1], other: HasTask[I, O2]
    ) -> ParallelTask[I, O1, O2]:
        return ParallelTask(self, other)


class Serializable(Protocol):
    def __rshift__[I, O1, O2](
        self: HasTask[I, O1], other: HasTask[O1, O2]
    ) -> SerialTask[I, O1, O2]:
        return SerialTask(self, other)


class Combinable(
    Parallelizable,
    Serializable,
    Protocol,
): ...


class Task[I, O](Combinable, HasTask[I, O]):
    inner: MojoTask[I, O]

    def __init__(self, task: HasTask[I, O]) -> None:
        self.inner = cast("MojoTask[I, O]", mojo_strata.PyTask())  # pyright: ignore[reportUnknownMemberType]
        self.inner.build(task)

    @override
    def __call__(self, message: I) -> O:
        return self.inner.__call__(message)


class ParallelTask[I, O1, O2](Combinable, HasTask[I, tuple[O1, O2]]):
    inner: MojoParTaskPair[I, O1, O2]

    def __init__(self, task_1: HasTask[I, O1], task_2: HasTask[I, O2]) -> None:
        self.inner = cast(
            "MojoParTaskPair[I, O1, O2]",
            mojo_strata.PyParallelTask(),  # pyright: ignore[reportUnknownMemberType]
        )
        self.inner.build(task_1, task_2)

    @override
    def __call__(self, message: I) -> tuple[O1, O2]:
        return self.inner.__call__(message)


class SerialTask[I, O1, O2](Combinable, HasTask[I, O2]):
    inner: MojoSerTaskPair[I, O1, O2]

    def __init__(self, task_1: HasTask[I, O1], task_2: HasTask[O1, O2]) -> None:
        self.inner = cast(
            "MojoSerTaskPair[I, O1, O2]",
            mojo_strata.PySerialTask(),  # pyright: ignore[reportUnknownMemberType]
        )
        self.inner.build(task_1, task_2)

    @override
    def __call__(self, message: I) -> O2:
        return self.inner.__call__(message)
