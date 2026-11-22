"""Python interoperability module for task group execution and GIL-free native stages."""

from std.atomic import Atomic
from std.benchmark import keep
from std.ffi import _Global, c_int, c_long
from std.memory import OpaquePointer
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc
from std.os import abort
from std.python import Python, PythonObject
from std.python._cpython import (
    GILAcquired,
    GILReleased,
    Py_ssize_t,
    PyObjectPtr,
    PyType_Slot,
)
from std.python.bindings import PythonModuleBuilder
from std.python.python_object import _unsafe_init
from std.runtime._asyncrt import TaskGroup as TG
from std.sys.info import num_logical_cores


comptime NATIVE_STAGE_CAPSULE_NAME = StaticString("strata.native_stage.v1")
"""PyCapsule name identifying a Strata C-ABI v1 native stage descriptor."""

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

comptime _OP_CAPSULE: Int32 = 0
comptime _OP_INT_LINEAR: Int32 = 1
comptime _OP_FLOAT_LINEAR: Int32 = 2
comptime _OP_FLOAT_POLY: Int32 = 3
comptime _OP_CPU_WORK: Int32 = 4

comptime _NATIVE_STATUS_OVERFLOW: Int32 = -4
comptime _PY_TP_CALL: c_int = 50

comptime _PLAN_ALL_NATIVE: Int32 = 0
comptime _PLAN_ALL_PYTHON: Int32 = 1
comptime _PLAN_HYBRID: Int32 = 2

comptime _ENTRY_NATIVE_CHAIN: Int32 = 0
comptime _ENTRY_PY_CALLABLE: Int32 = 1
comptime _ENTRY_NESTED_GROUP: Int32 = 2

comptime _STACK_PAR_LIMIT: Int = 16

comptime _PyCallOneArgFn = def(PyObjectPtr, PyObjectPtr) thin abi("C") -> PyObjectPtr
comptime _PySetRaisedExcFn = def(PyObjectPtr) thin abi("C") -> None


def _dummy_call_one_arg(a: PyObjectPtr, b: PyObjectPtr) abi("C") -> PyObjectPtr:
    return PyObjectPtr()


def _dummy_set_raised_exc(exc: PyObjectPtr) abi("C"):
    pass


struct _PyCapiCache(Movable):
    var has_call_one_arg: Bool
    var call_one_arg: _PyCallOneArgFn
    var has_set_raised_exc: Bool
    var set_raised_exc: _PySetRaisedExcFn

    def __init__(out self):
        ref cpython = Python().cpython()
        if cpython.lib.check_symbol("PyObject_CallOneArg"):
            self.has_call_one_arg = True
            self.call_one_arg = cpython.lib.borrow().get_function[
                _PyCallOneArgFn
            ]("PyObject_CallOneArg")
        else:
            self.has_call_one_arg = False
            self.call_one_arg = _dummy_call_one_arg

        if cpython.lib.check_symbol("PyErr_SetRaisedException"):
            self.has_set_raised_exc = True
            self.set_raised_exc = cpython.lib.borrow().get_function[
                _PySetRaisedExcFn
            ]("PyErr_SetRaisedException")
        else:
            self.has_set_raised_exc = False
            self.set_raised_exc = _dummy_set_raised_exc


def _init_capi_cache() -> _PyCapiCache:
    return _PyCapiCache()


comptime _CAPI_CACHE = _Global[
    StorageType=_PyCapiCache,
    "STRATA_PY_CAPI_CACHE",
    _init_capi_cache,
]

comptime NativeIntFn = def(
    Int64, Optional[OpaquePointer[MutUntrackedOrigin]]
) thin abi("C") -> Int64
"""C-ABI function signature for `Int64 -> Int64` GIL-free native stages."""

comptime NativeFloatFn = def(
    Float64, Optional[OpaquePointer[MutUntrackedOrigin]]
) thin abi("C") -> Float64
"""C-ABI function signature for `Float64 -> Float64` GIL-free native stages."""

comptime NativeValueFn = def(
    Pointer[NativeValue, ImmUntrackedOrigin],
    Pointer[NativeValue, MutUntrackedOrigin],
    Optional[OpaquePointer[MutUntrackedOrigin]],
) thin abi("C") -> Int32
"""C-ABI function signature for general `NativeValue -> NativeValue` native stages."""

comptime NativeCtxDeleter = def(
    OpaquePointer[MutUntrackedOrigin]
) thin abi("C") -> None
"""C-ABI callback signature invoked on PyCapsule destruction to free heap `ctx`."""


@fieldwise_init
struct NativeValue(Copyable, Defaultable, Movable, TrivialRegisterPassable):
    """C-ABI tagged scalar value passed between GIL-free native stages."""

    var kind: Int32
    """Value tag (`NATIVE_VAL_INT64`, `NATIVE_VAL_FLOAT64`, or `NATIVE_VAL_BOOL`)."""
    var _pad: Int32
    """Alignment padding for C ABI compatibility."""
    var int_val: Int64
    """Integer or boolean (0/1) payload."""
    var float_val: Float64
    """IEEE-754 float64 payload."""

    def __init__(out self):
        """Construct a zeroed `Int64` native value."""
        self.kind = NATIVE_VAL_INT64
        self._pad = 0
        self.int_val = 0
        self.float_val = 0.0

    @staticmethod
    def from_int(v: Int64) -> Self:
        """Construct an `Int64` native value.

        Args:
            v: Integer value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_INT64, 0, v, 0.0)

    @staticmethod
    def from_float(v: Float64) -> Self:
        """Construct a `Float64` native value.

        Args:
            v: Floating-point value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_FLOAT64, 0, 0, v)

    @staticmethod
    def from_bool(v: Bool) -> Self:
        """Construct a `Bool` native value.

        Args:
            v: Boolean value.

        Returns:
            Tagged `NativeValue`.
        """
        return Self(NATIVE_VAL_BOOL, 0, Int64(1) if v else Int64(0), 0.0)


@fieldwise_init
struct NativeStageDescriptor(Copyable, Defaultable, Movable):
    """C-ABI descriptor stored inside a `strata.native_stage.v1` PyCapsule."""

    var kind: Int32
    """Stage signature kind (`NATIVE_KIND_INT64`, `NATIVE_KIND_FLOAT64`, or `NATIVE_KIND_VALUE`)."""
    var _pad: Int32
    """Alignment padding for C ABI compatibility."""
    var fn_ptr: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Raw C-ABI function pointer matching `kind`."""
    var ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
    """Optional opaque user context pointer passed to `fn_ptr`."""
    var ctx_deleter: Optional[NativeCtxDeleter]
    """Optional C-ABI destructor invoked on `ctx` when the owning PyCapsule is freed."""

    def __init__(out self):
        """Construct an empty descriptor."""
        self.kind = NATIVE_KIND_INT64
        self._pad = 0
        self.fn_ptr = None
        self.ctx = None
        self.ctx_deleter = None


struct _CallResult(Movable):
    """Internal result holding either a Python value or a captured exception."""

    var value: PythonObject
    var error: Optional[PythonObject]

    def __init__(out self, var value: PythonObject):
        self.value = value^
        self.error = None

    def __init__(out self, *, var error: PythonObject):
        self.value = PythonObject()
        self.error = error^


struct _NativeEvalResult(
    Copyable, Defaultable, Movable, TrivialRegisterPassable
):
    """Result of executing a native stage or fused native chain without the GIL."""

    var value: NativeValue
    var status: Int32

    def __init__(out self):
        self.value = NativeValue()
        self.status = 0

    def __init__(out self, value: NativeValue, status: Int32):
        self.value = value
        self.status = status


@fieldwise_init
struct _NativeOp(Copyable, Defaultable, Movable, TrivialRegisterPassable):
    """Compact register-passable native execution op (no String or PythonObject refs)."""

    var op_kind: Int32
    var desc_kind: Int32
    var fn_addr: Int
    var ctx_addr: Int
    var i_p0: Int64
    var i_p1: Int64
    var f_p0: Float64
    var f_p1: Float64
    var f_p2: Float64

    def __init__(out self):
        self.op_kind = _OP_CAPSULE
        self.desc_kind = NATIVE_KIND_INT64
        self.fn_addr = 0
        self.ctx_addr = 0
        self.i_p0 = 0
        self.i_p1 = 0
        self.f_p0 = 0.0
        self.f_p1 = 0.0
        self.f_p2 = 0.0

    @staticmethod
    def from_stage(stage: NativeStage) -> Self:
        var fn_addr = 0
        if case .Some(p) = stage.descriptor.fn_ptr:
            fn_addr = Int(p)
        var ctx_addr = 0
        if case .Some(c) = stage.descriptor.ctx:
            ctx_addr = Int(c)
        return Self(
            stage.op_kind,
            stage.descriptor.kind,
            fn_addr,
            ctx_addr,
            stage.i_p0,
            stage.i_p1,
            stage.f_p0,
            stage.f_p1,
            stage.f_p2,
        )

    @staticmethod
    def from_descriptor(desc: NativeStageDescriptor) -> Self:
        var fn_addr = 0
        if case .Some(p) = desc.fn_ptr:
            fn_addr = Int(p)
        var ctx_addr = 0
        if case .Some(c) = desc.ctx:
            ctx_addr = Int(c)
        return Self(
            _OP_CAPSULE,
            desc.kind,
            fn_addr,
            ctx_addr,
            0,
            0,
            0.0,
            0.0,
            0.0,
        )

    @always_inline
    def input_kind(self) -> Int32:
        if self.op_kind == _OP_CAPSULE:
            return self.desc_kind
        if self.op_kind == _OP_INT_LINEAR or self.op_kind == _OP_CPU_WORK:
            return NATIVE_KIND_INT64
        return NATIVE_KIND_FLOAT64

    @always_inline
    def is_short_pure_arith(self) -> Bool:
        return (
            self.op_kind == _OP_INT_LINEAR
            or self.op_kind == _OP_FLOAT_LINEAR
            or self.op_kind == _OP_FLOAT_POLY
        )

    @always_inline
    def eval_native(self, input: NativeValue) -> _NativeEvalResult:
        if self.op_kind == _OP_INT_LINEAR:
            return _checked_int_linear(self.i_p0, self.i_p1, input.int_val)

        if self.op_kind == _OP_FLOAT_LINEAR:
            return _NativeEvalResult(
                NativeValue.from_float(self.f_p0 * input.float_val + self.f_p1),
                0,
            )

        if self.op_kind == _OP_FLOAT_POLY:
            var x = input.float_val
            var y = (self.f_p2 * x + self.f_p1) * x + self.f_p0
            return _NativeEvalResult(NativeValue.from_float(y), 0)

        if self.op_kind == _OP_CPU_WORK:
            var state = UInt64(input.int_val) ^ UInt64(0x9E3779B97F4A7C15)
            var iters = Int(self.i_p0)
            for _ in range(iters):
                state = (
                    state * UInt64(6364136223846793005)
                    + UInt64(1442695040888963407)
                )
                state ^= state >> 29
            return _NativeEvalResult(
                NativeValue.from_int(Int64(state & UInt64(0x7FFFFFFFFFFFFFFF))),
                0,
            )

        if self.fn_addr == 0:
            return _NativeEvalResult(NativeValue(), -1)

        var raw_fn = OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=self.fn_addr
        )
        var ctx_opt: Optional[OpaquePointer[MutUntrackedOrigin]] = None
        if self.ctx_addr != 0:
            ctx_opt = OpaquePointer[MutUntrackedOrigin](
                unsafe_from_address=self.ctx_addr
            )

        if self.desc_kind == NATIVE_KIND_INT64:
            var builtin_cap_fn: NativeIntFn = _capsule_int_linear_fn
            var builtin_cap_opaque = Pointer(to=builtin_cap_fn).unsafe_bitcast[
                OpaquePointer[MutUntrackedOrigin]
            ]()[]
            if self.fn_addr == Int(builtin_cap_opaque):
                if case .Some(raw_ctx) = ctx_opt:
                    var p = raw_ctx.unsafe_bitcast[_IntLinearCtx]()
                    return _checked_int_linear(
                        p[].scale, p[].bias, input.int_val
                    )
                return _NativeEvalResult(
                    NativeValue.from_int(input.int_val), 0
                )
            var int_fn = Pointer(to=raw_fn).unsafe_bitcast[NativeIntFn]()[]
            var out_i = int_fn(input.int_val, ctx_opt)
            return _NativeEvalResult(NativeValue.from_int(out_i), 0)

        if self.desc_kind == NATIVE_KIND_FLOAT64:
            var flt_fn = Pointer(to=raw_fn).unsafe_bitcast[NativeFloatFn]()[]
            var out_f = flt_fn(input.float_val, ctx_opt)
            return _NativeEvalResult(NativeValue.from_float(out_f), 0)

        var val_fn = Pointer(to=raw_fn).unsafe_bitcast[NativeValueFn]()[]
        var in_copy = input
        var out_val = NativeValue()
        var in_ptr = Pointer(to=in_copy).as_imm().unsafe_origin_cast[
            ImmUntrackedOrigin
        ]()
        var out_ptr = Pointer(to=out_val).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        var status = val_fn(in_ptr, out_ptr, ctx_opt)
        return _NativeEvalResult(out_val, status)


@fieldwise_init
struct _PlanEntry(Copyable, Defaultable, Movable, TrivialRegisterPassable):
    """Precomputed step or branch descriptor stored inside an immutable `TaskGroup`."""

    var kind: Int32
    var obj_idx: Int32
    var op_start: Int32
    var op_len: Int32
    var input_kind: Int32
    var all_short_arith: Bool

    def __init__(out self):
        self.kind = _ENTRY_PY_CALLABLE
        self.obj_idx = 0
        self.op_start = 0
        self.op_len = 0
        self.input_kind = NATIVE_KIND_INT64
        self.all_short_arith = False


def _eval_native_ops(
    ops_base: Pointer[_NativeOp, ImmUntrackedOrigin],
    op_start: Int,
    op_len: Int,
    input: NativeValue,
) -> _NativeEvalResult:
    """Evaluate a contiguous slice of `_NativeOp`s completely GIL-free."""
    var cur = input
    for offset in range(op_len):
        var op = ops_base[unsafe_offset=op_start + offset]
        if offset > 0:
            var coerced = _coerce_native_value(cur, op.input_kind())
            if coerced[1] != 0:
                return _NativeEvalResult(NativeValue(), coerced[1])
            cur = coerced[0]
        var res = op.eval_native(cur)
        if res.status != 0:
            return res
        cur = res.value
    return _NativeEvalResult(cur, 0)


def _restore_raised_exception(exc_ptr: PyObjectPtr):
    """Set CPython's active exception pointer directly (stealing `exc_ptr`)."""
    try:
        var cache = _CAPI_CACHE.get_or_create_ptr()
        if cache[].has_set_raised_exc:
            cache[].set_raised_exc(exc_ptr)
            return
    except:
        pass
    ref cpython = Python().cpython()
    if Bool(exc_ptr):
        var exc_type = cpython.PyObject_Type(exc_ptr)
        cpython.PyErr_Restore(exc_type, exc_ptr, PyObjectPtr())
    else:
        cpython.PyErr_Clear()


