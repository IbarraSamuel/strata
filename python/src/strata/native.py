"""GIL-free native Mojo scalar, Arrow columnar, and GPU stages for Python Strata."""

from __future__ import annotations

import importlib
import os
import sys
from dataclasses import dataclass
from typing import (
    TYPE_CHECKING,
    Any,
    Literal,
    Protocol,
    cast,
    overload,
    override,
    runtime_checkable,
)

from strata import mojo_strata
from strata.graph import Combinable, Task

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator, Sequence

_REPR_PREVIEW_LIMIT = 8
_REPR_HEAD_COUNT = 6


@runtime_checkable
class NativeCapsuleProvider(Protocol):
    """Protocol for objects exposing a `strata.native_stage.v1` PyCapsule."""

    def as_native_capsule(self) -> object:
        """Return a `strata.native_stage.v1` PyCapsule for GIL-free execution."""
        ...


@runtime_checkable
class ArrowCArrayProvider(Protocol):
    """Protocol for objects implementing the Apache Arrow PyCapsule Interface."""

    def __arrow_c_array__(  # ruff: ignore[bad-dunder-method-name]
        self, requested_schema: object = None
    ) -> tuple[object, object]:
        """Export `('arrow_schema', 'arrow_array')` PyCapsules."""
        ...


class ArrowArray[T: (float, int)]:
    """Arrow-compatible contiguous columnar array backed by native Mojo memory.

    Implements the Apache Arrow C Data Interface PyCapsule protocol
    (`__arrow_c_array__`) for zero-copy interchange with `pyarrow`, `polars`,
    `nanoarrow`, and Mojo CPU/GPU stages, while also functioning as a standard
    Python sequence with zero external dependencies.
    """

    _buffer: mojo_strata.ArrowBuffer

    def __init__(
        self,
        values: ArrowArray[Any]
        | mojo_strata.ArrowBuffer
        | ArrowCArrayProvider
        | Iterable[float | int]
        | object,
        *,
        dtype: Literal["float64", "int64", "auto"] = "auto",
    ) -> None:
        if isinstance(values, ArrowArray) and dtype in {"auto", values.dtype}:
            self._buffer = values.raw_buffer
            return
        if isinstance(values, mojo_strata.ArrowBuffer) and dtype in {
            "auto",
            values.get_dtype(),
        }:
            self._buffer = values
            return
        self._buffer = mojo_strata.ArrowBuffer.from_py(values, dtype)

    @property
    def raw_buffer(self) -> mojo_strata.ArrowBuffer:
        """Underlying native `mojo_strata.ArrowBuffer`."""
        return self._buffer

    @classmethod
    def from_raw_buffer(cls, buf: mojo_strata.ArrowBuffer) -> ArrowArray[Any]:
        """Wrap an existing `mojo_strata.ArrowBuffer` in an `ArrowArray`.

        Parameters
        ----------
        buf : mojo_strata.ArrowBuffer
            Native Mojo Arrow buffer.

        Returns
        -------
        ArrowArray[Any]
            Wrapped `ArrowArray`.
        """
        inst = object.__new__(cls)
        inst._buffer = buf
        return inst

    @classmethod
    def from_arrow(
        cls,
        obj: ArrowCArrayProvider | ArrowArray[Any] | object,
        *,
        dtype: Literal["float64", "int64", "auto"] = "auto",
    ) -> ArrowArray[Any]:
        """Construct an `ArrowArray` from any `__arrow_c_array__`-compatible object.

        Parameters
        ----------
        obj : ArrowCArrayProvider | ArrowArray | object
            Object implementing `__arrow_c_array__()` (e.g. `pyarrow.Array`,
            `polars.Series`, or `strata.ArrowArray`).
        dtype : {"float64", "int64", "auto"}, optional
            Target dtype or `"auto"` to preserve the source Arrow format.

        Returns
        -------
        ArrowArray[Any]
            Native Mojo-backed Arrow array.

        Raises
        ------
        TypeError
            If `obj` does not implement `__arrow_c_array__()`.
        """
        if not isinstance(obj, (ArrowArray, mojo_strata.ArrowBuffer)) and not hasattr(
            obj, "__arrow_c_array__"
        ):
            msg = "from_arrow() requires an object implementing __arrow_c_array__()"
            raise TypeError(msg)
        return cls(obj, dtype=dtype)

    def __arrow_c_array__(  # ruff: ignore[bad-dunder-method-name]
        self, requested_schema: object = None
    ) -> tuple[object, object]:
        """Export `('arrow_schema', 'arrow_array')` Arrow C Data Interface capsules.

        Parameters
        ----------
        requested_schema : object, optional
            Optional requested schema capsule (currently unused).

        Returns
        -------
        tuple[object, object]
            Pair of `(schema_capsule, array_capsule)` PyCapsules.
        """
        _ = requested_schema
        return self._buffer.export_c_capsules()

    @property
    def dtype(self) -> str:
        """Element data type (`"float64"` or `"int64"`)."""
        return self._buffer.get_dtype()

    @property
    def nbytes(self) -> int:
        """Total contiguous data buffer size in bytes."""
        return self._buffer.nbytes()

    def data_ptr(self) -> int:
        """Return the raw memory address of the contiguous buffer (`0` if empty).

        Returns
        -------
        int
            Memory address of the underlying data buffer.
        """
        return self._buffer.data_ptr()

    def __len__(self) -> int:
        return self._buffer.length()

    @overload
    def __getitem__(self, index: int) -> T: ...

    @overload
    def __getitem__(self, index: slice) -> ArrowArray[T]: ...

    def __getitem__(self, index: int | slice) -> T | ArrowArray[T]:
        if isinstance(index, slice):
            start, stop, step = index.indices(len(self))
            sliced_buf = self._buffer.slice_buffer(start, stop, step)
            return cast("ArrowArray[T]", ArrowArray.from_raw_buffer(sliced_buf))
        return cast("T", self._buffer.get_item(index))

    def __iter__(self) -> Iterator[T]:
        return iter(self.to_list())

    def to_list(self) -> list[T]:
        """Materialize the array elements as a Python `list`.

        Returns
        -------
        list[T]
            Copied Python list of array values.
        """
        return cast("list[T]", self._buffer.to_list())

    def to_pyarrow(self) -> Any:  # ruff: ignore[any-type]
        """Import this array into a `pyarrow.Array` via the Arrow C Data Interface.

        Returns
        -------
        pyarrow.Array
            Zero-copy imported PyArrow array (requires `pyarrow` to be installed).
        """
        pa: Any = importlib.import_module("pyarrow")
        return pa.array(self)

    @override
    def __eq__(self, other: object) -> bool:
        if isinstance(other, ArrowArray):
            return self.dtype == other.dtype and self.to_list() == other.to_list()
        if isinstance(other, (list, tuple)):
            return self.to_list() == list(other)
        return False

    @override
    def __hash__(self) -> int:
        return hash((self.dtype, tuple(self.to_list())))

    @override
    def __repr__(self) -> str:
        vals = self.to_list()
        preview = (
            vals
            if len(vals) <= _REPR_PREVIEW_LIMIT
            else [*vals[:_REPR_HEAD_COUNT], "..."]
        )
        return f"ArrowArray(dtype={self.dtype!r}, length={len(vals)}, values={preview})"


