from move.immutable import series_runner, parallel_runner
from move.mutable import MutCallable
from move.immutable import Callable


@fieldwise_init
struct UnsafeSerTaskPair[T1: Callable & Movable, T2: Callable & Movable](
    Callable, MutCallable, Movable
):
    var t1: T1
    var t2: T2

    fn __call__(self):
        series_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    fn __rshift__[
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return {self^, other^}


@fieldwise_init
struct UnsafeParTaskPair[T1: Callable & Movable, T2: Callable & Movable](
    Callable, MutCallable, Movable
):
    var t1: T1
    var t2: T2

    fn __call__(self):
        parallel_runner(self.t1, self.t2)

    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    fn __rshift__[
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return {self^, other^}


# THIS ALLOW US TO CREATE
struct UnsafeTaskRef[T: MutCallable, origin: ImmutableOrigin](
    Callable, MutCallable, Movable
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

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

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
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeParTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    fn __rshift__[
        t: MutCallable, o: MutableOrigin
    ](owned self, ref [o]other: t) -> UnsafeSerTaskPair[
        Self, UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result]
    ]:
        return {
            self^,
            UnsafeTaskRef[t, ImmutableOrigin.cast_from[o].result](other),
        }

    # ---- FOR IMMUTABLE VERSIONS -----
    fn __add__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: Callable & Movable
    ](owned self, owned other: t) -> UnsafeSerTaskPair[Self, t]:
        return {self^, other^}