def _get_exc_global(exc_name: String) -> PyObjectPtr:
    """Look up a CPython `PyExc_*` global pointer without importing `builtins`."""
    ref cpython = Python().cpython()
    if exc_name == "TypeError":
        return cpython.get_error_global("PyExc_TypeError")
    if exc_name == "ValueError":
        return cpython.get_error_global("PyExc_ValueError")
    if exc_name == "OverflowError":
        return cpython.get_error_global("PyExc_OverflowError")
    if exc_name == "RuntimeError":
        return cpython.get_error_global("PyExc_RuntimeError")
    return cpython.get_error_global("PyExc_Exception")


def _make_py_error(exc_name: String, message: String) -> PythonObject:
    """Create a Python exception instance directly via CPython C-API while holding the GIL."""
    ref cpython = Python().cpython()
    var exc_type = _get_exc_global(exc_name)
    var msg_ptr = cpython.PyUnicode_DecodeUTF8(message)
    if Bool(msg_ptr):
        var msg_obj = PythonObject(from_owned=msg_ptr)
        try:
            var cache = _CAPI_CACHE.get_or_create_ptr()
            if cache[].has_call_one_arg:
                var exc_ptr = cache[].call_one_arg(exc_type, msg_obj._obj_ptr)
                if Bool(exc_ptr):
                    return PythonObject(from_owned=exc_ptr)
                var raised_ptr = cpython.PyErr_GetRaisedException()
                if Bool(raised_ptr):
                    return PythonObject(from_owned=raised_ptr)
        except:
            pass

    # Fallback: construct exception via PyErr_SetString + PyErr_GetRaisedException
    var msg_copy = message
    cpython.PyErr_SetString(exc_type, msg_copy.as_c_string_span().ptr())
    var fallback_ptr = cpython.PyErr_GetRaisedException()
    if Bool(fallback_ptr):
        return PythonObject(from_owned=fallback_ptr)
    return PythonObject(from_owned=PyObjectPtr())


def _extract_int64_arg(
    py_val: PythonObject, arg_name: String
) -> Tuple[Int64, Optional[PythonObject]]:
    """Extract an `Int64` argument while rejecting `bool` and preserving `OverflowError`."""
    ref cpython = Python().cpython()
    var ptr = py_val._obj_ptr
    if cpython.PyBool_Check(ptr) != 0 or cpython.PyLong_Check(ptr) == 0:
        return (
            Int64(0),
            _make_py_error(
                "TypeError",
                String("Expected an int for '", arg_name, "'"),
            ),
        )
    var v = cpython.PyLong_AsSsize_t(ptr)
    if v == Py_ssize_t(-1) and cpython.PyErr_Occurred():
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return (Int64(0), PythonObject(from_owned=exc_ptr))
    return (Int64(v), None)


def _checked_int_linear(
    scale: Int64, bias: Int64, x: Int64
) -> _NativeEvalResult:
    """Evaluate `scale * x + bias` in `Int128` and report `Int64` overflow."""
    var acc = Int128(scale) * Int128(x) + Int128(bias)
    if acc < Int128(Int64.MIN) or acc > Int128(Int64.MAX):
        return _NativeEvalResult(NativeValue(), _NATIVE_STATUS_OVERFLOW)
    return _NativeEvalResult(NativeValue.from_int(Int64(acc)), 0)


def _unbox_for_native(
    py_val: PythonObject, expected_kind: Int32
) -> Tuple[NativeValue, Optional[PythonObject]]:
    """Unbox a Python scalar into `NativeValue` while holding the GIL."""
    ref cpython = Python().cpython()
    var ptr = py_val._obj_ptr

    if expected_kind == NATIVE_KIND_INT64:
        if cpython.PyBool_Check(ptr) != 0 or cpython.PyLong_Check(ptr) == 0:
            return (
                NativeValue(),
                _make_py_error(
                    "TypeError",
                    "NativeStage (int) expected an int input",
                ),
            )
        var v = cpython.PyLong_AsSsize_t(ptr)
        if v == Py_ssize_t(-1) and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return (NativeValue(), PythonObject(from_owned=exc_ptr))
        return (NativeValue.from_int(Int64(v)), None)

    if expected_kind == NATIVE_KIND_FLOAT64:
        if cpython.PyBool_Check(ptr) != 0 or (
            cpython.PyFloat_Check(ptr) == 0 and cpython.PyLong_Check(ptr) == 0
        ):
            return (
                NativeValue(),
                _make_py_error(
                    "TypeError",
                    "NativeStage (float) expected a float or int input",
                ),
            )
        var d = cpython.PyFloat_AsDouble(ptr)
        if d == -1.0 and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return (NativeValue(), PythonObject(from_owned=exc_ptr))
        return (NativeValue.from_float(Float64(d)), None)

    # NATIVE_KIND_VALUE accepts bool, int, or float
    if cpython.PyBool_Check(ptr) != 0:
        var b = cpython.PyLong_AsSsize_t(ptr)
        return (NativeValue.from_bool(b != 0), None)
    if cpython.PyLong_Check(ptr) != 0:
        var v = cpython.PyLong_AsSsize_t(ptr)
        if v == Py_ssize_t(-1) and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return (NativeValue(), PythonObject(from_owned=exc_ptr))
        return (NativeValue.from_int(Int64(v)), None)
    if cpython.PyFloat_Check(ptr) != 0:
        var d = cpython.PyFloat_AsDouble(ptr)
        if d == -1.0 and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return (NativeValue(), PythonObject(from_owned=exc_ptr))
        return (NativeValue.from_float(Float64(d)), None)

    return (
        NativeValue(),
        _make_py_error(
            "TypeError",
            "NativeStage (value) expected bool, int, or float input",
        ),
    )


def _box_from_native(val: NativeValue) -> _CallResult:
    """Box a `NativeValue` back into a `PythonObject` while holding the GIL."""
    ref cpython = Python().cpython()
    var obj_ptr: PyObjectPtr
    if val.kind == NATIVE_VAL_BOOL:
        obj_ptr = cpython.PyBool_FromLong(
            c_long(1) if val.int_val != 0 else c_long(0)
        )
    elif val.kind == NATIVE_VAL_FLOAT64:
        obj_ptr = cpython.PyFloat_FromDouble(val.float_val)
    elif val.kind == NATIVE_VAL_INT64:
        obj_ptr = cpython.PyLong_FromSsize_t(Py_ssize_t(val.int_val))
    else:
        return _CallResult(
            error=_make_py_error(
                "ValueError",
                String("Unknown NativeValue kind: ", val.kind),
            )
        )

    if not obj_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))
    return _CallResult(PythonObject(from_owned=obj_ptr))


def _coerce_native_value(
    val: NativeValue, expected_kind: Int32
) -> Tuple[NativeValue, Int32]:
    """Coerce a `NativeValue` between consecutive fused native stages without GIL."""
    if expected_kind == NATIVE_KIND_VALUE:
        return (val.copy(), 0)
    if expected_kind == NATIVE_KIND_INT64:
        if val.kind == NATIVE_VAL_INT64:
            return (NativeValue.from_int(val.int_val), 0)
        return (NativeValue(), -2)
    if expected_kind == NATIVE_KIND_FLOAT64:
        if val.kind == NATIVE_VAL_FLOAT64:
            return (val.copy(), 0)
        if val.kind == NATIVE_VAL_INT64:
            return (NativeValue.from_float(Float64(val.int_val)), 0)
        return (NativeValue(), -2)
    return (NativeValue(), -3)