def arrow_array(
    values: ArrowArray[Any]
    | ArrowCArrayProvider
    | Sequence[float | int]
    | Iterable[float | int]
    | object,
    *,
    dtype: Literal["float64", "int64", "auto"] = "auto",
) -> ArrowArray[Any]:
    """Create a native Mojo-backed `ArrowArray` from a sequence or Arrow object.

    Parameters
    ----------
    values : ArrowArray | ArrowCArrayProvider | Iterable[float | int]
        Input values or object implementing `__arrow_c_array__()`.
    dtype : {"float64", "int64", "auto"}, optional
        Target columnar dtype (`"float64"`, `"int64"`, or `"auto"`).

    Returns
    -------
    ArrowArray[Any]
        Contiguous Arrow-compatible columnar array.
    """
    return ArrowArray(values, dtype=dtype)


mojo_strata._set_arrow_wrapper(ArrowArray.from_raw_buffer)  # ruff: ignore[private-member-access]


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
        """ABI kind (`"int"`, `"float"`, `"value"`, `"arrow_float64"`, etc.)."""
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


def native_arrow_int_linear(
    scale: int = 1,
    bias: int = 0,
    *,
    use_gpu: bool = False,
    name: str = "native_arrow_int_linear",
) -> NativeTask[Any, ArrowArray[int]]:
    """Create a GIL-free Mojo stage computing `scale * x + bias` on Arrow ints.

    Parameters
    ----------
    scale : int, optional
        Multiplier applied to each element.
    bias : int, optional
        Offset added to each element.
    use_gpu : bool, optional
        If `True`, dispatches the kernel to the GPU when an accelerator is available.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[Any, ArrowArray[int]]
        Composable Arrow stage returning an `ArrowArray[int]`.
    """
    return NativeTask(
        mojo_strata.native_arrow_int_linear(scale, bias, use_gpu, name)
    )


