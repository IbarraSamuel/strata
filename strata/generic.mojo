from runtime.asyncrt import _run, TaskGroup


trait Callable:
    alias I: Copyable & Movable  # Because tuple
    alias O: Copyable & Movable  # Beacuse tuple

    fn __call__(self, arg: I) -> O:
        ...


@register_passable("trivial")
struct Task[
    T: Callable,
    *,
    origin: Origin[mut=False],
    In: Copyable & Movable = T.I,
    Out: Copyable & Movable = T.O,
](Callable):
    alias I = In
    alias O = Out

    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]task: T):
        self.inner = Pointer[origin=origin](to=task)

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return rebind[Self.O](self.inner[].__call__(rebind[T.I](arg)))

    # For airflow syntax
    @always_inline("nodebug")
    fn __rshift__[
        t: Callable, o: Origin[mut=False]
    ](
        self: Task[T, origin=origin, In = T.I, Out = t.I],
        ref [o]other: t,
        out pair: Task[
            SequentialPair[origin, o, T, t], origin=ImmutableAnyOrigin
        ],
    ):
        pair = {SequentialPair(self, Task(other))}

    @always_inline("nodebug")
    fn __add__[
        t: Callable, o: Origin[mut=False]
    ](
        self: Task[T, origin=origin, In = t.I, Out = T.O],
        ref [o]other: t,
        out pair: Task[
            ParallelPair[origin, o, T, t], origin=ImmutableAnyOrigin
        ],
    ):
        pair = {ParallelPair(self, Task(other))}


@register_passable("trivial")
struct SequentialPair[
    o1: Origin[mut=False], o2: Origin[mut=False], T1: Callable, T2: Callable
](Callable, Movable):
    alias I = T1.I
    alias O = T2.O

    alias Task1 = Task[T1, origin=o1, In = T1.I, Out = T2.I]
    alias Task2 = Task[T2, origin=o2, In = T2.I, Out = T2.O]

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, t1: Self.Task1, t2: Self.Task2):
        self.t1 = t1.inner
        self.t2 = t2.inner

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return self.t2[].__call__(rebind[T2.I](self.t1[].__call__(arg)))


@register_passable("trivial")
struct ParallelPair[
    o1: Origin[mut=False], o2: Origin[mut=False], T1: Callable, T2: Callable
](Callable, Movable):
    alias I = T1.I
    alias O = (T1.O, T2.O)

    alias Task1 = Task[T1, origin=o1, In = T2.I, Out = T1.O]
    alias Task2 = Task[T2, origin=o2, In = T2.I, Out = T2.O]

    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, t1: Self.Task1, t2: Self.Task2):
        self.t1 = t1.inner
        self.t2 = t2.inner

    # @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        tg = TaskGroup()

        v1: T1.O
        v2: T2.O

        @parameter
        async fn task_1():
            v1 = self.t1[].__call__(arg)

        @parameter
        async fn task_2():
            v2 = self.t2[].__call__(rebind[T2.I](arg))

        # This is safe because the variables will be initialized at the return.
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v1))
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(v2))

        tg.create_task(task_1())
        tg.create_task(task_2())

        tg.wait()

        return (v1, v2)


@fieldwise_init("implicit")
struct Fn[In: Copyable & Movable, Out: Copyable & Movable](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    @always_inline("nodebug")
    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