def _native_status_to_error(status: Int32) -> PythonObject:
    """Convert a non-zero native stage error code to a Python exception."""
    if status == _NATIVE_STATUS_OVERFLOW:
        return _make_py_error(
            "OverflowError",
            "Int64 overflow in NativeStage",
        )
    if status == -2:
        return _make_py_error(
            "TypeError",
            "Incompatible types between consecutive fused NativeStages",
        )
    if status == -1:
        return _make_py_error(
            "RuntimeError",
            "NativeStage descriptor has null function pointer",
        )
    return _make_py_error(
        "RuntimeError",
        String("NativeStage failed with status code ", status),
    )


struct NativeStage(Copyable, Movable, Writable):
    """GIL-free Mojo or C-ABI native pipeline stage runnable inside `TaskGroup`."""

    var name: String
    """Human-readable stage name for introspection and tracing."""
    var op_kind: Int32
    """Built-in kernel opcode or `0` for an external PyCapsule descriptor."""
    var descriptor: NativeStageDescriptor
    """C-ABI function descriptor when `op_kind == 0`."""
    var capsule_ref: Optional[PythonObject]
    """Strong reference keeping the backing `PyCapsule` alive."""
    var i_p0: Int64
    """First integer kernel parameter."""
    var i_p1: Int64
    """Second integer kernel parameter."""
    var f_p0: Float64
    """First float64 kernel parameter."""
    var f_p1: Float64
    """Second float64 kernel parameter."""
    var f_p2: Float64
    """Third float64 kernel parameter."""

    def __init__(
        out self,
        var name: String,
        op_kind: Int32,
        descriptor: NativeStageDescriptor,
        var capsule_ref: Optional[PythonObject],
        i_p0: Int64 = 0,
        i_p1: Int64 = 0,
        f_p0: Float64 = 0.0,
        f_p1: Float64 = 0.0,
        f_p2: Float64 = 0.0,
    ):
        """Construct a `NativeStage` descriptor.

        Args:
            name: Stage display name.
            op_kind: Kernel opcode (`0` for capsule, `1..4` for built-ins).
            descriptor: C-ABI descriptor used when `op_kind == 0`.
            capsule_ref: Optional strong reference to the owning `PyCapsule`.
            i_p0: First integer parameter.
            i_p1: Second integer parameter.
            f_p0: First float64 parameter.
            f_p1: Second float64 parameter.
            f_p2: Third float64 parameter.
        """
        self.name = name^
        self.op_kind = op_kind
        self.descriptor = descriptor.copy()
        self.capsule_ref = capsule_ref^
        self.i_p0 = i_p0
        self.i_p1 = i_p1
        self.f_p0 = f_p0
        self.f_p1 = f_p1
        self.f_p2 = f_p2

    def input_kind(self) -> Int32:
        """Return the expected native input kind tag.

        Returns:
            One of `NATIVE_KIND_INT64`, `NATIVE_KIND_FLOAT64`, or `NATIVE_KIND_VALUE`.
        """
        if self.op_kind == _OP_CAPSULE:
            return self.descriptor.kind
        if self.op_kind == _OP_INT_LINEAR or self.op_kind == _OP_CPU_WORK:
            return NATIVE_KIND_INT64
        return NATIVE_KIND_FLOAT64

    def kind_name(self) -> String:
        """Return a human-readable string for the stage's ABI kind.

        Returns:
            `"int"`, `"float"`, or `"value"`.
        """
        var k = self.input_kind()
        if k == NATIVE_KIND_INT64:
            return "int"
        if k == NATIVE_KIND_FLOAT64:
            return "float"
        return "value"

    def eval_native(self, input: NativeValue) -> _NativeEvalResult:
        """Execute this native stage completely GIL-free.

        Args:
            input: Pre-unboxed `NativeValue`.

        Returns:
            `_NativeEvalResult` containing output value and status code (`0` = ok).
        """
        return _NativeOp.from_stage(self).eval_native(input)

    def _call_result(self, msg: PythonObject) -> _CallResult:
        var op = _NativeOp.from_stage(self)
        var unboxed = _unbox_for_native(msg, op.input_kind())
        if case .Some(exc) = unboxed[1]:
            return _CallResult(error=exc)
        var in_val = unboxed[0]
        var eval_res: _NativeEvalResult
        if op.is_short_pure_arith():
            eval_res = op.eval_native(in_val)
        else:
            with GILReleased(Python()):
                eval_res = op.eval_native(in_val)
        if eval_res.status != 0:
            return _CallResult(error=_native_status_to_error(eval_res.status))
        return _box_from_native(eval_res.value)

    def write_to(self, mut writer: Some[Writer]):
        """Write a concise representation of this `NativeStage`.

        Args:
            writer: Output writer.
        """
        writer.write("NativeStage(", self.name, ", kind=", self.kind_name(), ")")

    def write_repr_to(self, mut writer: Some[Writer]):
        """Write a debug representation of this `NativeStage`.

        Args:
            writer: Output writer.
        """
        self.write_to(writer)

    def __repr__(self) -> String:
        """Return string representation of this `NativeStage`.

        Returns:
            Human-readable string representation.
        """
        return String("NativeStage(", self.name, ", kind=", self.kind_name(), ")")

    @staticmethod
    def py_init(
        out self: Self, args: PythonObject, kwargs: PythonObject
    ) raises:
        """Disallow direct unconfigured construction from Python.

        Args:
            args: Positional arguments.
            kwargs: Keyword arguments.

        Returns:
            Never returns; always raises an error.

        Raises:
            Error instructing callers to use factory constructors.
        """
        raise (
            "Use mojo_strata.native_from_capsule or built-in native_* "
            "factories to construct a NativeStage."
        )

    @staticmethod
    def call(
        self_ptr: Pointer[Self, MutAnyOrigin], v: PythonObject
    ) raises -> PythonObject:
        """Execute this native stage on `v` without holding the GIL.

        Args:
            self_ptr: Pointer to self.
            v: Input Python scalar.

        Returns:
            Result Python scalar.

        Raises:
            Error on invalid input type or native execution failure.
        """
        var res = self_ptr[]._call_result(v)
        if case .Some(exc) = res.error:
            return _restore_python_exception(exc)
        return res.value

    @staticmethod
    def get_name(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return this native stage's name.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python string containing the stage name.

        Raises:
            Error if Python string construction fails.
        """
        return PythonObject(self_ptr[].name)

    @staticmethod
    def get_kind(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return this native stage's ABI input kind string.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python string (`"int"`, `"float"`, or `"value"`).

        Raises:
            Error if Python string construction fails.
        """
        return PythonObject(self_ptr[].kind_name())

    @staticmethod
    def is_gil_free(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return `True`, indicating this stage executes without the GIL.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python `True`.

        Raises:
            Error if Python bool conversion fails.
        """
        return PythonObject(True)

    @staticmethod
    def map_list(
        self_ptr: Pointer[Self, MutAnyOrigin],
        items: PythonObject,
        max_concurrency: PythonObject,
    ) raises -> PythonObject:
        """Execute this native stage over a Python iterable completely GIL-free.

        Uses atomic work-stealing (`W - 1` Mojo worker tasks plus the caller thread)
        with a single GIL release and returns a Python `list` in input order.

        Args:
            self_ptr: Pointer to self.
            items: Python iterable of scalar inputs matching this stage's ABI kind.
            max_concurrency: Maximum concurrent workers (`0` = default core count, `1` = sequential).

        Returns:
            Python `list` of transformed outputs in input order.

        Raises:
            Error if `max_concurrency` is invalid or input unboxing / evaluation fails.
        """
        var op = _NativeOp.from_stage(self_ptr[])
        var ops = List[_NativeOp](capacity=1)
        ops.append(op)
        var out = _map_native_ops_py(
            ops, op.is_short_pure_arith(), items, max_concurrency
        )
        keep(self_ptr[])
        return out^


def _try_stage_from_capsule(
    obj: PythonObject, name: String = "native_capsule"
) -> Optional[NativeStage]:
    """Extract a `NativeStage` if `obj` is a valid `strata.native_stage.v1` capsule."""
    ref cpython = Python().cpython()
    if not cpython.PyCapsule_IsValid(
        obj._obj_ptr, String(NATIVE_STAGE_CAPSULE_NAME)
    ):
        return None
    try:
        var raw_ptr = cpython.PyCapsule_GetPointer(
            obj._obj_ptr, String(NATIVE_STAGE_CAPSULE_NAME)
        )
        var desc_ptr = raw_ptr.unsafe_bitcast[NativeStageDescriptor]()
        var desc = desc_ptr[].copy()
        return NativeStage(name, _OP_CAPSULE, desc, obj)
    except:
        return None


def _try_extract_native_stage(obj: PythonObject) -> Optional[NativeStage]:
    """Return a `NativeStage` if `obj` is a `NativeStage` or valid capsule."""
    try:
        if case .Some(ns_ptr) = obj._try_downcast_value[NativeStage]():
            return ns_ptr[].copy()
    except:
        pass
    return _try_stage_from_capsule(obj)


def _try_append_native_ops(
    obj: PythonObject, mut out_ops: List[_NativeOp]
) -> Bool:
    """Append compact `_NativeOp`s if `obj` is a NativeStage, valid capsule, or pure-native serial TaskGroup."""
    try:
        if case .Some(ns_ptr) = obj._try_downcast_value[NativeStage]():
            out_ops.append(_NativeOp.from_stage(ns_ptr[]))
            return True
    except:
        pass

    try:
        if case .Some(grp_ptr) = obj._try_downcast_value[TaskGroup]():
            if grp_ptr[].is_pure_native_serial():
                for op in grp_ptr[]._plan_ops:
                    out_ops.append(op)
                return True
            return False
    except:
        pass

    ref cpython = Python().cpython()
    if cpython.PyCapsule_IsValid(
        obj._obj_ptr, String(NATIVE_STAGE_CAPSULE_NAME)
    ):
        try:
            var raw_ptr = cpython.PyCapsule_GetPointer(
                obj._obj_ptr, String(NATIVE_STAGE_CAPSULE_NAME)
            )
            var desc_ptr = raw_ptr.unsafe_bitcast[NativeStageDescriptor]()
            out_ops.append(_NativeOp.from_descriptor(desc_ptr[]))
            return True
        except:
            return False
    return False


def _is_nested_task_group(obj: PythonObject) -> Bool:
    """Return `True` if `obj` is a `mojo_strata.TaskGroup` instance."""
    try:
        if case .Some(_) = obj._try_downcast_value[TaskGroup]():
            return True
    except:
        pass
    return False


def _invoke_py_callable(task: PythonObject, msg: PythonObject) -> _CallResult:
    """Invoke a plain Python callable directly via cached `PyObject_CallOneArg`.

    Must be called while holding the GIL. `PyObject_CallOneArg` borrows `msg`.
    """
    ref cpython = Python().cpython()
    var res_ptr = PyObjectPtr()
    var used_fast = False
    try:
        var cache = _CAPI_CACHE.get_or_create_ptr()
        if cache[].has_call_one_arg:
            res_ptr = cache[].call_one_arg(task._obj_ptr, msg._obj_ptr)
            used_fast = True
    except:
        pass
    if not used_fast:
        var args_ptr = cpython.PyTuple_New(1)
        if not args_ptr:
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _CallResult(error=PythonObject(from_owned=exc_ptr))
        var msg_owned = msg
        _ = cpython.PyTuple_SetItem(args_ptr, 0, msg_owned^.steal_data())
        var args = PythonObject(from_owned=args_ptr)
        res_ptr = cpython.PyObject_CallObject(task._obj_ptr, args._obj_ptr)

    if not res_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))
    return _CallResult(PythonObject(from_owned=res_ptr))


def _invoke_nested_group(task: PythonObject, msg: PythonObject) -> _CallResult:
    """Invoke a pre-classified nested `TaskGroup` directly while holding the GIL."""
    try:
        if case .Some(grp_ptr) = task._try_downcast_value[TaskGroup]():
            return grp_ptr[]._call_result(msg)
    except:
        pass
    return _invoke_py_callable(task, msg)


def _invoke_py(task: PythonObject, msg: PythonObject) -> _CallResult:
    """Invoke a Python callable, NativeStage, or nested TaskGroup while preserving exceptions.

    Must be called while holding the GIL.
    """
    try:
        if case .Some(grp_ptr) = task._try_downcast_value[TaskGroup]():
            return grp_ptr[]._call_result(msg)
    except:
        pass

    if case .Some(native) = _try_extract_native_stage(task):
        return native._call_result(msg)

    return _invoke_py_callable(task, msg)


def _restore_python_exception(var exc: PythonObject) -> PythonObject:
    """Set CPython's error indicator to `exc` and return a NULL PythonObject.

    Must be called while holding the GIL right before returning to CPython.
    Uses `PyErr_SetRaisedException` directly so restoration remains resilient
    even under `RecursionError` or `MemoryError`.
    """
    ref cpython = Python().cpython()
    if Bool(exc._obj_ptr):
        _restore_raised_exception(exc^.steal_data())
        return PythonObject(from_owned=PyObjectPtr())
    var err_type = cpython.get_error_global("PyExc_RuntimeError")
    var fallback_msg = String("Failed to propagate Python exception")
    cpython.PyErr_SetString(err_type, fallback_msg.as_c_string_span().ptr())
    return PythonObject(from_owned=PyObjectPtr())


def _tp_call_native_stage(
    py_self_ptr: PyObjectPtr,
    args_ptr: PyObjectPtr,
    kwargs_ptr: PyObjectPtr,
) abi("C") -> PyObjectPtr:
    """CPython `tp_call` slot making `mojo_strata.NativeStage` directly callable."""
    ref cpython = Python().cpython()
    if Bool(kwargs_ptr) and cpython.PyObject_Length(kwargs_ptr) > 0:
        var err_type = cpython.get_error_global("PyExc_TypeError")
        var msg = String("NativeStage.__call__() takes no keyword arguments")
        cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
        return PyObjectPtr()
    if cpython.PyObject_Length(args_ptr) != 1:
        var err_type = cpython.get_error_global("PyExc_TypeError")
        var msg = String(
            "NativeStage.__call__() takes exactly 1 positional argument"
        )
        cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
        return PyObjectPtr()
    var py_self = PythonObject(from_borrowed=py_self_ptr)
    var arg_ptr = cpython.PyTuple_GetItem(args_ptr, 0)
    if not arg_ptr:
        return PyObjectPtr()
    var arg = PythonObject(from_borrowed=arg_ptr)
    try:
        if case .Some(ns_ptr) = py_self._try_downcast_value[NativeStage]():
            var res = ns_ptr[]._call_result(arg)
            if case .Some(exc) = res.error:
                _ = _restore_python_exception(exc)
                return PyObjectPtr()
            var out = res.value
            return out^.steal_data()
    except e:
        var err_type = cpython.get_error_global("PyExc_RuntimeError")
        var msg = String(e)
        cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
        return PyObjectPtr()
    var err_type = cpython.get_error_global("PyExc_TypeError")
    var msg = String("Expected a mojo_strata.NativeStage instance")
    cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
    return PyObjectPtr()


def _tp_init_task_group(
    py_self_ptr: PyObjectPtr,
    args_ptr: PyObjectPtr,
    kwargs_ptr: PyObjectPtr,
) abi("C") -> c_int:
    """CPython `tp_init` slot for `TaskGroup` with strict arg validation and `TypeError`."""
    ref cpython = Python().cpython()
    var n_args = cpython.PyObject_Length(args_ptr)
    var n_kwargs = cpython.PyObject_Length(kwargs_ptr) if Bool(kwargs_ptr) else 0
    if n_args < 0 or n_kwargs < 0:
        return -1

    var task_obj: PythonObject
    if n_args == 1 and n_kwargs == 0:
        var arg0 = cpython.PyTuple_GetItem(args_ptr, 0)
        if not arg0:
            return -1
        task_obj = PythonObject(from_borrowed=arg0)
    elif n_args == 0 and n_kwargs == 1:
        var kwargs = PythonObject(from_borrowed=kwargs_ptr)
        try:
            var key = PythonObject("task")
            if key not in kwargs:
                var err_type = cpython.get_error_global("PyExc_TypeError")
                var msg = String(
                    "TaskGroup() got an unexpected keyword argument"
                )
                cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
                return -1
            task_obj = kwargs[key]
        except:
            if not cpython.PyErr_Occurred():
                var err_type = cpython.get_error_global("PyExc_TypeError")
                var msg = String("TaskGroup() invalid keyword arguments")
                cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
            return -1
    else:
        var err_type = cpython.get_error_global("PyExc_TypeError")
        var msg = String("TaskGroup() takes exactly 1 argument ('task')")
        cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
        return -1

    try:
        _unsafe_init(py_self_ptr, TaskGroup(task=task_obj))
        return 0
    except e:
        var err_type = cpython.get_error_global("PyExc_RuntimeError")
        var msg = String(e)
        cpython.PyErr_SetString(err_type, msg.as_c_string_span().ptr())
        return -1


__async def _run_py_callable_task(
    task_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    msg_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    out_ptr: Pointer[PythonObject, MutUntrackedOrigin],
    err_ptr: Pointer[Optional[PythonObject], MutUntrackedOrigin],
):
    with GILAcquired(Python()):
        var res = _invoke_py_callable(task_ptr[], msg_ptr[])
        if case .Some(exc) = res.error:
            err_ptr[] = exc
        else:
            out_ptr[] = res.value


__async def _run_nested_group_task(
    task_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    msg_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    out_ptr: Pointer[PythonObject, MutUntrackedOrigin],
    err_ptr: Pointer[Optional[PythonObject], MutUntrackedOrigin],
):
    with GILAcquired(Python()):
        var res = _invoke_nested_group(task_ptr[], msg_ptr[])
        if case .Some(exc) = res.error:
            err_ptr[] = exc
        else:
            out_ptr[] = res.value


__async def _run_native_ops_task(
    ops_base: Pointer[_NativeOp, ImmUntrackedOrigin],
    op_start: Int,
    op_len: Int,
    input: NativeValue,
    out_ptr: Pointer[_NativeEvalResult, MutUntrackedOrigin],
):
    # Executes 100% GIL-free on Mojo's asyncrt worker pool.
    out_ptr[] = _eval_native_ops(ops_base, op_start, op_len, input)


__async def _run_native_map_worker(
    ops_base: Pointer[_NativeOp, ImmUntrackedOrigin],
    op_len: Int,
    in_base: Pointer[NativeValue, ImmUntrackedOrigin],
    out_base: Pointer[_NativeEvalResult, MutUntrackedOrigin],
    next_ptr: Pointer[Atomic[Int64], MutUntrackedOrigin],
    n: Int,
):
    while True:
        var idx = Int(next_ptr[].fetch_add(1))
        if idx >= n:
            break
        out_base[unsafe_offset=idx] = _eval_native_ops(
            ops_base, 0, op_len, in_base[unsafe_offset=idx]
        )


def _map_native_ops_py(
    ops: List[_NativeOp],
    all_short_arith: Bool,
    items: PythonObject,
    max_concurrency_obj: PythonObject,
) -> PythonObject:
    """Execute a pure-native `_NativeOp` chain across a Python iterable GIL-free."""
    ref cpython = Python().cpython()
    var mc_ptr = max_concurrency_obj._obj_ptr
    if cpython.PyBool_Check(mc_ptr) != 0 or cpython.PyLong_Check(mc_ptr) == 0:
        return _restore_python_exception(
            _make_py_error(
                "TypeError",
                "map_list() max_concurrency must be an int (>= 0)",
            )
        )
    var mc_raw = cpython.PyLong_AsSsize_t(mc_ptr)
    if mc_raw == Py_ssize_t(-1) and cpython.PyErr_Occurred():
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _restore_python_exception(PythonObject(from_owned=exc_ptr))
    var max_conc = Int(mc_raw)
    if max_conc < 0:
        return _restore_python_exception(
            _make_py_error(
                "ValueError",
                "map_list() max_concurrency must be >= 0",
            )
        )

    var iter_ptr = cpython.PyObject_GetIter(items._obj_ptr)
    if not iter_ptr:
        return PythonObject(from_owned=PyObjectPtr())
    var iter_obj = PythonObject(from_owned=iter_ptr)

    var cap_hint = Int(cpython.PyObject_Length(items._obj_ptr))
    if cap_hint < 0:
        cpython.PyErr_Clear()
        cap_hint = 0

    var inputs = List[NativeValue](capacity=cap_hint)
    var expected_kind = ops[0].input_kind()
    while True:
        var next_item_ptr = cpython.PyIter_Next(iter_obj._obj_ptr)
        if not next_item_ptr:
            if cpython.PyErr_Occurred():
                return PythonObject(from_owned=PyObjectPtr())
            break
        var item_obj = PythonObject(from_owned=next_item_ptr)
        var unboxed = _unbox_for_native(item_obj, expected_kind)
        if case .Some(exc) = unboxed[1]:
            return _restore_python_exception(exc)
        inputs.append(unboxed[0])

    var n = len(inputs)
    if n == 0:
        var empty_ptr = cpython.PyList_New(0)
        if not empty_ptr:
            return PythonObject(from_owned=PyObjectPtr())
        return PythonObject(from_owned=empty_ptr)

    var op_len = len(ops)
    var ops_base = ops.unsafe_ptr().as_imm().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]()
    var in_base = inputs.unsafe_ptr().as_imm().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]()
    var outputs = List[_NativeEvalResult](unsafe_uninit_length=n)
    var out_base = outputs.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()

    var workers = min(max_conc, n) if max_conc > 0 else min(
        max(num_logical_cores(), 1), n
    )
    if workers <= 1 or n == 1:
        if all_short_arith and n <= 64:
            for i in range(n):
                out_base[unsafe_offset=i] = _eval_native_ops(
                    ops_base, 0, op_len, in_base[unsafe_offset=i]
                )
        else:
            with GILReleased(Python()):
                for i in range(n):
                    out_base[unsafe_offset=i] = _eval_native_ops(
                        ops_base, 0, op_len, in_base[unsafe_offset=i]
                    )
    else:
        var next_idx = Atomic[Int64](0)
        var next_ptr = Pointer(to=next_idx).unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        with GILReleased(Python()):
            var tg = TG()
            for _ in range(workers - 1):
                tg.create_task(
                    _run_native_map_worker(
                        ops_base, op_len, in_base, out_base, next_ptr, n
                    )
                )
            while True:
                var idx = Int(next_idx.fetch_add(1))
                if idx >= n:
                    break
                out_base[unsafe_offset=idx] = _eval_native_ops(
                    ops_base, 0, op_len, in_base[unsafe_offset=idx]
                )
            tg.wait()
        keep(ops)
        keep(inputs)
        keep(outputs)
        keep(next_idx)

    var list_ptr = cpython.PyList_New(Py_ssize_t(n))
    if not list_ptr:
        return PythonObject(from_owned=PyObjectPtr())
    for i in range(n):
        var eval_res = outputs[i]
        if eval_res.status != 0:
            _ = PythonObject(from_owned=list_ptr)
            return _restore_python_exception(
                _native_status_to_error(eval_res.status)
            )
        var boxed = _box_from_native(eval_res.value)
        if case .Some(exc) = boxed.error:
            _ = PythonObject(from_owned=list_ptr)
            return _restore_python_exception(exc)
        var val_obj = boxed.value
        _ = cpython.PyList_SetItem(
            list_ptr, Py_ssize_t(i), val_obj^.steal_data()
        )
    return PythonObject(from_owned=list_ptr)


# ===----------------------------------------------------------------------=== #
# Capsule & Factory Helpers Exported to Python
# ===----------------------------------------------------------------------=== #


struct _IntLinearCtx(Copyable, Movable):
    var scale: Int64
    var bias: Int64

    def __init__(out self, scale: Int64, bias: Int64):
        self.scale = scale
        self.bias = bias


def _capsule_int_linear_fn(
    x: Int64, ctx: Optional[OpaquePointer[MutUntrackedOrigin]]
) abi("C") -> Int64:
    if case .Some(raw_ctx) = ctx:
        var p = raw_ctx.unsafe_bitcast[_IntLinearCtx]()
        var acc = Int128(p[].scale) * Int128(x) + Int128(p[].bias)
        return Int64(acc)
    return x


def _delete_int_linear_ctx(raw_ctx: OpaquePointer[MutUntrackedOrigin]) abi("C"):
    dealloc(
        ThinAllocation(
            unsafe_owned_ptr=raw_ctx.unsafe_bitcast[_IntLinearCtx]()
        ).unsafe_with_layout(Layout[_IntLinearCtx].single())
    )


def _destroy_int_linear_capsule(capsule: PyObjectPtr) abi("C"):
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
        elif case .Some(raw_ctx) = desc_ptr[].ctx:
            _delete_int_linear_ctx(raw_ctx)
        dealloc(
            ThinAllocation(
                unsafe_owned_ptr=desc_ptr
            ).unsafe_with_layout(Layout[NativeStageDescriptor].single())
        )
    except:
        pass
    _restore_raised_exception(saved_exc)


def native_from_capsule(
    capsule: PythonObject, name: PythonObject
) raises -> PythonObject:
    """Wrap a `strata.native_stage.v1` PyCapsule into a GIL-free `NativeStage`.

    Args:
        capsule: CPython `PyCapsule` named `"strata.native_stage.v1"`.
        name: Human-readable stage name string.

    Returns:
        A `mojo_strata.NativeStage` executing the capsule without the GIL.

    Raises:
        Error if `capsule` is not a valid `strata.native_stage.v1` PyCapsule.
    """
    var stage_name = String(py=name)
    if case .Some(stage) = _try_stage_from_capsule(capsule, stage_name):
        var owned_stage = stage.copy()
        return PythonObject(alloc=owned_stage^)
    return _restore_python_exception(
        _make_py_error(
            "TypeError",
            "Expected a valid PyCapsule named 'strata.native_stage.v1'",
        )
    )


def native_int_linear(
    scale: PythonObject, bias: PythonObject, name: PythonObject
) raises -> PythonObject:
    """Construct a built-in GIL-free integer linear stage (`scale * x + bias`).

    Args:
        scale: Integer multiplier.
        bias: Integer offset.
        name: Stage display name.

    Returns:
        A `mojo_strata.NativeStage` for `int -> int`.

    Raises:
        Error if argument conversion fails.
    """
    var s_res = _extract_int64_arg(scale, "scale")
    if case .Some(exc) = s_res[1]:
        return _restore_python_exception(exc)
    var b_res = _extract_int64_arg(bias, "bias")
    if case .Some(exc) = b_res[1]:
        return _restore_python_exception(exc)
    var s = s_res[0]
    var b = b_res[0]
    var stage_name = String(py=name)
    var stage = NativeStage(
        stage_name^,
        _OP_INT_LINEAR,
        NativeStageDescriptor(),
        None,
        i_p0=s,
        i_p1=b,
    )
    return PythonObject(alloc=stage^)


def native_float_linear(
    scale: PythonObject, bias: PythonObject, name: PythonObject
) raises -> PythonObject:
    """Construct a built-in GIL-free float64 linear stage (`scale * x + bias`).

    Args:
        scale: Float64 multiplier.
        bias: Float64 offset.
        name: Stage display name.

    Returns:
        A `mojo_strata.NativeStage` for `float -> float`.

    Raises:
        Error if argument conversion fails.
    """
    var s = Float64(py=scale)
    var b = Float64(py=bias)
    var stage_name = String(py=name)
    var stage = NativeStage(
        stage_name^,
        _OP_FLOAT_LINEAR,
        NativeStageDescriptor(),
        None,
        f_p0=s,
        f_p1=b,
    )
    return PythonObject(alloc=stage^)


def native_float_poly(
    c0: PythonObject, c1: PythonObject, c2: PythonObject, name: PythonObject
) raises -> PythonObject:
    """Construct a built-in GIL-free quadratic stage (`c2*x^2 + c1*x + c0`).

    Args:
        c0: Constant coefficient.
        c1: Linear coefficient.
        c2: Quadratic coefficient.
        name: Stage display name.

    Returns:
        A `mojo_strata.NativeStage` for `float -> float`.

    Raises:
        Error if argument conversion fails.
    """
    var p0 = Float64(py=c0)
    var p1 = Float64(py=c1)
    var p2 = Float64(py=c2)
    var stage_name = String(py=name)
    var stage = NativeStage(
        stage_name^,
        _OP_FLOAT_POLY,
        NativeStageDescriptor(),
        None,
        f_p0=p0,
        f_p1=p1,
        f_p2=p2,
    )
    return PythonObject(alloc=stage^)


def native_cpu_work(
    iterations: PythonObject, name: PythonObject
) raises -> PythonObject:
    """Construct a deterministic GIL-free Mojo CPU kernel (`int -> int`).

    Args:
        iterations: Number of 64-bit mixing iterations to perform per call.
        name: Stage display name.

    Returns:
        A `mojo_strata.NativeStage` performing pure-Mojo arithmetic without the GIL.

    Raises:
        Error if argument conversion fails.
    """
    var iters = Int64(Int(py=iterations))
    if iters < 0:
        iters = 0
    var stage_name = String(py=name)
    var stage = NativeStage(
        stage_name^,
        _OP_CPU_WORK,
        NativeStageDescriptor(),
        None,
        i_p0=iters,
    )
    return PythonObject(alloc=stage^)


def make_int_linear_capsule(
    scale: PythonObject, bias: PythonObject
) raises -> PythonObject:
    """Create a `strata.native_stage.v1` PyCapsule implementing `scale * x + bias`.

    Args:
        scale: Integer multiplier.
        bias: Integer offset.

    Returns:
        A CPython `PyCapsule` conforming to the `strata.native_stage.v1` ABI.

    Raises:
        Error if argument conversion or capsule allocation fails.
    """
    var s_res = _extract_int64_arg(scale, "scale")
    if case .Some(exc) = s_res[1]:
        return _restore_python_exception(exc)
    var b_res = _extract_int64_arg(bias, "bias")
    if case .Some(exc) = b_res[1]:
        return _restore_python_exception(exc)
    var s = s_res[0]
    var b = b_res[0]
    var ctx_alloc = alloc(Layout[_IntLinearCtx].single())
    var ctx_ptr = ctx_alloc^.unsafe_leak()
    ctx_ptr.write(_IntLinearCtx(s, b))
    var desc_alloc = alloc(Layout[NativeStageDescriptor].single())
    var desc_ptr = desc_alloc^.unsafe_leak()
    var fn_val: NativeIntFn = _capsule_int_linear_fn
    var fn_opaque = Pointer(to=fn_val).unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]()[]
    desc_ptr.write(
        NativeStageDescriptor(
            NATIVE_KIND_INT64,
            0,
            fn_opaque,
            ctx_ptr.unsafe_bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),
            Optional[NativeCtxDeleter](_delete_int_linear_ctx),
        )
    )
    ref cpython = Python().cpython()
    var cap_ptr = cpython.PyCapsule_New(
        desc_ptr.unsafe_bitcast[NoneType]().unsafe_origin_cast[
            MutUntrackedOrigin
        ](),
        NATIVE_STAGE_CAPSULE_NAME,
        _destroy_int_linear_capsule,
    )
    if not cap_ptr:
        dealloc(
            ThinAllocation(unsafe_owned_ptr=ctx_ptr).unsafe_with_layout(
                Layout[_IntLinearCtx].single()
            )
        )
        dealloc(
            ThinAllocation(unsafe_owned_ptr=desc_ptr).unsafe_with_layout(
                Layout[NativeStageDescriptor].single()
            )
        )
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _restore_python_exception(PythonObject(from_owned=exc_ptr))
    return PythonObject(from_owned=cap_ptr)


@export
def PyInit_mojo_strata() abi("C") -> PythonObject:
    """Initialize the CPython extension module for mojo_strata.

    Returns:
        The initialized Python module object.
    """
    try:
        _ = _CAPI_CACHE.get_or_create_ptr()
        var strata = PythonModuleBuilder("mojo_strata")

        ref tg_builder = (
            strata.add_type[TaskGroup]("mojo_strata.TaskGroup")
            .def_staticmethod[TaskGroup.from_tasks](
                "from_tasks",
                "Build a TaskGroup from a sequence of tasks and mode (0 serial, 1 parallel) in O(N).",
            )
            .def_method[TaskGroup.with_task](
                "with_task",
                "Return a new TaskGroup with an additional task without mutating self.",
            )
            .def_method[TaskGroup.call]("call", "Execute this task group.")
            .def_method[TaskGroup.get_mode](
                "get_mode",
                "Return this task group's execution mode (-1 undefined, 0 serial, 1 parallel).",
            )
            .def_method[TaskGroup.get_tasks](
                "get_tasks",
                "Return a shallow Python list of tasks contained in this group.",
            )
            .def_method[TaskGroup.is_pure_native](
                "is_pure_native",
                "Return True if this TaskGroup is a pure-native serial chain supporting GIL-free map_list.",
            )
            .def_method[TaskGroup.map_list](
                "map_list",
                "Execute a pure-native serial TaskGroup over an iterable completely GIL-free.",
            )
        )
        tg_builder._insert_slot(PyType_Slot.tp_init(_tp_init_task_group))

        ref ns_builder = (
            strata.add_type[NativeStage]("mojo_strata.NativeStage")
            .def_py_init[NativeStage.py_init]()
            .def_method[NativeStage.call](
                "call", "Execute this native stage without holding the GIL."
            )
            .def_method[NativeStage.get_name](
                "get_name", "Return this native stage's name."
            )
            .def_method[NativeStage.get_kind](
                "get_kind", "Return this native stage's ABI input kind."
            )
            .def_method[NativeStage.is_gil_free](
                "is_gil_free", "Return True for GIL-free native stages."
            )
            .def_method[NativeStage.map_list](
                "map_list",
                "Execute this native stage over an iterable completely GIL-free.",
            )
        )
        var ns_call_fn = _tp_call_native_stage
        var ns_call_opaque = Pointer(to=ns_call_fn).unsafe_bitcast[
            OpaquePointer[MutUntrackedOrigin]
        ]()[]
        ns_builder._insert_slot(PyType_Slot(_PY_TP_CALL, ns_call_opaque))

        strata.def_function[native_from_capsule](
            "native_from_capsule",
            "Wrap a strata.native_stage.v1 PyCapsule into a NativeStage.",
        )
        strata.def_function[native_int_linear](
            "native_int_linear",
            "Create a GIL-free integer linear NativeStage (scale * x + bias).",
        )
        strata.def_function[native_float_linear](
            "native_float_linear",
            "Create a GIL-free float64 linear NativeStage (scale * x + bias).",
        )
        strata.def_function[native_float_poly](
            "native_float_poly",
            "Create a GIL-free quadratic float64 NativeStage (c2*x^2 + c1*x + c0).",
        )
        strata.def_function[native_cpu_work](
            "native_cpu_work",
            "Create a deterministic GIL-free Mojo CPU compute NativeStage.",
        )
        strata.def_function[make_int_linear_capsule](
            "make_int_linear_capsule",
            "Create a strata.native_stage.v1 PyCapsule implementing scale * x + bias.",
        )

        var mod = strata.finalize()
        var builtins = Python.import_module("builtins")
        var tg_type = mod.__getattr__("mojo_strata.TaskGroup")
        mod.TaskGroup = tg_type
        _ = builtins.delattr(mod, "mojo_strata.TaskGroup")
        var ns_type = mod.__getattr__("mojo_strata.NativeStage")
        mod.NativeStage = ns_type
        _ = builtins.delattr(mod, "mojo_strata.NativeStage")
        return mod
    except e:
        abort(String("failed to create Python module: ", e))


struct TaskGroup(Movable, Writable):
    """Python-interoperable task group managing serial or parallel task pipelines."""

    comptime undefined = TaskGroup(-1)
    """Undefined group mode constant."""
    comptime Serial = TaskGroup(0)
    """Serial execution group mode constant."""
    comptime Parallel = TaskGroup(1)
    """Parallel execution group mode constant."""

    var mode: Int
    """Execution mode of the task group (-1: undefined, 0: serial, 1: parallel)."""
    var objects: List[PythonObject]
    """List of task PythonObjects in the group."""
    var _plan_kind: Int32
    """Precomputed dispatch plan tag (`_PLAN_ALL_NATIVE`, `_PLAN_ALL_PYTHON`, or `_PLAN_HYBRID`)."""
    var _plan_ops: List[_NativeOp]
    """Flattened compact native operations referenced by `_plan_entries`."""
    var _plan_entries: List[_PlanEntry]
    """Precomputed serial segments or parallel branches."""
    var _all_same_input_kind: Int32
    """Shared input kind across all native branches in `ALL_NATIVE` parallel mode, or `-1`."""

    def __init__(out self, task: PythonObject):
        """Construct a TaskGroup with a single initial task.

        Args:
            task: Initial Python task object.
        """
        self.mode = -1
        self.objects = [task]
        self._plan_kind = _PLAN_ALL_PYTHON
        self._plan_ops = List[_NativeOp]()
        self._plan_entries = List[_PlanEntry]()
        self._all_same_input_kind = -1
        self._rebuild_plan()

    def __init__(out self, mode: Int):
        """Construct an empty TaskGroup with a specific execution mode.

        Args:
            mode: Mode integer (0 for serial, 1 for parallel).
        """
        self.mode = mode
        self.objects = []
        self._plan_kind = _PLAN_ALL_PYTHON
        self._plan_ops = List[_NativeOp]()
        self._plan_entries = List[_PlanEntry]()
        self._all_same_input_kind = -1

    def copy(self, out o: Self):
        """Copy the TaskGroup.

        Returns:
            A cloned copy of this TaskGroup.
        """
        o = Self(mode=self.mode)
        o.objects = self.objects.copy()
        o._plan_kind = self._plan_kind
        o._plan_ops = self._plan_ops.copy()
        o._plan_entries = self._plan_entries.copy()
        o._all_same_input_kind = self._all_same_input_kind

    def is_pure_native_serial(self) -> Bool:
        """Return `True` if this group is a pure-native serial or single-stage chain.

        Returns:
            `True` when every child is a pure-native stage/serial group and mode is serial or undefined.
        """
        return (
            self._plan_kind == _PLAN_ALL_NATIVE
            and (
                self.mode == Self.Serial.mode
                or self.mode == Self.undefined.mode
            )
            and len(self._plan_ops) > 0
        )

    def _rebuild_plan(mut self):
        """Eagerly precompute the immutable execution plan for this TaskGroup."""
        self._plan_ops.clear()
        self._plan_entries.clear()
        self._all_same_input_kind = -1

        var count = len(self.objects)
        if count == 0:
            self._plan_kind = _PLAN_ALL_PYTHON
            return

        if self.mode == Self.Serial.mode or self.mode == Self.undefined.mode:
            var has_native = False
            var has_python = False
            var idx = 0
            while idx < count:
                var op_start = len(self._plan_ops)
                if _try_append_native_ops(self.objects[idx], self._plan_ops):
                    has_native = True
                    var next_idx = idx + 1
                    # Fuse maximal contiguous native runs at construction time
                    while next_idx < count:
                        if _try_append_native_ops(
                            self.objects[next_idx], self._plan_ops
                        ):
                            next_idx += 1
                        else:
                            break
                    var op_len = len(self._plan_ops) - op_start
                    var short_arith = True
                    for k in range(op_start, op_start + op_len):
                        if not self._plan_ops[k].is_short_pure_arith():
                            short_arith = False
                            break
                    self._plan_entries.append(
                        _PlanEntry(
                            _ENTRY_NATIVE_CHAIN,
                            Int32(idx),
                            Int32(op_start),
                            Int32(op_len),
                            self._plan_ops[op_start].input_kind(),
                            short_arith,
                        )
                    )
                    idx = next_idx
                else:
                    has_python = True
                    var entry_kind = (
                        _ENTRY_NESTED_GROUP if _is_nested_task_group(
                            self.objects[idx]
                        ) else _ENTRY_PY_CALLABLE
                    )
                    self._plan_entries.append(
                        _PlanEntry(
                            entry_kind,
                            Int32(idx),
                            0,
                            0,
                            NATIVE_KIND_INT64,
                            False,
                        )
                    )
                    idx += 1

            if has_native and not has_python:
                self._plan_kind = _PLAN_ALL_NATIVE
                self._all_same_input_kind = self._plan_entries[0].input_kind
            elif has_python and not has_native:
                self._plan_kind = _PLAN_ALL_PYTHON
            else:
                self._plan_kind = _PLAN_HYBRID
            return

        # Parallel mode: one entry per branch in self.objects
        var has_native = False
        var has_python = False
        var shared_kind: Int32 = -2
        for idx in range(count):
            var op_start = len(self._plan_ops)
            if _try_append_native_ops(self.objects[idx], self._plan_ops):
                has_native = True
                var op_len = len(self._plan_ops) - op_start
                var in_kind = self._plan_ops[op_start].input_kind()
                if shared_kind == -2:
                    shared_kind = in_kind
                elif shared_kind != in_kind:
                    shared_kind = -1
                var short_arith = True
                for k in range(op_start, op_start + op_len):
                    if not self._plan_ops[k].is_short_pure_arith():
                        short_arith = False
                        break
                self._plan_entries.append(
                    _PlanEntry(
                        _ENTRY_NATIVE_CHAIN,
                        Int32(idx),
                        Int32(op_start),
                        Int32(op_len),
                        in_kind,
                        short_arith,
                    )
                )
            else:
                has_python = True
                var entry_kind = (
                    _ENTRY_NESTED_GROUP if _is_nested_task_group(
                        self.objects[idx]
                    ) else _ENTRY_PY_CALLABLE
                )
                self._plan_entries.append(
                    _PlanEntry(
                        entry_kind,
                        Int32(idx),
                        0,
                        0,
                        NATIVE_KIND_INT64,
                        False,
                    )
                )

        if has_native and not has_python:
            self._plan_kind = _PLAN_ALL_NATIVE
            self._all_same_input_kind = shared_kind if shared_kind >= 0 else -1
        elif has_python and not has_native:
            self._plan_kind = _PLAN_ALL_PYTHON
        else:
            self._plan_kind = _PLAN_HYBRID

    def write_to(self, mut writer: Some[Writer]):
        """Write a concise representation of this `TaskGroup`.

        Args:
            writer: Output writer.
        """
        writer.write(self.__repr__())

    def write_repr_to(self, mut writer: Some[Writer]):
        """Write a debug representation of this `TaskGroup`.

        Args:
            writer: Output writer.
        """
        writer.write(self.__repr__())

    def __repr__(self) -> String:
        """Return string representation of the TaskGroup.

        Returns:
            A string describing mode and contained tasks.
        """
        var objs = "[" + String(", ").join(self.objects) + "]"
        var mode = (
            "undefined" if self.mode
            == Self.undefined.mode else "Serial" if self.mode
            == Self.Serial.mode else "Parallel"
        )
        return String("TaskGroup(mode:", mode, ", objects:", objs, ")")

    def _append_parallel_or_single(
        mut self, t: PythonObject, mode: Int
    ) raises:
        if mode == Self.Parallel.mode:
            if case .Some(rhs_ptr) = t._try_downcast_value[TaskGroup]():
                if rhs_ptr[].mode == Self.Parallel.mode:
                    for obj in rhs_ptr[].objects:
                        self.objects.append(obj)
                    return
        self.objects.append(t)

    def _add_task(mut self, t: PythonObject, mode: Int) raises:
        if self.mode == Self.undefined.mode:
            self.mode = mode

        if self.mode == mode:
            self._append_parallel_or_single(t, mode)
            self._rebuild_plan()
            return

        var new_group = TaskGroup(mode=mode)
        new_group.objects.append(PythonObject(alloc=self.copy()))
        new_group._append_parallel_or_single(t, mode)
        new_group._rebuild_plan()
        self = new_group^

    def _with_task(self, t: PythonObject, mode: Int) raises -> Self:
        var cloned = self.copy()
        cloned._add_task(t, mode)
        return cloned^

    @staticmethod
    def _build_exception_group(failed: List[PythonObject]) -> _CallResult:
        if len(failed) == 1:
            return _CallResult(error=failed[0])
        try:
            var builtins = Python.import_module("builtins")
            var py_errs = Python.list()
            for exc in failed:
                _ = py_errs.append(exc)
            var group = builtins.BaseExceptionGroup(
                "Parallel task failures", py_errs
            )
            return _CallResult(error=group^)
        except:
            return _CallResult(error=failed[0])

    def _call_parallel_all_native(self, msg: PythonObject) -> _CallResult:
        """Ultra-fast zero-Python-list path for `ALL_NATIVE` parallel fan-outs."""
        var count = len(self._plan_entries)
        var ops_base = self._plan_ops.unsafe_ptr().as_imm().unsafe_origin_cast[
            ImmUntrackedOrigin
        ]()

        # Deduplicated unboxing (1 unbox when all branches share input_kind)
        var has_kind_val = Array[Bool, 3](fill=False)
        var kind_vals = Array[NativeValue, 3](fill=NativeValue())

        if self._all_same_input_kind >= 0:
            var k = Int(self._all_same_input_kind)
            var unboxed = _unbox_for_native(msg, self._all_same_input_kind)
            if case .Some(exc) = unboxed[1]:
                # Preserve PEP 654 per-branch exception semantics (count errors)
                if count == 1:
                    return _CallResult(error=exc)
                var failed = List[PythonObject](capacity=count)
                failed.append(exc)
                for _ in range(1, count):
                    var dup = _unbox_for_native(msg, self._all_same_input_kind)
                    if case .Some(e2) = dup[1]:
                        failed.append(e2)
                return Self._build_exception_group(failed)
            has_kind_val[k] = True
            kind_vals[k] = unboxed[0]
        else:
            for idx in range(count):
                var k = Int(self._plan_entries[idx].input_kind)
                if not has_kind_val[k]:
                    var unboxed = _unbox_for_native(
                        msg, self._plan_entries[idx].input_kind
                    )
                    if case .Some(_) = unboxed[1]:
                        # Mixed-kind partial unboxing failure: fall back to general
                        # parallel path so valid branches & per-branch errors match exactly.
                        return self._call_parallel_general(msg)
                    has_kind_val[k] = True
                    kind_vals[k] = unboxed[0]

        if count == 1:
            var e0 = self._plan_entries[0]
            var in0 = kind_vals[Int(e0.input_kind)]
            var eval0: _NativeEvalResult
            with GILReleased(Python()):
                eval0 = _eval_native_ops(
                    ops_base, Int(e0.op_start), Int(e0.op_len), in0
                )
            keep(self)
            keep(msg)
            if eval0.status != 0:
                return _CallResult(error=_native_status_to_error(eval0.status))
            var boxed0 = _box_from_native(eval0.value)
            if case .Some(exc) = boxed0.error:
                return _CallResult(error=exc)
            ref cpython = Python().cpython()
            var tp_ptr = cpython.PyTuple_New(1)
            if not tp_ptr:
                var exc_ptr = cpython.PyErr_GetRaisedException()
                return _CallResult(error=PythonObject(from_owned=exc_ptr))
            var item0 = boxed0.value
            _ = cpython.PyTuple_SetItem(tp_ptr, 0, item0^.steal_data())
            return _CallResult(PythonObject(from_owned=tp_ptr))

        var last = count - 1
        if count <= _STACK_PAR_LIMIT:
            var res_arr = Array[_NativeEvalResult, _STACK_PAR_LIMIT](
                fill=_NativeEvalResult()
            )
            var res_base = Pointer(to=res_arr[0]).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            with GILReleased(Python()):
                var tg = TG()
                for idx in range(last):
                    var entry = self._plan_entries[idx]
                    tg.create_task(
                        _run_native_ops_task(
                            ops_base,
                            Int(entry.op_start),
                            Int(entry.op_len),
                            kind_vals[Int(entry.input_kind)],
                            res_base.unsafe_offset(idx),
                        )
                    )
                var last_entry = self._plan_entries[last]
                res_arr[last] = _eval_native_ops(
                    ops_base,
                    Int(last_entry.op_start),
                    Int(last_entry.op_len),
                    kind_vals[Int(last_entry.input_kind)],
                )
                tg.wait()
            keep(self)
            keep(msg)

            var has_err = False
            for idx in range(count):
                if res_arr[idx].status != 0:
                    has_err = True
                    break
            if has_err:
                var failed = List[PythonObject]()
                for idx in range(count):
                    if res_arr[idx].status != 0:
                        failed.append(
                            _native_status_to_error(res_arr[idx].status)
                        )
                return Self._build_exception_group(failed)

            ref cpython = Python().cpython()
            var tp_ptr = cpython.PyTuple_New(Py_ssize_t(count))
            if not tp_ptr:
                var exc_ptr = cpython.PyErr_GetRaisedException()
                return _CallResult(error=PythonObject(from_owned=exc_ptr))
            for idx in range(count):
                var boxed = _box_from_native(res_arr[idx].value)
                if case .Some(exc) = boxed.error:
                    _ = PythonObject(from_owned=tp_ptr)
                    return _CallResult(error=exc)
                var item = boxed.value
                _ = cpython.PyTuple_SetItem(
                    tp_ptr, Py_ssize_t(idx), item^.steal_data()
                )
            return _CallResult(PythonObject(from_owned=tp_ptr))

        # Heap path for count > 16
        var res_list = List[_NativeEvalResult](unsafe_uninit_length=count)
        var res_base = res_list.unsafe_ptr().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        with GILReleased(Python()):
            var tg = TG()
            for idx in range(last):
                var entry = self._plan_entries[idx]
                tg.create_task(
                    _run_native_ops_task(
                        ops_base,
                        Int(entry.op_start),
                        Int(entry.op_len),
                        kind_vals[Int(entry.input_kind)],
                        res_base.unsafe_offset(idx),
                    )
                )
            var last_entry = self._plan_entries[last]
            res_base[unsafe_offset=last] = _eval_native_ops(
                ops_base,
                Int(last_entry.op_start),
                Int(last_entry.op_len),
                kind_vals[Int(last_entry.input_kind)],
            )
            tg.wait()
        keep(self)
        keep(msg)
        keep(res_list)

        var has_err = False
        for idx in range(count):
            if res_list[idx].status != 0:
                has_err = True
                break
        if has_err:
            var failed = List[PythonObject]()
            for idx in range(count):
                if res_list[idx].status != 0:
                    failed.append(_native_status_to_error(res_list[idx].status))
            return Self._build_exception_group(failed)

        ref cpython = Python().cpython()
        var tp_ptr = cpython.PyTuple_New(Py_ssize_t(count))
        if not tp_ptr:
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _CallResult(error=PythonObject(from_owned=exc_ptr))
        for idx in range(count):
            var boxed = _box_from_native(res_list[idx].value)
            if case .Some(exc) = boxed.error:
                _ = PythonObject(from_owned=tp_ptr)
                return _CallResult(error=exc)
            var item = boxed.value
            _ = cpython.PyTuple_SetItem(
                tp_ptr, Py_ssize_t(idx), item^.steal_data()
            )
        return _CallResult(PythonObject(from_owned=tp_ptr))

    def _call_parallel_general(self, msg: PythonObject) -> _CallResult:
        """Parallel dispatch for `ALL_PYTHON`, `HYBRID`, or mixed-unbox-error groups."""
        var count = len(self._plan_entries)
        var values = List[PythonObject](length=count, fill=PythonObject())
        var errors = List[Optional[PythonObject]](length=count, fill=None)
        var native_inputs = List[NativeValue](
            length=count, fill=NativeValue()
        )
        var native_results = List[_NativeEvalResult](
            length=count, fill=_NativeEvalResult()
        )
        var has_spawned = List[Bool](length=count, fill=False)

        for idx in range(count):
            var entry = self._plan_entries[idx]
            if entry.kind == _ENTRY_NATIVE_CHAIN:
                var unboxed = _unbox_for_native(msg, entry.input_kind)
                if case .Some(exc) = unboxed[1]:
                    errors[idx] = exc
                else:
                    native_inputs[idx] = unboxed[0]
                    has_spawned[idx] = True
            else:
                has_spawned[idx] = True

        var tg = TG()
        var msg_ptr = Pointer(to=msg).unsafe_origin_cast[ImmUntrackedOrigin]()
        var ops_base = self._plan_ops.unsafe_ptr().as_imm().unsafe_origin_cast[
            ImmUntrackedOrigin
        ]()

        for idx in range(count):
            if not has_spawned[idx]:
                continue
            var entry = self._plan_entries[idx]
            if entry.kind == _ENTRY_NATIVE_CHAIN:
                var o_ptr = Pointer(to=native_results[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                tg.create_task(
                    _run_native_ops_task(
                        ops_base,
                        Int(entry.op_start),
                        Int(entry.op_len),
                        native_inputs[idx],
                        o_ptr,
                    )
                )
            elif entry.kind == _ENTRY_NESTED_GROUP:
                var t_ptr = Pointer(
                    to=self.objects[Int(entry.obj_idx)]
                ).unsafe_origin_cast[ImmUntrackedOrigin]()
                var out_ptr = Pointer(to=values[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                var err_ptr = Pointer(to=errors[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                tg.create_task(
                    _run_nested_group_task(t_ptr, msg_ptr, out_ptr, err_ptr)
                )
            else:
                var t_ptr = Pointer(
                    to=self.objects[Int(entry.obj_idx)]
                ).unsafe_origin_cast[ImmUntrackedOrigin]()
                var out_ptr = Pointer(to=values[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                var err_ptr = Pointer(to=errors[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                tg.create_task(
                    _run_py_callable_task(t_ptr, msg_ptr, out_ptr, err_ptr)
                )

        with GILReleased(Python()):
            tg.wait()

        # Keep buffers referenced by untracked pointers alive across tg.wait().
        keep(self)
        keep(native_inputs)
        keep(msg)

        # Box native outputs back to Python while holding the GIL
        for idx in range(count):
            if (
                self._plan_entries[idx].kind == _ENTRY_NATIVE_CHAIN
                and has_spawned[idx]
            ):
                if native_results[idx].status != 0:
                    errors[idx] = _native_status_to_error(
                        native_results[idx].status
                    )
                else:
                    var boxed = _box_from_native(native_results[idx].value)
                    if case .Some(exc) = boxed.error:
                        errors[idx] = exc
                    else:
                        values[idx] = boxed.value

        var failed = List[PythonObject]()
        for idx in range(count):
            if case .Some(exc) = errors[idx]:
                failed.append(exc)

        if len(failed) > 0:
            return Self._build_exception_group(failed)

        ref cpython = Python().cpython()
        var tp_ptr = cpython.PyTuple_New(Py_ssize_t(count))
        if not tp_ptr:
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _CallResult(error=PythonObject(from_owned=exc_ptr))
        for idx in range(count):
            var item = values[idx]
            _ = cpython.PyTuple_SetItem(
                tp_ptr, Py_ssize_t(idx), item^.steal_data()
            )
        return _CallResult(PythonObject(from_owned=tp_ptr))

    def _call_result(self, msg: PythonObject) -> _CallResult:
        var count = len(self.objects)
        if count == 0:
            return _CallResult(msg)

        if self.mode == Self.undefined.mode:
            if count != 1:
                return _CallResult(
                    error=_make_py_error("ValueError", "Group mode not set up")
                )
            var entry = self._plan_entries[0]
            if entry.kind == _ENTRY_NATIVE_CHAIN:
                var unboxed = _unbox_for_native(msg, entry.input_kind)
                if case .Some(exc) = unboxed[1]:
                    return _CallResult(error=exc)
                var ops_base = self._plan_ops.unsafe_ptr().as_imm().unsafe_origin_cast[
                    ImmUntrackedOrigin
                ]()
                var eval_res: _NativeEvalResult
                if entry.all_short_arith:
                    eval_res = _eval_native_ops(
                        ops_base,
                        Int(entry.op_start),
                        Int(entry.op_len),
                        unboxed[0],
                    )
                else:
                    with GILReleased(Python()):
                        eval_res = _eval_native_ops(
                            ops_base,
                            Int(entry.op_start),
                            Int(entry.op_len),
                            unboxed[0],
                        )
                keep(self)
                if eval_res.status != 0:
                    return _CallResult(
                        error=_native_status_to_error(eval_res.status)
                    )
                return _box_from_native(eval_res.value)
            if entry.kind == _ENTRY_NESTED_GROUP:
                return _invoke_nested_group(self.objects[0], msg)
            return _invoke_py_callable(self.objects[0], msg)

        if self.mode == Self.Serial.mode:
            var iv = msg
            var num_entries = len(self._plan_entries)
            var ops_base = self._plan_ops.unsafe_ptr().as_imm().unsafe_origin_cast[
                ImmUntrackedOrigin
            ]()
            for e_idx in range(num_entries):
                var entry = self._plan_entries[e_idx]
                if entry.kind == _ENTRY_NATIVE_CHAIN:
                    var unboxed = _unbox_for_native(iv, entry.input_kind)
                    if case .Some(exc) = unboxed[1]:
                        return _CallResult(error=exc)
                    var eval_res: _NativeEvalResult
                    if entry.all_short_arith:
                        eval_res = _eval_native_ops(
                            ops_base,
                            Int(entry.op_start),
                            Int(entry.op_len),
                            unboxed[0],
                        )
                    else:
                        with GILReleased(Python()):
                            eval_res = _eval_native_ops(
                                ops_base,
                                Int(entry.op_start),
                                Int(entry.op_len),
                                unboxed[0],
                            )
                    keep(self)
                    if eval_res.status != 0:
                        return _CallResult(
                            error=_native_status_to_error(eval_res.status)
                        )
                    var boxed = _box_from_native(eval_res.value)
                    if case .Some(exc) = boxed.error:
                        return _CallResult(error=exc)
                    iv = boxed.value
                elif entry.kind == _ENTRY_NESTED_GROUP:
                    var res = _invoke_nested_group(
                        self.objects[Int(entry.obj_idx)], iv
                    )
                    if case .Some(exc) = res.error:
                        return _CallResult(error=exc)
                    iv = res.value
                else:
                    var res = _invoke_py_callable(
                        self.objects[Int(entry.obj_idx)], iv
                    )
                    if case .Some(exc) = res.error:
                        return _CallResult(error=exc)
                    iv = res.value
            return _CallResult(iv^)

        if self._plan_kind == _PLAN_ALL_NATIVE:
            return self._call_parallel_all_native(msg)
        return self._call_parallel_general(msg)

    @staticmethod
    def from_tasks(
        tasks: PythonObject, _mode: PythonObject
    ) raises -> PythonObject:
        """Construct a `TaskGroup` from a Python iterable of tasks in O(N).

        Args:
            tasks: Non-empty Python iterable of callables, `NativeStage`s, capsules, or `TaskGroup`s.
            _mode: Execution mode integer (`0` for serial, `1` for parallel).

        Returns:
            A new `TaskGroup` containing all tasks with its execution plan precomputed once.

        Raises:
            Error if `_mode` is not an int in `{0, 1}` or `tasks` is empty/not iterable.
        """
        ref cpython = Python().cpython()
        var mode_ptr = _mode._obj_ptr
        if (
            cpython.PyBool_Check(mode_ptr) != 0
            or cpython.PyLong_Check(mode_ptr) == 0
        ):
            return _restore_python_exception(
                _make_py_error(
                    "TypeError",
                    "TaskGroup.from_tasks() mode must be an int (0 or 1)",
                )
            )
        var mode_raw = cpython.PyLong_AsSsize_t(mode_ptr)
        if mode_raw == Py_ssize_t(-1) and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _restore_python_exception(PythonObject(from_owned=exc_ptr))
        var mode_val = Int(mode_raw)
        if mode_val != Self.Serial.mode and mode_val != Self.Parallel.mode:
            return _restore_python_exception(
                _make_py_error(
                    "ValueError",
                    "TaskGroup.from_tasks() mode must be 0 (serial) or 1 (parallel)",
                )
            )

        var iter_ptr = cpython.PyObject_GetIter(tasks._obj_ptr)
        if not iter_ptr:
            return PythonObject(from_owned=PyObjectPtr())
        var iter_obj = PythonObject(from_owned=iter_ptr)

        var grp = TaskGroup(mode=mode_val)
        while True:
            var item_ptr = cpython.PyIter_Next(iter_obj._obj_ptr)
            if not item_ptr:
                if cpython.PyErr_Occurred():
                    return PythonObject(from_owned=PyObjectPtr())
                break
            var item_obj = PythonObject(from_owned=item_ptr)
            grp._append_parallel_or_single(item_obj, mode_val)

        if len(grp.objects) == 0:
            return _restore_python_exception(
                _make_py_error(
                    "ValueError",
                    "TaskGroup.from_tasks() requires at least one task",
                )
            )
        grp._rebuild_plan()
        return PythonObject(alloc=grp^)

    @staticmethod
    def is_pure_native(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return `True` if this `TaskGroup` is a pure-native serial chain.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python `bool` indicating whether `map_list` can execute this group GIL-free.

        Raises:
            Error if Python bool conversion fails.
        """
        return PythonObject(self_ptr[].is_pure_native_serial())

    @staticmethod
    def map_list(
        self_ptr: Pointer[Self, MutAnyOrigin],
        items: PythonObject,
        max_concurrency: PythonObject,
    ) raises -> PythonObject:
        """Execute a pure-native serial `TaskGroup` over a Python iterable completely GIL-free.

        Args:
            self_ptr: Pointer to self.
            items: Python iterable of scalar inputs matching the chain's first stage ABI kind.
            max_concurrency: Maximum concurrent workers (`0` = default core count, `1` = sequential).

        Returns:
            Python `list` of transformed outputs in input order.

        Raises:
            Error if this group is not a pure-native serial chain or execution fails.
        """
        if not self_ptr[].is_pure_native_serial():
            return _restore_python_exception(
                _make_py_error(
                    "TypeError",
                    "TaskGroup.map_list() requires a pure-native serial TaskGroup",
                )
            )
        var all_short = self_ptr[]._plan_entries[0].all_short_arith
        var out = _map_native_ops_py(
            self_ptr[]._plan_ops, all_short, items, max_concurrency
        )
        keep(self_ptr[])
        return out^

    @staticmethod
    def py_init(
        out self: Self, args: PythonObject, kwargs: PythonObject
    ) raises:
        """Initialize from Python arguments.

        Args:
            args: Positional Python arguments.
            kwargs: Keyword Python arguments.

        Returns:
            The initialized TaskGroup.

        Raises:
            Error if invalid arguments are passed.
        """
        var has_kwargs = Bool(kwargs._obj_ptr)
        var n_kwargs = len(kwargs) if has_kwargs else 0
        var n_args = len(args)
        var task_obj: PythonObject
        if n_args == 1 and n_kwargs == 0:
            task_obj = args[0]
        elif n_args == 0 and n_kwargs == 1 and PythonObject("task") in kwargs:
            task_obj = kwargs[PythonObject("task")]
        else:
            raise "TaskGroup() takes exactly 1 argument ('task')"

        self = Self(task=task_obj)

    @staticmethod
    def with_task(
        self_ptr: Pointer[Self, MutAnyOrigin],
        t: PythonObject,
        _mode: PythonObject,
    ) raises -> PythonObject:
        """Return a new TaskGroup with `t` added, without mutating `self`.

        Args:
            self_ptr: Pointer to self.
            t: Python task to add.
            _mode: Mode integer (0 for serial, 1 for parallel).

        Returns:
            A new TaskGroup PythonObject containing the appended task.

        Raises:
            Error if task addition fails or `_mode` is not an int in `{0, 1}`.
        """
        ref cpython = Python().cpython()
        var mode_ptr = _mode._obj_ptr
        if (
            cpython.PyBool_Check(mode_ptr) != 0
            or cpython.PyLong_Check(mode_ptr) == 0
        ):
            return _restore_python_exception(
                _make_py_error(
                    "TypeError",
                    "TaskGroup.with_task() mode must be an int (0 or 1)",
                )
            )
        var mode_raw = cpython.PyLong_AsSsize_t(mode_ptr)
        if mode_raw == Py_ssize_t(-1) and cpython.PyErr_Occurred():
            var exc_ptr = cpython.PyErr_GetRaisedException()
            return _restore_python_exception(PythonObject(from_owned=exc_ptr))
        var mode_val = Int(mode_raw)
        if mode_val != Self.Serial.mode and mode_val != Self.Parallel.mode:
            return _restore_python_exception(
                _make_py_error(
                    "ValueError",
                    "TaskGroup.with_task() mode must be 0 (serial) or 1 (parallel)",
                )
            )
        var next_group = self_ptr[]._with_task(t, mode_val)
        return PythonObject(alloc=next_group^)

    @staticmethod
    def call(
        self_ptr: Pointer[Self, MutAnyOrigin], v: PythonObject
    ) raises -> PythonObject:
        """Invoke the task group from Python.

        Args:
            self_ptr: Pointer to self.
            v: Input argument.

        Returns:
            Output from group execution.

        Raises:
            Error if execution fails.
        """
        var res = self_ptr[]._call_result(v)
        if case .Some(exc) = res.error:
            return _restore_python_exception(exc)
        return res.value

    @staticmethod
    def get_mode(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return this task group's mode integer to Python.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python int (`-1` undefined, `0` serial, `1` parallel).

        Raises:
            Error if Python conversion fails.
        """
        return PythonObject(self_ptr[].mode)

    @staticmethod
    def get_tasks(
        self_ptr: Pointer[Self, MutAnyOrigin]
    ) raises -> PythonObject:
        """Return a shallow Python list of tasks stored in this group.

        Args:
            self_ptr: Pointer to self.

        Returns:
            Python list of child task objects and nested `TaskGroup`s.

        Raises:
            Error if Python list construction fails.
        """
        var out = Python.list()
        for obj in self_ptr[].objects:
            _ = out.append(obj)
        return out^
