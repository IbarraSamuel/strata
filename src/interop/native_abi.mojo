"""Public Mojo C-ABI helpers for exporting GIL-free stages to Python Strata.

External Mojo extension modules can import this module to wrap pure-Mojo
functions into `strata.native_stage.v1` `PyCapsule` objects that `mojo_strata`
executes completely GIL-free inside hybrid Python/Mojo pipelines.
"""

from std.memory import OpaquePointer
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc
from std.python import Python, PythonObject
from std.python._cpython import PyObjectPtr


comptime NATIVE_STAGE_CAPSULE_NAME = StaticString("strata.native_stage.v1")
"""PyCapsule name identifying a Strata v1 native stage descriptor."""

comptime NATIVE_KIND_INT64: Int32 = 0
"""Native stage ABI kind accepting and returning `Int64`."""
comptime NATIVE_KIND_FLOAT64: Int32 = 1
"""Native stage ABI kind accepting and returning `Float64`."""
comptime NATIVE_KIND_VALUE: Int32 = 2
"""Native stage ABI kind accepting and returning tagged `NativeValue`."""

comptime NATIVE_VAL_INT64: Int32 = 0
"""Tagged `NativeValue` discriminant for `Int64`."""
comptime NATIVE_VAL_FLOAT64: Int32 = 1
"""Tagged `NativeValue` discriminant for `Float64`."""
comptime NATIVE_VAL_BOOL: Int32 = 2
"""Tagged `NativeValue` discriminant for `Bool`."""

comptime NativeIntFn = def(
    Int64, Optional[OpaquePointer[MutUntrackedOrigin]]
) thin abi("C") -> Int64
"""C-ABI function pointer signature for `Int64 -> Int64` native stages."""

comptime NativeFloatFn = def(
    Float64, Optional[OpaquePointer[MutUntrackedOrigin]]
) thin abi("C") -> Float64
"""C-ABI function pointer signature for `Float64 -> Float64` native stages."""

comptime NativeValueFn = def(
    Pointer[NativeValue, ImmUntrackedOrigin],
    Pointer[NativeValue, MutUntrackedOrigin],
    Optional[OpaquePointer[MutUntrackedOrigin]],
) thin abi("C") -> Int32
"""C-ABI function pointer signature for `NativeValue -> NativeValue` native stages."""


@fieldwise_init
struct NativeValue(Copyable, Defaultable, Movable):
    """C-ABI tagged scalar value exchanged between GIL-free native stages."""

    var kind: Int32
    """Value tag (`NATIVE_VAL_INT64`, `NATIVE_VAL_FLOAT64`, or `NATIVE_VAL_BOOL`)."""
    var _pad: Int32
    """Alignment padding for C ABI layout stability."""
    var int_val: Int64
    """Integer or boolean (0/1) payload."""
    var float_val: Float64
    """IEEE-754 float64 payload."""

    def __init__(out self):
        """Construct a zeroed `Int64` `NativeValue`."""
        self.kind = NATIVE_VAL_INT64
        self._pad = 0
        self.int_val = 0
        self.float_val = 0.0

    @staticmethod
    def from_int(v: Int64) -> Self:
        """Construct a `NativeValue` holding an `Int64`.

        Args:
            v: Integer value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_INT64, 0, v, 0.0)

    @staticmethod
    def from_float(v: Float64) -> Self:
        """Construct a `NativeValue` holding a `Float64`.

        Args:
            v: Float64 value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_FLOAT64, 0, 0, v)

    @staticmethod
    def from_bool(v: Bool) -> Self:
        """Construct a `NativeValue` holding a `Bool`.

        Args:
            v: Boolean value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_BOOL, 0, Int64(1) if v else Int64(0), 0.0)


@fieldwise_init
struct NativeStageDescriptor(Copyable, Defaultable, Movable):
    """C-ABI descriptor layout stored inside a `strata.native_stage.v1` PyCapsule."""

    var kind: Int32
    """ABI kind (`NATIVE_KIND_INT64`, `NATIVE_KIND_FLOAT64`, or `NATIVE_KIND_VALUE`)."""
    var _pad: Int32
    """Alignment padding for C ABI layout stability."""
    var fn_ptr: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Raw C-ABI function pointer matching `kind`."""
    var ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional opaque context pointer passed to `fn_ptr`."""

    def __init__(out self):
        """Construct an empty descriptor."""
        self.kind = NATIVE_KIND_INT64
        self._pad = 0
        self.fn_ptr = None
        self.ctx = None


def _destroy_descriptor_capsule(capsule: PyObjectPtr) abi("C"):
    ref cpython = Python().cpython()
    try:
        var raw_ptr = cpython.PyCapsule_GetPointer(
            capsule, String(NATIVE_STAGE_CAPSULE_NAME)
        )
        dealloc(
            ThinAllocation(
                unsafe_owned_ptr=raw_ptr.unsafe_bitcast[NativeStageDescriptor]()
            ).unsafe_with_layout(Layout[NativeStageDescriptor].single())
        )
    except:
        pass


def _allocate_descriptor_capsule(
    var desc: NativeStageDescriptor,
) raises -> PythonObject:
    var desc_alloc = alloc(Layout[NativeStageDescriptor].single())
    var desc_ptr = desc_alloc^.unsafe_leak()
    desc_ptr.write(desc^)
    ref cpython = Python().cpython()
    var cap_ptr = cpython.PyCapsule_New(
        desc_ptr.unsafe_bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ](),
        NATIVE_STAGE_CAPSULE_NAME,
        _destroy_descriptor_capsule,
    )
    if not cap_ptr:
        dealloc(
            ThinAllocation(unsafe_owned_ptr=desc_ptr).unsafe_with_layout(
                Layout[NativeStageDescriptor].single()
            )
        )
        raise "Failed to allocate PyCapsule for native stage"
    return PythonObject(from_owned=cap_ptr)


def export_int_stage_capsule(
    func: NativeIntFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
) raises -> PythonObject:
    """Export a pure-Mojo `Int64 -> Int64` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer taking `(Int64, ctx)` and returning `Int64`.
        ctx: Optional opaque context pointer outliving the capsule.

    Returns:
        A CPython `PyCapsule` runnable GIL-free in Python Strata graphs.

    Raises:
        Error if capsule creation fails.
    """
    var fn_val = func
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    return _allocate_descriptor_capsule(
        NativeStageDescriptor(NATIVE_KIND_INT64, 0, fn_opaque, ctx)
    )


def export_float_stage_capsule(
    func: NativeFloatFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
) raises -> PythonObject:
    """Export a pure-Mojo `Float64 -> Float64` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer taking `(Float64, ctx)` and returning `Float64`.
        ctx: Optional opaque context pointer outliving the capsule.

    Returns:
        A CPython `PyCapsule` runnable GIL-free in Python Strata graphs.

    Raises:
        Error if capsule creation fails.
    """
    var fn_val = func
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    return _allocate_descriptor_capsule(
        NativeStageDescriptor(NATIVE_KIND_FLOAT64, 0, fn_opaque, ctx)
    )


def export_value_stage_capsule(
    func: NativeValueFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
) raises -> PythonObject:
    """Export a general `NativeValue -> NativeValue` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer writing output `NativeValue` and returning status `0` on success.
        ctx: Optional opaque context pointer outliving the capsule.

    Returns:
        A CPython `PyCapsule` runnable GIL-free in Python Strata graphs.

    Raises:
        Error if capsule creation fails.
    """
    var fn_val = func
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    return _allocate_descriptor_capsule(
        NativeStageDescriptor(NATIVE_KIND_VALUE, 0, fn_opaque, ctx)
    )
