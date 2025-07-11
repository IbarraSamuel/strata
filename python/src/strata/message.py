from __future__ import annotations

from typing import Protocol, cast, overload, override, runtime_checkable

from . import old_mojo_strata as mojo_strata


class HasTask[I, O](Protocol):
    def __call__(self, message: I, /) -> O: ...


@runtime_checkable
class NestedTask[I, Oi, Of, *Ts](Protocol):
    _parallel_join: bool = True

    def __call__(self, message: I, /) -> tuple[Oi, *Ts, Of]: ...


class Parallelizable(Protocol):
    @overload
    def __add__[I, Oi, Oo, Of, *On](
        self: NestedTask[I, Oi, Of, *On],  # ty: ignore
        other: HasTask[I, Oo],
    ) -> ParallelTask[I, Oi, Oo, *On, Of]: ...  # ty: ignore
    @overload
    def __add__[I, O1, O2](
        self: HasTask[I, O1], other: HasTask[I, O2]
    ) -> ParallelTask[I, O1, O2]: ...

    def __add__[I, Oi, Oo, Of, *On](
        self: HasTask[I, Oi] | NestedTask[I, Oi, Of, *On],  # ty: ignore
        other: HasTask[I, Oo],
    ) -> ParallelTask[I, Oi, Oo] | ParallelTask[I, Oi, Oo, *On, Of]:  # ty: ignore[too-many-positional-arguments]
        return ParallelTask(self, other)  # pyright: ignore[reportReturnType]


class Serializable(Protocol):
    def __rshift__[I, M, O](
        self: HasTask[I, M], other: HasTask[M, O]
    ) -> SerialTask[I, O]:
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


class ParallelTask[I, Oi, Oo, *On](Combinable, NestedTask[I, Oi, Oo, *On]):  # ty: ignore
    inner: mojo_strata.PyParallelTask[I, tuple[tuple[Oi, *On], Oo] | tuple[Oi, Oo]]
    _parallel_join: bool

    @overload
    def __init__[i, oi, of, oo, *on](
        self: ParallelTask[i, oi, oo, *on, of],  # ty: ignore
        task_1: NestedTask[i, oi, of, *on],  # ty: ignore
        task_2: HasTask[i, oo],
    ) -> None: ...

    @overload
    def __init__[i, oi, oo](
        self: ParallelTask[i, oi, oo],
        task_1: HasTask[i, oi],
        task_2: HasTask[i, oo],
    ) -> None: ...
    def __init__[i, oi, of, oo, *on](
        self: ParallelTask[i, oi, oo, *on, of] | ParallelTask[i, oi, oo, *tuple[()]],  # ty: ignore
        task_1: HasTask[i, oi] | NestedTask[i, oi, of, *on],  # ty: ignore
        task_2: HasTask[i, oo],
    ) -> None:
        self._parallel_join = isinstance(task_1, ParallelTask)
        if type(task_1) is NestedTask[i, oi, of, *on]:  # ty: ignore
            self.inner = mojo_strata.PyParallelTask(task_1=task_1, task_2=task_2)  # pyright: ignore[reportAttributeAccessIssue]
            return

        if type(task_1) is HasTask[i, oi]:
            self.inner = mojo_strata.PyParallelTask(task_1=task_1, task_2=task_2)

        else:
            msg = "No types can match the value required."
            raise TypeError(msg)

    @override
    def __call__(self, msg: I) -> tuple[Oi, *On, Oo]:
        v1, v2 = self.inner.__call__(msg)
        if self._parallel_join:
            # SAFETY: Since we come from a parallel join, then this should be a tuple.
            return (*cast("tuple[Oi, *On]", v1), v2)

        # SAFETY: We know this should be a single value, and therefore, *Os is empty.
        return cast("tuple[Oi, *On, Oo]", (v1, v2))


def f1(v: int) -> float:
    return v + 1.0


def f2(v: int) -> str:
    return str(v)


def f3(v: int) -> int:
    return int(v)


def test() -> None:
    pt = ParallelTask(task_1=f1, task_2=f2)
    r2 = ParallelTask(pt, f3)
    _r = r2(1)


class SerialTask[I, O2](Combinable, HasTask[I, O2]):
    inner: mojo_strata.PySerialTask[I, O2]

    def __init__[O1](self, task_1: HasTask[I, O1], task_2: HasTask[O1, O2]) -> None:
        self.inner = mojo_strata.PySerialTask(task_1=task_1, task_2=task_2)

    @override
    def __call__(self, message: I) -> O2:
        return self.inner.__call__(message)
