"""Internal facade isolating Mojo's private async runtime and ownership intrinsics.

Centralizes unstable stdlib imports (`std.runtime._asyncrt`) and low-level
placement initialization helpers so compiler upgrades stay localized here.
"""

from std.runtime._asyncrt import TaskGroup as _TaskGroup, _run

comptime TaskGroup = _TaskGroup
"""Re-exported Mojo async runtime `TaskGroup`."""

comptime run_coro = _run
"""Re-exported Mojo async runtime coroutine runner."""


@always_inline
def uninitialized_storage[T: AnyType](out value: T):
    """Allocate an uninitialized output slot marked initialized for placement writes.

    Safety:
        Callers must initialize every field/element of `value` before reading or
        destroying it.

    Parameters:
        T: Storage type to mark initialized.
    """
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(value))
