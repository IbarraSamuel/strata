from runtime.asyncrt import _run, TaskGroup
from sys.intrinsics import _type_is_eq


trait Callable:
    alias I: Copyable & Movable  # Because tuple
    alias O: Copyable & Movable  # Beacuse tuple

    fn __call__(self, arg: Self.I) -> Self.O:
        ...

    fn __rshift__[
        s: ImmutableOrigin, t: Callable, //
    ](
        ref [s]self,
        var other: Task[T=t, In = Self.O],
    ) -> Group[
        o1=s, o2 = other.origin, T1=Self, T2=t, Self.I, t.O
    ]:
        return Group(Task(self), other^)

    fn __add__[
        s: ImmutableOrigin, t: Callable, //
    ](
        ref [s]self,
        var other: Task[T=t, In = Self.I],
    ) -> Group[
        o1=s, o2 = other.origin, T1=Self, T2=t, Self.I, (Self.O, t.O)
    ]:
        return Group(Task(self), other^)


struct Task[
    origin: ImmutableOrigin,
    T: Callable, //,
    In: Copyable & Movable = T.I,
    Out: Copyable & Movable = T.O,
](Callable, Movable):
    alias I = In
    alias O = Out

    var inner: Pointer[T, origin]

    @always_inline("nodebug")
    @implicit  # To be able to parametrize the trait
    fn __init__(out self: Task[origin=origin, T=T], ref [origin]task: T):
        self.inner = Pointer(to=task)

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return rebind[Self.O](self.inner[].__call__(rebind[T.I](arg)))


@register_passable("trivial")
struct Group[
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
    T1: Callable,
    T2: Callable, //,
    In: Copyable & Movable,
    Out: Copyable & Movable,
](Callable, Movable):
    alias I = In
    alias O = Out

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    # Init to be a SequentialPair
    fn __init__(
        out self: Group[
            o1 = t1.origin,
            o2 = t2.origin,
            T1 = t1.T,
            T2 = t2.T,
            (t1.I, t2.I),
            (t1.O, t2.O),
        ],
        var t1: Task,
        var t2: Task,
    ):
        self.t1 = t1.inner
        self.t2 = t2.inner

    # Init to be a SequentialPair
    fn __init__(
        out self: Group[o1=o1, o2=o2, T1=T1, T2=T2, T1.I, T2.O],
        var t1: Task[origin=o1, T=T1, In = T1.I, Out = T1.O],
        var t2: Task[origin=o2, T=T2, In = T1.O, Out = T2.O],
    ):
        self.t1 = t1.inner
        self.t2 = t2.inner

    # Init to be a ParallelPair
    fn __init__(
        out self: Group[o1=o1, o2=o2, T1=T1, T2=T2, In, (T1.O, T2.O)],
        var t1: Task[origin=o1, T=T1, In=In, Out = T1.O],
        var t2: Task[origin=o2, T=T2, In=In, Out = T2.O],
    ):
        self.t1 = t1.inner
        self.t2 = t2.inner

    # Call for a SequentialPair
    fn sequential_call(
        self: Group[o1=o1, o2=o2, T1=T1, T2=T2, T1.I, T2.O], arg: Self.I
    ) -> Self.O:
        ref a1 = rebind[T1.I](arg)
        ref r1 = self.t1[].__call__(a1)
        ref a2 = rebind[T2.I](r1)
        ref r2 = self.t2[].__call__(a2)
        return rebind[Out](r2)

    # Call for a ParallelPair
    fn parallel_call(
        self: Group[o1=o1, o2=o2, T1=T1, T2=T2, In, (T1.O, T2.O)], arg: Self.I
    ) -> Self.O:
        tg = TaskGroup()

        v1: T1.O
        v2: T2.O

        @parameter
        async fn task_1():
            v1 = self.t1[].__call__(rebind[T1.I](arg))

        @parameter
        async fn task_2():
            v2 = self.t2[].__call__(rebind[T2.I](arg))

        # This is safe because the variables will be initialized at the return.
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v1))
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v2))

        tg.create_task(task_1())
        tg.create_task(task_2())

        tg.wait()

        return rebind[Out]((v1, v2))

    # Call for a SequentialPair
    fn __call__(self, arg: Self.I) -> Self.O:
        @parameter
        if _type_is_eq[Out, T2.O]():
            return rebind[Self.O](
                rebind[Group[o1=o1, o2=o2, T1=T1, T2=T2, T1.I, T2.O]](
                    self
                ).sequential_call(rebind[T1.I](arg))
            )
        else:
            return rebind[Self.O](
                rebind[Group[o1=o1, o2=o2, T1=T1, T2=T2, In, (T1.O, T2.O)]](
                    self
                ).parallel_call(arg)
            )
