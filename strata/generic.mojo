from runtime.asyncrt import _run, TaskGroup


trait Callable:
    alias I: Copyable & Movable  # Because tuple
    alias O: Copyable & Movable  # Beacuse tuple

    fn __call__(self, arg: I) -> O:
        ...


struct InWrapper[T: Callable, o: ImmutableOrigin, In: Copyable & Movable]:
    var value: Pointer[T, o]

    @implicit
    fn __init__(out self: InWrapper[T, o, T.I], ref [o]value: T):
        self.value = Pointer(to=value)


# @register_passable("trivial")
struct Task[
    origin: ImmutableOrigin,
    T: Callable, //,
    In: Copyable & Movable,
    Out: Copyable & Movable,
](Callable):
    alias I = In
    alias O = Out

    var inner: Pointer[T, origin]

    # fn __init__(
    #     out self: Task[T, T.I, Out, origin],
    #     var task: OutWrapper[T, origin, Out],
    # ):
    #     self.inner = Pointer(to=task.value[])

    fn __init__(
        out self: Task[origin=origin, T=T, In, T.O],
        var task: InWrapper[T, origin, In],
    ):
        self.inner = Pointer(to=task.value[])

    fn __init__(
        out self: Task[origin=origin, T = Fn[In, Out], In, T.O],
        ref [origin]task: Fn[In, Out],
    ):
        self.inner = Pointer(to=task)

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return rebind[Self.O](self.inner[].__call__(rebind[T.I](arg)))

    # For airflow syntax
    @always_inline("nodebug")
    fn __rshift__[
        t: Callable, o: ImmutableOrigin, //
    ](
        owned self: Task[origin=origin, T=T, In = T.I, Out = t.I],
        ref [o]other: t,
    ) -> SequentialPair[o1=origin, o2=o, T1=T, T2=t, T.I, t.O]:
        return SequentialPair(self^, Task(other))

    @always_inline("nodebug")
    fn __add__[
        t: Callable, o: ImmutableOrigin, //
    ](
        owned self: Task[origin=origin, T=T, In = t.I, Out = T.O],
        ref [o]other: t,
    ) -> ParallelPair[o1=origin, o2=o, T1=T, T2=t, t.I, (T.O, t.O)]:
        return ParallelPair(self^, Task(other))


# @register_passable("trivial")
struct SequentialPair[
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
    T1: Callable,
    T2: Callable, //,
    In: Copyable & Movable,
    Out: Copyable & Movable,
](Callable, Movable):
    alias I = In
    alias O = Out

    alias Task1 = Task[origin=o1, T=T1, In=In, Out = T2.I]
    alias Task2 = Task[origin=o2, T=T2, In = T2.I, Out=Out]

    alias FromSeq[O: Copyable & Movable] = SequentialPair[In=In, Out=O, **_]
    alias FromPar[O: Copyable & Movable] = ParallelPair[In=In, Out=O, **_]

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, var t1: Self.Task1, var t2: Self.Task2):
        self.t1 = t1.inner
        self.t2 = t2.inner

    fn __init__(
        out self: SequentialPair[
            o1=o1, o2=o2, T1 = __type_of(t1), T2=T2, t1.I, t2.O
        ],
        ref [o1]t1: Self.FromSeq[T2.I],
        var t2: Self.Task2,
    ):
        self.t1 = Pointer(to=t1)
        self.t2 = t2.inner

    fn __init__(
        out self: SequentialPair[
            o1=o1, o2=o2, T1 = __type_of(t1), T2=T2, t1.I, t2.O
        ],
        ref [o1]t1: Self.FromPar[T2.I],
        var t2: Self.Task2,
    ):
        self.t1 = Pointer(to=t1)
        self.t2 = t2.inner

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        ref a1 = rebind[T1.I](arg)
        ref r1 = self.t1[].__call__(a1)
        ref a2 = rebind[T2.I](r1)
        ref r2 = self.t2[].__call__(a2)
        return rebind[Out](r2)

    @always_inline("nodebug")
    fn __rshift__[
        o: ImmutableOrigin, t: Callable, //
    ](
        self: SequentialPair[o1=o1, o2=o2, T1=T1, T2=T2, In, t.I],
        ref [o]other: t,
    ) -> SequentialPair[
        o1 = __origin_of(self), o2=o, T1 = __type_of(self), T2=t, In, t.O
    ]:
        return SequentialPair(self, Task(other))

    @always_inline("nodebug")
    fn __add__[
        o: ImmutableOrigin, t: Callable, //
    ](
        self: SequentialPair[o1=o1, o2=o2, T1=T1, T2=T2, t.I, Out],
        ref [o]other: t,
    ) -> ParallelPair[
        o1 = __origin_of(self),
        o2=o,
        T1 = __type_of(self),
        T2=t,
        t.I,
        (Out, t.O),
    ]:
        return ParallelPair(self, Task(other))


# @register_passable("trivial")
struct ParallelPair[
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
    T1: Callable,
    T2: Callable, //,
    In: Copyable & Movable = T2.I,
    Out: Copyable & Movable = (T1.O, T2.O),
    # o1: ImmutableOrigin = ImmutableAnyOrigin,
    # o2: ImmutableOrigin = ImmutableAnyOrigin,
](Callable, Movable):
    alias I = In
    alias O = Out

    alias Task1 = Task[origin=o1, T=T1, In=In, Out = T1.O]
    alias Task2 = Task[origin=o2, T=T2, In=In, Out = T2.O]

    alias FromSeq[I: Copyable & Movable] = SequentialPair[In=I, **_]
    alias FromPar[I: Copyable & Movable] = ParallelPair[In=I, **_]

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, var t1: Self.Task1, var t2: Self.Task2):
        self.t1 = t1.inner
        self.t2 = t2.inner

    fn __init__(
        out self: ParallelPair[
            o1=o1, o2=o2, T1 = __type_of(t1), T2=T2, In, (t1.O, t2.O)
        ],
        ref [o1]t1: Self.FromSeq[T2.I],
        var t2: Self.Task2,
    ):
        self.t1 = Pointer(to=t1)
        self.t2 = t2.inner

    fn __init__(
        out self: ParallelPair[
            o1=o1, o2=o2, T1 = __type_of(t1), T2=T2, In, (t1.O, t2.O)
        ],
        ref [o1]t1: Self.FromPar[T2.I],
        var t2: Self.Task2,
    ):
        self.t1 = Pointer(to=t1)
        self.t2 = t2.inner

    # @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
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

    @always_inline("nodebug")
    fn __rshift__[
        o: ImmutableOrigin, t: Callable, //
    ](
        self: ParallelPair[o1=o1, o2=o2, T1=T1, T2=T2, In, t.I],
        ref [o]other: t,
    ) -> SequentialPair[
        o1 = __origin_of(self), o2=o, T1 = __type_of(self), T2=t, In, t.O
    ]:
        return SequentialPair(self, Task(other))

    @always_inline("nodebug")
    fn __add__[
        o: ImmutableOrigin, t: Callable, //
    ](
        self: ParallelPair[o1=o1, o2=o2, T1=T1, T2=T2, t.I, Out],
        ref [o]other: t,
    ) -> ParallelPair[
        o1 = __origin_of(self),
        o2=o,
        T1 = __type_of(self),
        T2=t,
        t.I,
        (Out, t.O),
    ]:
        return ParallelPair(self, Task(other))


@register_passable("trivial")
struct Fn[In: Copyable & Movable, Out: Copyable & Movable](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    @implicit
    @always_inline("builtin")
    fn __init__(out self, func: fn (In) -> Out):
        self.func = func

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
