from strata.immutable import Callable
from strata.mutable import MutCallable, _MovableMutCallable


@register_passable("trivial")
struct UnsafeTaskRef[T: MutCallable](Callable, _MovableMutCallable):
    """This structure will treat MutableCallables as Immutable Callables.
    Is a way of casting a MutableCallable into a Callable.
    Since we might need to operate with other MutableCallables in the future,
    we cannot use full references as it is on the Immutable version. Basically,
    because it will require to create this Ref, and the ref will have no origin,
    since it's created on the fly. Because of that, we will use a `mixed` approach.
    The first part will be a reference to a "immutable" task, and the second a var
    version of this UnsafeTaskRef.

    We should avoid using this one, the most we can.
    """

    var inner: UnsafePointer[T]

    fn __init__(out self, ref inner: T):
        self.inner = UnsafePointer(to=inner)

    @always_inline("nodebug")
    fn __call__(self):
        # WARNING: There is no guarrantee on what is made inside the task.
        # Since could be mutable, and the caller doesn't need mutability.
        # Higher level tasks are all immutable, so there is no problem.
        self.inner[]()
