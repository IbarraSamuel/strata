"""Python interoperability module for task group execution and GIL-free native stages."""

from std.benchmark import keep
from std.ffi import c_long
from std.memory import OpaquePointer
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc
from std.os import abort
from std.python import Python, PythonObject
from std.python._cpython import (
    GILAcquired,
    GILReleased,
    Py_ssize_t,
    PyObjectPtr,
)
from std.python.bindings import PythonModuleBuilder
from std.runtime._asyncrt import TaskGroup as TG


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


@fieldwise_init
struct NativeValue(Copyable, Defaultable, Movable):
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

    def __init__(out self):
        """Construct an empty descriptor."""
        self.kind = NATIVE_KIND_INT64
        self._pad = 0
        self.fn_ptr = None
        self.ctx = None


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


struct _NativeEvalResult(Copyable, Defaultable, Movable):
    """Result of executing a native stage or fused native chain without the GIL."""

    var value: NativeValue
    var status: Int32

    def __init__(out self):
        self.value = NativeValue()
        self.status = 0

    def __init__(out self, value: NativeValue, status: Int32):
        self.value = value.copy()
        self.status = status


def _make_py_error(exc_name: String, message: String) -> PythonObject:
    """Create a Python exception instance while holding the GIL."""
    try:
        var builtins = Python.import_module("builtins")
        var exc_cls = builtins.__getattr__(exc_name)
        return exc_cls(message)
    except:
        return PythonObject()


def _unbox_for_native(
    py_val: PythonObject, expected_kind: Int32
) -> Tuple[NativeValue, Optional[PythonObject]]:
    """Unbox a Python scalar into `NativeValue` while holding the GIL."""
    ref cpython = Python().cpython()
    var ptr = py_val._obj_ptr

    if expected_kind == NATIVE_KIND_INT64:
        if cpython.PyLong_Check(ptr) == 0:
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
        if cpython.PyFloat_Check(ptr) == 0 and cpython.PyLong_Check(ptr) == 0:
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
    else:
        obj_ptr = cpython.PyLong_FromSsize_t(Py_ssize_t(val.int_val))

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
        if val.kind == NATIVE_VAL_INT64 or val.kind == NATIVE_VAL_BOOL:
            return (NativeValue.from_int(val.int_val), 0)
        return (NativeValue(), -2)
    if expected_kind == NATIVE_KIND_FLOAT64:
        if val.kind == NATIVE_VAL_FLOAT64:
            return (val.copy(), 0)
        if val.kind == NATIVE_VAL_INT64 or val.kind == NATIVE_VAL_BOOL:
            return (NativeValue.from_float(Float64(val.int_val)), 0)
        return (NativeValue(), -2)
    return (NativeValue(), -3)


def _native_status_to_error(status: Int32) -> PythonObject:
    """Convert a non-zero native stage error code to a Python exception."""
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
        if self.op_kind == _OP_INT_LINEAR:
            return _NativeEvalResult(
                NativeValue.from_int(self.i_p0 * input.int_val + self.i_p1), 0
            )

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

        # External C-ABI PyCapsule dispatch (completely GIL-free)
        if case .Some(raw_fn) = self.descriptor.fn_ptr:
            if self.descriptor.kind == NATIVE_KIND_INT64:
                var int_fn = Pointer(to=raw_fn).unsafe_bitcast[NativeIntFn]()[]
                var out_i = int_fn(input.int_val, self.descriptor.ctx)
                return _NativeEvalResult(NativeValue.from_int(out_i), 0)
            if self.descriptor.kind == NATIVE_KIND_FLOAT64:
                var flt_fn = Pointer(to=raw_fn).unsafe_bitcast[
                    NativeFloatFn
                ]()[]
                var out_f = flt_fn(input.float_val, self.descriptor.ctx)
                return _NativeEvalResult(NativeValue.from_float(out_f), 0)
            var val_fn = Pointer(to=raw_fn).unsafe_bitcast[NativeValueFn]()[]
            var in_copy = input.copy()
            var out_val = NativeValue()
            var in_ptr = Pointer(to=in_copy).as_imm().unsafe_origin_cast[
                ImmUntrackedOrigin
            ]()
            var out_ptr = Pointer(to=out_val).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            var status = val_fn(in_ptr, out_ptr, self.descriptor.ctx)
            return _NativeEvalResult(out_val, status)

        return _NativeEvalResult(NativeValue(), -1)

    def _call_result(self, msg: PythonObject) -> _CallResult:
        var unboxed = _unbox_for_native(msg, self.input_kind())
        if case .Some(exc) = unboxed[1]:
            return _CallResult(error=exc)
        var in_val = unboxed[0].copy()
        var eval_res: _NativeEvalResult
        with GILReleased(Python()):
            eval_res = self.eval_native(in_val)
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


