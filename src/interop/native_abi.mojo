"""Public Mojo C-ABI helpers for exporting GIL-free scalar and Arrow stages to Python Strata.

External Mojo extension modules can import this module to wrap pure-Mojo CPU or
GPU functions into `strata.native_stage.v1` `PyCapsule` objects that
`mojo_strata` executes completely GIL-free inside hybrid Python/Mojo pipelines.
"""

from std.memory import OpaquePointer
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc
from std.python import Python, PythonObject
from std.python._cpython import PyObjectPtr


comptime NATIVE_STAGE_CAPSULE_NAME = StaticString("strata.native_stage.v1")
"""PyCapsule name identifying a Strata v1 native stage descriptor."""

comptime ARROW_SCHEMA_CAPSULE_NAME = StaticString("arrow_schema")
"""Standard Apache Arrow C Data Interface PyCapsule name for `ArrowSchema`."""

comptime ARROW_ARRAY_CAPSULE_NAME = StaticString("arrow_array")
"""Standard Apache Arrow C Data Interface PyCapsule name for `ArrowArray`."""

comptime NATIVE_KIND_INT64: Int32 = 0
"""Native stage ABI kind accepting and returning scalar `Int64`."""
comptime NATIVE_KIND_FLOAT64: Int32 = 1
"""Native stage ABI kind accepting and returning scalar `Float64`."""
comptime NATIVE_KIND_VALUE: Int32 = 2
"""Native stage ABI kind accepting and returning tagged scalar `NativeValue`."""
comptime NATIVE_KIND_ARROW_FLOAT64: Int32 = 3
"""Native stage ABI kind accepting and returning contiguous Arrow `Float64` columns."""
comptime NATIVE_KIND_ARROW_INT64: Int32 = 4
"""Native stage ABI kind accepting and returning contiguous Arrow `Int64` columns."""

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

comptime NativeArrowFloatFn = def(
    Pointer[Float64, ImmUntrackedOrigin],
    Pointer[Float64, MutUntrackedOrigin],
    Int64,
    Optional[OpaquePointer[MutUntrackedOrigin]],
) thin abi("C") -> Int32
"""C-ABI function pointer signature for `(in_ptr, out_ptr, length, ctx) -> status` Arrow `Float64` stages."""

comptime NativeArrowIntFn = def(
    Pointer[Int64, ImmUntrackedOrigin],
    Pointer[Int64, MutUntrackedOrigin],
    Int64,
    Optional[OpaquePointer[MutUntrackedOrigin]],
) thin abi("C") -> Int32
"""C-ABI function pointer signature for `(in_ptr, out_ptr, length, ctx) -> status` Arrow `Int64` stages."""

