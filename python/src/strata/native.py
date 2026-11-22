"""GIL-free native Mojo stages and runtime diagnostics for Python Strata."""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Any, Protocol, cast, override, runtime_checkable

from strata import mojo_strata
from strata.graph import Combinable, Task


@runtime_checkable
class NativeCapsuleProvider(Protocol):
    """Protocol for objects exposing a `strata.native_stage.v1` PyCapsule."""

    def as_native_capsule(self) -> object:
        """Return a `strata.native_stage.v1` PyCapsule for GIL-free execution."""
        ...


class NativeTask[I, O](Combinable, Task[I, O]):
    """Composable Python wrapper around a GIL-free `mojo_strata.NativeStage`.

    When composed with `|` or `&`, `NativeTask` unwraps directly to its
    underlying `mojo_strata.NativeStage` so `TaskGroup` executes it without
    acquiring the Python GIL and fuses consecutive native stages.
    """

    inner_native: mojo_strata.NativeStage[I, O]

    def __init__(self, native: mojo_strata.NativeStage[I, O]) -> None:
        self.inner_native = native

    @property
    def name(self) -> str:
        """Human-readable name of the underlying native stage."""
        return self.inner_native.get_name()

    @property
    def kind(self) -> str:
        """ABI kind (`"int"`, `"float"`, or `"value"`)."""
        return self.inner_native.get_kind()

    @property
    def is_gil_free(self) -> bool:
        """Whether this stage executes without acquiring the Python GIL."""
        return self.inner_native.is_gil_free()

    @override
    def __call__(self, msg: I, /) -> O:
        return self.inner_native.call(msg)


def native_stage(
    target: NativeTask[Any, Any]
    | mojo_strata.NativeStage[Any, Any]
    | NativeCapsuleProvider
    | object,
    *,
    name: str | None = None,
) -> NativeTask[Any, Any]:
    """Lift a native stage, `strata.native_stage.v1` PyCapsule, or provider.

    Parameters
    ----------
    target : NativeTask | NativeStage | NativeCapsuleProvider | object
        Existing native stage, `strata.native_stage.v1` PyCapsule, or an object
        implementing `as_native_capsule()`.
    name : str | None, optional
        Display name used when wrapping a raw PyCapsule.

    Returns
    -------
    NativeTask[Any, Any]
        Composable GIL-free native stage ready for `|` and `&`.
    """
    if isinstance(target, NativeTask):
        return target
    if isinstance(target, mojo_strata.NativeStage):
        return NativeTask(target)
    capsule = (
        target.as_native_capsule()
        if isinstance(target, NativeCapsuleProvider)
        else target
    )
    stage_name = name if name is not None else "native_capsule"
    return NativeTask(mojo_strata.native_from_capsule(capsule, stage_name))


def native_int_linear(
    scale: int = 1,
    bias: int = 0,
    *,
    name: str = "native_int_linear",
) -> NativeTask[int, int]:
    """Create a GIL-free Mojo integer linear stage computing `scale * x + bias`.

    Parameters
    ----------
    scale : int, optional
        Multiplier applied to the input integer.
    bias : int, optional
        Offset added after multiplication.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[int, int]
        Composable GIL-free integer stage.
    """
    return NativeTask(mojo_strata.native_int_linear(scale, bias, name))


def native_float_linear(
    scale: float = 1.0,
    bias: float = 0.0,
    *,
    name: str = "native_float_linear",
) -> NativeTask[float, float]:
    """Create a GIL-free Mojo float64 linear stage computing `scale * x + bias`.

    Parameters
    ----------
    scale : float, optional
        Multiplier applied to the input float.
    bias : float, optional
        Offset added after multiplication.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[float, float]
        Composable GIL-free float64 stage.
    """
    return NativeTask(mojo_strata.native_float_linear(scale, bias, name))


def native_float_poly(
    c0: float,
    c1: float,
    c2: float,
    *,
    name: str = "native_float_poly",
) -> NativeTask[float, float]:
    """Create a GIL-free Mojo quadratic stage computing `c2*x^2 + c1*x + c0`.

    Parameters
    ----------
    c0 : float
        Constant coefficient.
    c1 : float
        Linear coefficient.
    c2 : float
        Quadratic coefficient.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[float, float]
        Composable GIL-free float64 polynomial stage.
    """
    return NativeTask(mojo_strata.native_float_poly(c0, c1, c2, name))


def native_cpu_work(
    iterations: int,
    *,
    name: str = "native_cpu_work",
) -> NativeTask[int, int]:
    """Create a deterministic GIL-free Mojo CPU compute kernel (`int -> int`).

    Parameters
    ----------
    iterations : int
        Number of 64-bit mixing rounds executed per invocation.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[int, int]
        Composable GIL-free compute stage.
    """
    return NativeTask(mojo_strata.native_cpu_work(iterations, name))


@dataclass(frozen=True)
class RuntimeInfo:
    """Snapshot of the active Python and Strata runtime concurrency capabilities."""

    python_version: str
    gil_enabled: bool
    native_gil_free: bool
    cpu_count: int


def is_gil_enabled() -> bool:
    """Return `True` if the active Python interpreter currently holds a GIL.

    Returns
    -------
    bool
        `False` on free-threaded Python (`3.13t`/`3.14t`/`3.15t`) with GIL
        disabled, otherwise `True`.
    """
    checker = getattr(sys, "_is_gil_enabled", None)
    if callable(checker):
        return bool(cast("Any", checker)())
    return True


def runtime_info() -> RuntimeInfo:
    """Return concurrency capabilities of the current Python + Mojo Strata runtime.

    Returns
    -------
    RuntimeInfo
        Interpreter version, GIL status, native GIL-free availability, and CPU count.
    """
    return RuntimeInfo(
        python_version=sys.version.split()[0],
        gil_enabled=is_gil_enabled(),
        native_gil_free=hasattr(mojo_strata, "NativeStage"),
        cpu_count=os.cpu_count() or 1,
    )