def _try_extract_native_chain(
    obj: PythonObject,
) -> Optional[List[NativeStage]]:
    """Extract a pure-native serial chain if `obj` is a single native stage or pure-native serial group."""
    if case .Some(single) = _try_extract_native_stage(obj):
        var chain = List[NativeStage]()
        chain.append(single.copy())
        return chain^

    try:
        if case .Some(grp_ptr) = obj._try_downcast_value[TaskGroup]():
            if (
                grp_ptr[].mode == TaskGroup.Serial.mode
                or grp_ptr[].mode == TaskGroup.undefined.mode
            ) and len(grp_ptr[].objects) > 0:
                var chain = List[NativeStage]()
                for child in grp_ptr[].objects:
                    if case .Some(sub_chain) = _try_extract_native_chain(child):
                        for stage in sub_chain:
                            chain.append(stage.copy())
                    else:
                        return None
                return chain^
    except:
        pass
    return None


def _eval_native_chain(
    chain: List[NativeStage], input: NativeValue
) -> _NativeEvalResult:
    """Evaluate a sequence of native stages completely GIL-free."""
    var cur = input.copy()
    for idx in range(len(chain)):
        if idx > 0:
            var coerced = _coerce_native_value(cur, chain[idx].input_kind())
            if coerced[1] != 0:
                return _NativeEvalResult(NativeValue(), coerced[1])
            cur = coerced[0].copy()
        var res = chain[idx].eval_native(cur)
        if res.status != 0:
            return res^
        cur = res.value.copy()
    return _NativeEvalResult(cur, 0)


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

    ref cpython = Python().cpython()
    var args_ptr = cpython.PyTuple_New(1)
    if not args_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))

    var msg_owned = msg
    _ = cpython.PyTuple_SetItem(args_ptr, 0, msg_owned^.steal_data())
    var args = PythonObject(from_owned=args_ptr)

    var res_ptr = cpython.PyObject_CallObject(task._obj_ptr, args._obj_ptr)
    if not res_ptr:
        var exc_ptr = cpython.PyErr_GetRaisedException()
        return _CallResult(error=PythonObject(from_owned=exc_ptr))

    return _CallResult(PythonObject(from_owned=res_ptr))


def _restore_python_exception(var exc: PythonObject) -> PythonObject:
    """Set CPython's error indicator to `exc` and return a NULL PythonObject.

    Must be called while holding the GIL right before returning to CPython.
    """
    ref cpython = Python().cpython()
    try:
        var builtins = Python.import_module("builtins")
        var exc_type = builtins.type(exc)
        var exc_tb = exc.__traceback__
        var tb_ptr = PyObjectPtr()
        if exc_tb._obj_ptr != Python.none()._obj_ptr:
            tb_ptr = exc_tb^.steal_data()
        cpython.PyErr_Restore(
            exc_type^.steal_data(),
            exc^.steal_data(),
            tb_ptr,
        )
        return PythonObject(from_owned=PyObjectPtr())
    except:
        var err_type = cpython.get_error_global("PyExc_RuntimeError")
        var fallback_msg = String("Failed to propagate Python exception")
        cpython.PyErr_SetString(err_type, fallback_msg.as_c_string_span().ptr())
        return PythonObject(from_owned=PyObjectPtr())