def native_arrow_float_linear(
    scale: float = 1.0,
    bias: float = 0.0,
    *,
    use_gpu: bool = False,
    name: str = "native_arrow_float_linear",
) -> NativeTask[Any, ArrowArray[float]]:
    """Create a GIL-free Mojo stage computing `scale * x + bias` on Arrow floats.

    Parameters
    ----------
    scale : float, optional
        Multiplier applied to each element.
    bias : float, optional
        Offset added to each element.
    use_gpu : bool, optional
        If `True`, dispatches the kernel to the GPU when an accelerator is available.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[Any, ArrowArray[float]]
        Composable Arrow stage returning an `ArrowArray[float]`.
    """
    return NativeTask(
        mojo_strata.native_arrow_float_linear(scale, bias, use_gpu, name)
    )


def native_arrow_float_poly(
    c0: float,
    c1: float,
    c2: float,
    *,
    use_gpu: bool = False,
    name: str = "native_arrow_float_poly",
) -> NativeTask[Any, ArrowArray[float]]:
    """Create a GIL-free Mojo stage computing `c2*x^2 + c1*x + c0` on Arrow floats.

    Parameters
    ----------
    c0 : float
        Constant coefficient.
    c1 : float
        Linear coefficient.
    c2 : float
        Quadratic coefficient.
    use_gpu : bool, optional
        If `True`, dispatches the kernel to the GPU when an accelerator is available.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[Any, ArrowArray[float]]
        Composable Arrow stage returning an `ArrowArray[float]`.
    """
    return NativeTask(
        mojo_strata.native_arrow_float_poly(c0, c1, c2, use_gpu, name)
    )


def gpu_arrow_int_linear(
    scale: int = 1,
    bias: int = 0,
    *,
    name: str = "gpu_arrow_int_linear",
) -> NativeTask[Any, ArrowArray[int]]:
    """Create a GPU-accelerated Mojo stage computing `scale * x + bias` on Arrow ints.

    Parameters
    ----------
    scale : int, optional
        Multiplier applied to each element.
    bias : int, optional
        Offset added to each element.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[Any, ArrowArray[int]]
        Composable GPU Arrow stage returning an `ArrowArray[int]`.
    """
    return native_arrow_int_linear(scale, bias, use_gpu=True, name=name)


def gpu_arrow_float_linear(
    scale: float = 1.0,
    bias: float = 0.0,
    *,
    name: str = "gpu_arrow_float_linear",
) -> NativeTask[Any, ArrowArray[float]]:
    """Create a GPU-accelerated Mojo stage computing `scale * x + bias` on Arrow floats.

    Parameters
    ----------
    scale : float, optional
        Multiplier applied to each element.
    bias : float, optional
        Offset added to each element.
    name : str, optional
        Display name for introspection and tracing.

    Returns
    -------
    NativeTask[Any, ArrowArray[float]]
        Composable GPU Arrow stage returning an `ArrowArray[float]`.
    """
    return native_arrow_float_linear(scale, bias, use_gpu=True, name=name)


def gpu_arrow_float_poly(
    c0: float,
    c1: float,
    c2: float,
    *,
    name: str = "gpu_arrow_float_poly",
) -> NativeTask[Any, ArrowArray[float]]:
    """Create a GPU-accelerated Mojo quadratic stage over Arrow float data.

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
    NativeTask[Any, ArrowArray[float]]
        Composable GPU Arrow stage returning an `ArrowArray[float]`.
    """
    return native_arrow_float_poly(c0, c1, c2, use_gpu=True, name=name)


def has_gpu() -> bool:
    """Return `True` if a supported GPU accelerator is available to the Mojo runtime.

    Returns
    -------
    bool
        `True` if a supported GPU is present, otherwise `False`.
    """
    return bool(mojo_strata.has_gpu())


@dataclass(frozen=True)
class RuntimeInfo:
    """Snapshot of the active Python and Strata runtime concurrency capabilities."""

    python_version: str
    gil_enabled: bool
    native_gil_free: bool
    cpu_count: int
    gpu_available: bool = False


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
        Interpreter version, GIL status, native GIL-free availability, CPU count,
        and GPU availability.
    """
    return RuntimeInfo(
        python_version=sys.version.split()[0],
        gil_enabled=is_gil_enabled(),
        native_gil_free=hasattr(mojo_strata, "NativeStage"),
        cpu_count=os.cpu_count() or 1,
        gpu_available=has_gpu(),
    )