comptime NativeCtxDeleter = def(
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> None
"""C-ABI callback signature invoked on PyCapsule destruction to free heap `ctx`."""

comptime ArrowSchemaReleaseFn = def(
    Pointer[ArrowCSchema, MutUntrackedOrigin]
) thin abi("C") -> None
"""C-ABI release callback signature for an Apache Arrow `ArrowSchema` struct."""

comptime ArrowArrayReleaseFn = def(
    Pointer[ArrowCArray, MutUntrackedOrigin]
) thin abi("C") -> None
"""C-ABI release callback signature for an Apache Arrow `ArrowArray` struct."""


@fieldwise_init
struct ArrowCSchema(Copyable, Defaultable, Movable):
    """C-ABI layout matching the Apache Arrow C Data Interface `struct ArrowSchema`."""

    var format: Optional[Pointer[UInt8, ImmUntrackedOrigin]]
    """Null-terminated format string (`"g"` for float64, `"l"` for int64, `"f"` for float32, `"i"` for int32)."""
    var name: Optional[Pointer[UInt8, ImmUntrackedOrigin]]
    """Optional null-terminated field name string."""
    var metadata: Optional[Pointer[UInt8, ImmUntrackedOrigin]]
    """Optional binary metadata pointer."""
    var flags: Int64
    """Bitflags (e.g. `ARROW_FLAG_NULLABLE = 2`)."""
    var n_children: Int64
    """Number of child schemas (`0` for primitive flat arrays)."""
    var children: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional pointer to child `ArrowCSchema*` array."""
    var dictionary: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional pointer to dictionary `ArrowCSchema`."""
    var release: Optional[ArrowSchemaReleaseFn]
    """Release callback; set to `None` (`NULL`) once released."""
    var private_data: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Producer-private opaque handle."""

    def __init__(out self):
        """Construct a zeroed `ArrowCSchema`."""
        self.format = None
        self.name = None
        self.metadata = None
        self.flags = 0
        self.n_children = 0
        self.children = None
        self.dictionary = None
        self.release = None
        self.private_data = None


@fieldwise_init
struct ArrowCArray(Copyable, Defaultable, Movable):
    """C-ABI layout matching the Apache Arrow C Data Interface `struct ArrowArray`."""

    var length: Int64
    """Logical number of elements in the array."""
    var null_count: Int64
    """Number of null elements (`0` for non-null primitive buffers)."""
    var offset: Int64
    """Logical starting element offset inside the data buffer."""
    var n_buffers: Int64
    """Number of buffers (`2` for primitive arrays: `[validity_bitmap, data_buffer]`)."""
    var n_children: Int64
    """Number of child arrays (`0` for primitive arrays)."""
    var buffers: Optional[
        Pointer[Optional[OpaquePointer[ImmUntrackedOrigin]], MutUntrackedOrigin]
    ]
    """Pointer to array of buffer pointers (`buffers[0]` validity, `buffers[1]` values)."""
    var children: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional pointer to child `ArrowCArray*` array."""
    var dictionary: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional pointer to dictionary `ArrowCArray`."""
    var release: Optional[ArrowArrayReleaseFn]
    """Release callback; set to `None` (`NULL`) once released."""
    var private_data: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Producer-private opaque handle keeping backing memory alive."""

    def __init__(out self):
        """Construct a zeroed `ArrowCArray`."""
        self.length = 0
        self.null_count = 0
        self.offset = 0
        self.n_buffers = 0
        self.n_children = 0
        self.buffers = None
        self.children = None
        self.dictionary = None
        self.release = None
        self.private_data = None


@fieldwise_init
struct NativeValue(Copyable, Defaultable, Movable, TrivialRegisterPassable):
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
    """ABI kind (`NATIVE_KIND_INT64`, `NATIVE_KIND_FLOAT64`, `NATIVE_KIND_VALUE`, `NATIVE_KIND_ARROW_FLOAT64`, or `NATIVE_KIND_ARROW_INT64`)."""
    var _pad: Int32
    """Alignment padding for C ABI layout stability."""
    var fn_ptr: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Raw C-ABI function pointer matching `kind`."""
    var ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional opaque context pointer passed to `fn_ptr`."""
    var ctx_deleter: Optional[NativeCtxDeleter]
    """Optional C-ABI destructor invoked on `ctx` when the owning PyCapsule is freed."""

    def __init__(out self):
        """Construct an empty descriptor."""
        self.kind = NATIVE_KIND_INT64
        self._pad = 0
        self.fn_ptr = None
        self.ctx = None
        self.ctx_deleter = None


def _restore_raised_exception(exc_ptr: PyObjectPtr):
    ref cpython = Python().cpython()
    if cpython.lib.check_symbol("PyErr_SetRaisedException"):
        var set_exc = cpython.lib.borrow().get_function[
            def(PyObjectPtr) thin abi("C") -> None
        ]("PyErr_SetRaisedException")
        set_exc(exc_ptr)
    elif Bool(exc_ptr):
        var exc_type = cpython.PyObject_Type(exc_ptr)
        cpython.PyErr_Restore(exc_type, exc_ptr, PyObjectPtr())
    else:
        cpython.PyErr_Clear()


def _destroy_descriptor_capsule(capsule: PyObjectPtr) abi("C"):
    ref cpython = Python().cpython()
    var saved_exc = cpython.PyErr_GetRaisedException()
    try:
        var raw_ptr = cpython.PyCapsule_GetPointer(
            capsule, String(NATIVE_STAGE_CAPSULE_NAME)
        )
        var desc_ptr = raw_ptr.unsafe_bitcast[NativeStageDescriptor]()
        if case .Some(deleter) = desc_ptr[].ctx_deleter:
            if case .Some(raw_ctx) = desc_ptr[].ctx:
                deleter(raw_ctx)
        dealloc(
            ThinAllocation(unsafe_owned_ptr=desc_ptr).unsafe_with_layout(
                Layout[NativeStageDescriptor].single()
            )
        )
    except:
        pass
    _restore_raised_exception(saved_exc)


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
    ctx_deleter: Optional[NativeCtxDeleter] = None,
) raises -> PythonObject:
    """Export a pure-Mojo `Int64 -> Int64` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer taking `(Int64, ctx)` and returning `Int64`.
        ctx: Optional opaque context pointer outliving the capsule.
        ctx_deleter: Optional C-ABI destructor called with `ctx` on capsule teardown.

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
        NativeStageDescriptor(NATIVE_KIND_INT64, 0, fn_opaque, ctx, ctx_deleter)
    )


def export_float_stage_capsule(
    func: NativeFloatFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
    ctx_deleter: Optional[NativeCtxDeleter] = None,
) raises -> PythonObject:
    """Export a pure-Mojo `Float64 -> Float64` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer taking `(Float64, ctx)` and returning `Float64`.
        ctx: Optional opaque context pointer outliving the capsule.
        ctx_deleter: Optional C-ABI destructor called with `ctx` on capsule teardown.

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
        NativeStageDescriptor(
            NATIVE_KIND_FLOAT64, 0, fn_opaque, ctx, ctx_deleter
        )
    )


