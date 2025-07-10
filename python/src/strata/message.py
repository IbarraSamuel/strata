from __future__ import annotations

from typing import Protocol, override

from . import old_mojo_strata as mojo_strata


class HasTask[I, O](Protocol):
    def __call__(self, message: I) -> O: ...


class Parallelizable(Protocol):
    def __add__[I, O1, O2](
        self: HasTask[I, O1], other: HasTask[I, O2]
    ) -> ParallelTask[I, tuple[O1, O2]]:
        return ParallelTask(self, other)  # ty: ignore[invalid-return-type]


class Serializable(Protocol):
    def __rshift__[I, O1, O2](
        self: HasTask[I, O1], other: HasTask[O1, O2]
    ) -> SerialTask[I, O2]:
        return SerialTask(self, other)


class Combinable(
    Parallelizable,
    Serializable,
    Protocol,
): ...


class Task[I, O](Combinable, HasTask[I, O]):
    inner: mojo_strata.PyTask[I, O]

    def __init__(self, task: HasTask[I, O]) -> None:
        self.inner = mojo_strata.PyTask(inner=task)

    @override
    def __call__(self, message: I) -> O:
        return self.inner.__call__(message)


class ParallelTask[I, O](Combinable, HasTask[I, O]):
    inner: mojo_strata.PyParallelTask[I, O]

    def __init__[IB, O1, O2](
        self: ParallelTask[IB, tuple[O1, O2]],
        task_1: HasTask[IB, O1],
        task_2: HasTask[IB, O2],
    ) -> None:
        self.inner = mojo_strata.PyParallelTask(task_1=task_1, task_2=task_2)  # ty: ignore[invalid-assignment]

    @override
    def __call__(self, message: I) -> O:
        return self.inner.__call__(message)


class SerialTask[I, O2](Combinable, HasTask[I, O2]):
    inner: mojo_strata.PySerialTask[I, O2]

    def __init__[O1](self, task_1: HasTask[I, O1], task_2: HasTask[O1, O2]) -> None:
        self.inner = mojo_strata.PySerialTask(task_1=task_1, task_2=task_2)

    @override
    def __call__(self, message: I) -> O2:
        return self.inner.__call__(message)
