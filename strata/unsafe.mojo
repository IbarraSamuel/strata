from strata.immutable import series_runner, parallel_runner, Callable
from strata.mutable import MutCallable, MovableMutCallable


# @fieldwise_init
# struct UnsafeSerTaskPair[T1: Callable & Movable, T2: Callable & Movable](
#     Callable, MovableMutCallable
# ):
#     var t1: T1
#     var t2: T2

#     fn __call__(self):
#         series_runner(self.t1, self.t2)

#     # ---- FOR MUTABLE VERSIONS -----
#     fn __add__[
#         t: MutCallable, o: MutableOrigin
#     ](var self, ref [o]other: t) -> UnsafeParTaskPair[Self, UnsafeTaskRef[t]]:
#         return {self^, UnsafeTaskRef(other)}

#     fn __rshift__[
#         t: MutCallable, o: MutableOrigin
#     ](var self, ref [o]other: t) -> UnsafeSerTaskPair[Self, UnsafeTaskRef[t]]:
#         return {self^, UnsafeTaskRef(other)}

#     # ---- FOR IMMUTABLE VERSIONS -----
#     fn __add__[
#         t: Callable & Movable
#     ](var self, var other: t) -> UnsafeParTaskPair[Self, t]:
#         return {self^, other^}

#     fn __rshift__[
#         t: Callable & Movable
#     ](var self, var other: t) -> UnsafeSerTaskPair[Self, t]:
#         return {self^, other^}


# @fieldwise_init
# struct UnsafeParTaskPair[T1: Callable & Movable, T2: Callable & Movable](
#     Callable, MovableMutCallable
# ):
#     var t1: T1
#     var t2: T2

#     fn __call__(self):
#         parallel_runner(self.t1, self.t2)

#     # ---- FOR MUTABLE VERSIONS -----
#     fn __add__[
#         t: MutCallable, o: MutableOrigin
#     ](var self, ref [o]other: t) -> UnsafeParTaskPair[Self, UnsafeTaskRef[t]]:
#         return {self^, UnsafeTaskRef(other)}

#     fn __rshift__[
#         t: MutCallable, o: MutableOrigin
#     ](var self, ref [o]other: t) -> UnsafeSerTaskPair[Self, UnsafeTaskRef[t]]:
#         return {self^, UnsafeTaskRef(other)}

#     # ---- FOR IMMUTABLE VERSIONS -----
#     fn __add__[
#         t: Callable & Movable
#     ](var self, var other: t) -> UnsafeParTaskPair[Self, t]:
#         return {self^, other^}

#     fn __rshift__[
#         t: Callable & Movable
#     ](var self, var other: t) -> UnsafeSerTaskPair[Self, t]:
#         return {self^, other^}


@register_passable("trivial")
struct UnsafeTaskRef[T: MutCallable](Callable, MovableMutCallable):
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

    # ---- FOR MUTABLE VERSIONS -----
    # fn __add__[
    #     t: MutCallable, o: MutableOrigin
    # ](var self, ref [o]other: t) -> UnsafeParTaskPair[Self, UnsafeTaskRef[t]]:
    #     return {self, UnsafeTaskRef(other)}

    # fn __rshift__[
    #     t: MutCallable, o: MutableOrigin
    # ](var self, ref [o]other: t) -> UnsafeSerTaskPair[Self, UnsafeTaskRef[t]]:
    #     return {self, UnsafeTaskRef(other)}

    # # # ---- FOR IMMUTABLE VERSIONS -----
    # fn __add__[
    #     t: Callable & Movable
    # ](var self, var other: t) -> UnsafeParTaskPair[Self, t]:
    #     return {self, other^}

    # fn __rshift__[
    #     t: Callable & Movable
    # ](var self, var other: t) -> UnsafeSerTaskPair[Self, t]:
    #     return {self, other^}