__async def _run_async_task(
    task_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    msg_ptr: Pointer[PythonObject, ImmUntrackedOrigin],
    out_ptr: Pointer[PythonObject, MutUntrackedOrigin],
    err_ptr: Pointer[Optional[PythonObject], MutUntrackedOrigin],
):
    with GILAcquired(Python()):
        var res = _invoke_py(task_ptr[], msg_ptr[])
        if case .Some(exc) = res.error:
            err_ptr[] = exc
        else:
            out_ptr[] = res.value


__async def _run_native_chain_task(
    chain_ptr: Pointer[List[NativeStage], ImmUntrackedOrigin],
    in_ptr: Pointer[NativeValue, ImmUntrackedOrigin],
    out_ptr: Pointer[_NativeEvalResult, MutUntrackedOrigin],
):
    # Executes 100% GIL-free on Mojo's asyncrt worker pool.
    out_ptr[] = _eval_native_chain(chain_ptr[], in_ptr[])


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
        return p[].scale * x + p[].bias
    return x


def _destroy_int_linear_capsule(capsule: PyObjectPtr) abi("C"):
    ref cpython = Python().cpython()
    try:
        var raw_ptr = cpython.PyCapsule_GetPointer(
            capsule, String(NATIVE_STAGE_CAPSULE_NAME)
        )
        var desc_ptr = raw_ptr.unsafe_bitcast[NativeStageDescriptor]()
        if case .Some(raw_ctx) = desc_ptr[].ctx:
            dealloc(
                ThinAllocation(
                    unsafe_owned_ptr=raw_ctx.unsafe_bitcast[_IntLinearCtx]()
                ).unsafe_with_layout(Layout[_IntLinearCtx].single())
            )
        dealloc(
            ThinAllocation(
                unsafe_owned_ptr=desc_ptr
            ).unsafe_with_layout(Layout[NativeStageDescriptor].single())
        )
    except:
        pass


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
    var s = Int64(Int(py=scale))
    var b = Int64(Int(py=bias))
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
    var s = Int64(Int(py=scale))
    var b = Int64(Int(py=bias))
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
        var strata = PythonModuleBuilder("mojo_strata")

        _ = (
            strata.add_type[TaskGroup]("mojo_strata.TaskGroup")
            .def_py_init[TaskGroup.py_init]()
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
        )

        _ = (
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
        )

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

    def __init__(out self, task: PythonObject):
        """Construct a TaskGroup with a single initial task.

        Args:
            task: Initial Python task object.
        """
        self.mode = -1
        self.objects = [task]

    def __init__(out self, mode: Int):
        """Construct an empty TaskGroup with a specific execution mode.

        Args:
            mode: Mode integer (0 for serial, 1 for parallel).
        """
        self.mode = mode
        self.objects = []

    def copy(self, out o: Self):
        """Copy the TaskGroup.

        Returns:
            A cloned copy of this TaskGroup.
        """
        o = Self(mode=self.mode)
        o.objects = self.objects.copy()

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
            return

        var new_group = TaskGroup(mode=mode)
        new_group.objects.append(PythonObject(alloc=self.copy()))
        new_group._append_parallel_or_single(t, mode)
        self = new_group^

    def _with_task(self, t: PythonObject, mode: Int) raises -> Self:
        var cloned = self.copy()
        cloned._add_task(t, mode)
        return cloned^

    def _call_result(self, msg: PythonObject) -> _CallResult:
        var count = len(self.objects)
        if count == 0:
            return _CallResult(msg)

        if self.mode == Self.undefined.mode:
            if count == 1:
                return _invoke_py(self.objects[0], msg)
            return _CallResult(
                error=_make_py_error("ValueError", "Group mode not set up")
            )

        if self.mode == Self.Serial.mode:
            var iv = msg
            var idx = 0
            while idx < count:
                if case .Some(first_chain) = _try_extract_native_chain(
                    self.objects[idx]
                ):
                    # Fuse maximal contiguous native run into a single GIL-free block
                    var fused = first_chain.copy()
                    var next_idx = idx + 1
                    while next_idx < count:
                        if case .Some(more) = _try_extract_native_chain(
                            self.objects[next_idx]
                        ):
                            for stage in more:
                                fused.append(stage.copy())
                            next_idx += 1
                        else:
                            break
                    var unboxed = _unbox_for_native(iv, fused[0].input_kind())
                    if case .Some(exc) = unboxed[1]:
                        return _CallResult(error=exc)
                    var in_val = unboxed[0].copy()
                    var eval_res: _NativeEvalResult
                    with GILReleased(Python()):
                        eval_res = _eval_native_chain(fused, in_val)
                    if eval_res.status != 0:
                        return _CallResult(
                            error=_native_status_to_error(eval_res.status)
                        )
                    var boxed = _box_from_native(eval_res.value)
                    if case .Some(exc) = boxed.error:
                        return _CallResult(error=exc)
                    iv = boxed.value
                    idx = next_idx
                else:
                    var res = _invoke_py(self.objects[idx], iv)
                    if case .Some(exc) = res.error:
                        return _CallResult(error=exc)
                    iv = res.value
                    idx += 1
            return _CallResult(iv^)

        # Parallel execution: hybrid dispatch (GIL-free for native branches/chains,
        # GIL-acquired on demand for Python branches).
        var values = List[PythonObject](length=count, fill=PythonObject())
        var errors = List[Optional[PythonObject]](length=count, fill=None)
        var is_native = List[Bool](length=count, fill=False)
        var native_chains = List[List[NativeStage]](capacity=count)
        var native_inputs = List[NativeValue](length=count, fill=NativeValue())
        var native_results = List[_NativeEvalResult](
            length=count, fill=_NativeEvalResult()
        )
        var has_spawned = List[Bool](length=count, fill=False)

        for idx in range(count):
            if case .Some(chain) = _try_extract_native_chain(self.objects[idx]):
                is_native[idx] = True
                var unboxed = _unbox_for_native(msg, chain[0].input_kind())
                if case .Some(exc) = unboxed[1]:
                    errors[idx] = exc
                    native_chains.append(List[NativeStage]())
                else:
                    native_inputs[idx] = unboxed[0].copy()
                    native_chains.append(chain.copy())
                    has_spawned[idx] = True
            else:
                native_chains.append(List[NativeStage]())
                has_spawned[idx] = True

        var tg = TG()
        var msg_ptr = Pointer(to=msg).unsafe_origin_cast[ImmUntrackedOrigin]()

        for idx in range(count):
            if not has_spawned[idx]:
                continue
            if is_native[idx]:
                var c_ptr = Pointer(
                    to=native_chains[idx]
                ).as_imm().unsafe_origin_cast[ImmUntrackedOrigin]()
                var i_ptr = Pointer(
                    to=native_inputs[idx]
                ).as_imm().unsafe_origin_cast[ImmUntrackedOrigin]()
                var o_ptr = Pointer(to=native_results[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                tg.create_task(_run_native_chain_task(c_ptr, i_ptr, o_ptr))
            else:
                var t_ptr = Pointer(to=self.objects[idx]).unsafe_origin_cast[
                    ImmUntrackedOrigin
                ]()
                var out_ptr = Pointer(to=values[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                var err_ptr = Pointer(to=errors[idx]).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                tg.create_task(
                    _run_async_task(t_ptr, msg_ptr, out_ptr, err_ptr)
                )

        with GILReleased(Python()):
            tg.wait()

        # Keep buffers referenced by untracked pointers alive across tg.wait().
        keep(native_chains)
        keep(native_inputs)
        keep(msg)

        # Box native outputs back to Python while holding the GIL
        for idx in range(count):
            if is_native[idx] and has_spawned[idx]:
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

        if len(failed) == 1:
            return _CallResult(error=failed[0])
        if len(failed) > 1:
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
        if len(args) != 1 and PythonObject("task") not in kwargs:
            raise "Bad arguments."

        var task_obj = (
            args[0] if len(args) == 1 else kwargs[PythonObject("task")]
        )
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
            Error if task addition fails.
        """
        var next_group = self_ptr[]._with_task(t, Int(py=_mode))
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
