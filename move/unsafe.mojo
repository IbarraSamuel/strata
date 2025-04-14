from move.immutable import series_runner, parallel_runner, CallableMovable
from move.mutable import MutableCallable


struct UnsafeSerTaskPair[T1: CallableMovable, T2: CallableMovable](
    CallableMovable
):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(self):
        series_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeParTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeSerTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return UnsafeParTaskPair(self^, other^)

    fn __rshift__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return UnsafeSerTaskPair(self^, other^)


struct UnsafeParTaskPair[T1: CallableMovable, T2: CallableMovable](
    CallableMovable
):
    var t1: T1
    var t2: T2

    fn __init__(out self, owned v1: T1, owned v2: T2):
        self.t1 = v1^
        self.t2 = v2^

    fn __moveinit__(out self, owned other: Self):
        self.t1 = other.t1^
        self.t2 = other.t2^

    fn __call__(self):
        parallel_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeParTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeSerTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return UnsafeParTaskPair(self^, other^)

    fn __rshift__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return UnsafeSerTaskPair(self^, other^)


# THIS ALLOW US TO CREATE
struct UnsafeTaskRef[T: MutableCallable, origin: ImmutableOrigin](
    CallableMovable
):
    """This structure will treat MutableCallables as Immutable Callables.
    Is a way of casting a MutableCallable into a Callable.
    Since we might need to operate with other MutableCallables in the future,
    we cannot use full references as it is on the Immutable version. Basically,
    because it will require to create this Ref, and the ref will have no origin,
    since it's created on the fly. Because of that, we will use a `mixed` approach.
    The first part will be a reference to a "immutable" task, and the second a owned
    version of this UnsafeTaskRef.

    We should avoid using this one, the most we can.
    """

    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __moveinit__(out self, owned other: Self):
        self.inner = other.inner

    fn __call__(self):
        # Fake it as mutable.
        # SAFETY: This only allows to modify the inner value.
        # No access to other tasks.
        # WARNING: There is no guarrantee on what is made inside the task.
        # Higher level tasks, are all immutable, so there is no problem.
        alias MutPtr = Pointer[T, MutableOrigin.cast_from[origin].result]
        rebind[MutPtr](self.inner)[]()

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeParTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    fn __rshift__[
        t: MutableCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return UnsafeSerTaskPair(
            self^, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other)
        )

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return UnsafeParTaskPair(self^, other^)

    fn __rshift__[
        t: CallableMovable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return UnsafeSerTaskPair(self^, other^)
