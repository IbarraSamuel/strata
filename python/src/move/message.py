from __future__ import annotations

from typing import Protocol, cast, override

import move.mojo_move as move  # ty: ignore[unresolved-import]


class Callable[I, O](Protocol):
    def __call__(self, message: I) -> O: ...


class MojoTask[I, O](Callable[I, O], Protocol):
    def __init__(self) -> None:
        pass

    def build(self, task: Callable[I, O]) -> None:
        pass

    @override
    def __call__(self, message: I) -> O: ...


class MojoParTaskPair[I, O1, O2](Callable[I, tuple[O1, O2]], Protocol):
    def __init__(self) -> None: ...

    def build(self, task_1: Callable[I, O1], task_2: Callable[I, O2]) -> None: ...

    @override
    def __call__(self, message: I) -> tuple[O1, O2]: ...


class MojoSerTaskPair[I, O1, O2](Callable[I, O2], Protocol):
    def __init__(self) -> None: ...

    def build(self, task_1: Callable[I, O1], task_2: Callable[O1, O2]) -> None: ...

    @override
    def __call__(self, message: I) -> O2: ...


class Parallelizable(Protocol):
    def __add__[I, O1, O2](
        self: Callable[I, O1], other: Callable[I, O2]
    ) -> ParallelTask[I, O1, O2]:
        return ParallelTask(self, other)


class Serializable(Protocol):
    def __rshift__[I, O1, O2](
        self: Callable[I, O1], other: Callable[O1, O2]
    ) -> SerialTask[I, O1, O2]:
        return SerialTask(self, other)


class Combinable(
    Parallelizable,
    Serializable,
    Protocol,
): ...


class Task[I, O](Combinable, Callable[I, O]):
    def __init__(self, task: Callable[I, O]) -> None:
        self.inner: MojoTask[I, O] = cast("MojoTask[I, O]", move.PyTask())  # pyright: ignore[reportUnknownMemberType]
        self.inner.build(task)

    @override
    def __call__(self, message: I) -> O:
        return self.inner.__call__(message)


class ParallelTask[I, O1, O2](Combinable, Callable[I, tuple[O1, O2]]):
    def __init__(self, task_1: Callable[I, O1], task_2: Callable[I, O2]) -> None:
        self.inner: MojoParTaskPair[I, O1, O2] = cast(
            "MojoParTaskPair[I, O1, O2]",
            move.PyParallelTask(),  # pyright: ignore[reportUnknownMemberType]
        )
        self.inner.build(task_1, task_2)

    @override
    def __call__(self, message: I) -> tuple[O1, O2]:
        return self.inner.__call__(message)


class SerialTask[I, O1, O2](Combinable, Callable[I, O2]):
    def __init__(self, task_1: Callable[I, O1], task_2: Callable[O1, O2]) -> None:
        self.inner: MojoSerTaskPair[I, O1, O2] = cast(
            "MojoSerTaskPair[I, O1, O2]",
            move.PySerialTask(),  # pyright: ignore[reportUnknownMemberType]
        )
        self.inner.build(task_1, task_2)

    @override
    def __call__(self, message: I) -> O2:
        return self.inner.__call__(message)