def export_value_stage_capsule(
    func: NativeValueFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
    ctx_deleter: Optional[NativeCtxDeleter] = None,
) raises -> PythonObject:
    """Export a general `NativeValue -> NativeValue` function as a `strata.native_stage.v1` PyCapsule.

    Args:
        func: C-ABI function pointer writing output `NativeValue` and returning status `0` on success.
        ctx: Optional opaque context pointer outliving the capsule.
        ctx_deleter: Optional C-ABI destructor called with `ctx` on capsule teardown.

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
        NativeStageDescriptor(NATIVE_KIND_VALUE, 0, fn_opaque, ctx, ctx_deleter)
    )


def export_arrow_float_stage_capsule(
    func: NativeArrowFloatFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
    ctx_deleter: Optional[NativeCtxDeleter] = None,
) raises -> PythonObject:
    """Export a columnar Arrow `Float64` buffer kernel as a `strata.native_stage.v1` PyCapsule.

    The callback receives `(in_ptr, out_ptr, length, ctx)` with the Python GIL
    released and writes `length` elements into `out_ptr`, returning `0` on
    success or a non-zero status code on failure (e.g., GPU execution error).

    Args:
        func: C-ABI function pointer operating on contiguous `Float64` buffers.
        ctx: Optional opaque context pointer outliving the capsule.
        ctx_deleter: Optional C-ABI destructor called with `ctx` on capsule teardown.

    Returns:
        A CPython `PyCapsule` runnable GIL-free on Arrow-like data in Python Strata graphs.

    Raises:
        Error if capsule creation fails.
    """
    var fn_val = func
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    return _allocate_descriptor_capsule(
        NativeStageDescriptor(
            NATIVE_KIND_ARROW_FLOAT64, 0, fn_opaque, ctx, ctx_deleter
        )
    )


def export_arrow_int_stage_capsule(
    func: NativeArrowIntFn,
    ctx: Optional[OpaquePointer[MutUntrackedOrigin]] = None,
    ctx_deleter: Optional[NativeCtxDeleter] = None,
) raises -> PythonObject:
    """Export a columnar Arrow `Int64` buffer kernel as a `strata.native_stage.v1` PyCapsule.

    The callback receives `(in_ptr, out_ptr, length, ctx)` with the Python GIL
    released and writes `length` elements into `out_ptr`, returning `0` on
    success, `-4` on `Int64` overflow, or any other non-zero status code on failure.

    Args:
        func: C-ABI function pointer operating on contiguous `Int64` buffers.
        ctx: Optional opaque context pointer outliving the capsule.
        ctx_deleter: Optional C-ABI destructor called with `ctx` on capsule teardown.

    Returns:
        A CPython `PyCapsule` runnable GIL-free on Arrow-like data in Python Strata graphs.

    Raises:
        Error if capsule creation fails.
    """
    var fn_val = func
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    return _allocate_descriptor_capsule(
        NativeStageDescriptor(
            NATIVE_KIND_ARROW_INT64, 0, fn_opaque, ctx, ctx_deleter
        )
    )
