from move.message import Message


trait ImmCallable:
    """The struct should contain a fn __call__ method.

    ```mojo
    trait ImmCallable:
        fn __call__(self):
            ...
    ```
    """

    fn __call__(self):
        ...


trait Callable:
    """The struct should contain a fn __call__ method.

    ```mojo
    trait Callable:
        fn __call__(mut self):
            ...
    ```
    """

    fn __call__(mut self):
        ...


trait CallableMovable(Callable, Movable):
    """A `Callable` + `Movable`.

    ```mojo
    trait CallableMutableMovable:
        fn __moveinit__(out self, owned existing: Self):
            ...

        fn __call__(mut self):
            ...
    ```
    """

    ...


trait CallableDefaultable(ImmCallable, Defaultable):
    """A `Callable` + `Defaultable`.

    ```mojo
    trait CallableDefaultable:
        fn __init__(out self):
            ...

        fn __call__(self):
            ...
    ```
    """

    ...


trait ImmCallableWithMessage:
    """A `ImmCallable` with a Message to pass to the next task.

    ```mojo
    from move.message import Message

    trait ImmCallableWithMessage:
        fn __call__(self, msg: Message) -> Message:
            ...
    ```
    """

    fn __call__(self, owned msg: Message) -> Message:
        ...


struct GenericCallablePack[origin: Origin, tr: __type_of(AnyType), *Ts: tr](
    Copyable
):
    # struct CallablePack[origin: Origin, *Ts: ImmCallable](Copyable):
    """Stores a reference variadic pack of (read only) `Callable` structs.

    The storage it's just the `VariadicPack` inner _value.

    If you are getting a variadic set of `Callable` arguments, you can store them in
    a CallablePack. Those can be used later, even out of the function. We use a lifetime
    hack to point to the _value lifetime instead of the args lifetime.

    ```mojo
    from move.callable import GenericCallablePack, ImmCallable

    struct MyTask(ImmCallable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running my call...")

    # hack to point to the _value lifetime instead of the args lifetime.
    fn store_value[*Ts: ImmCallable](*args: *Ts) -> GenericCallablePack[__origin_of(args._value), ImmCallable, *Ts]:
        return rebind[GenericCallablePack[__origin_of(args._value), ImmCallable, *Ts]](GenericCallablePack(args._value))


    task = MyTask()
    cpacks = store_value(task)

    # Use the task here
    cpacks[0]()

    ```
    """

    alias Storage = VariadicPack[origin, tr, *Ts]._mlir_type

    var storage: Self.Storage

    @implicit
    fn __init__(out self, storage: Self.Storage):
        self.storage = storage

    fn __copyinit__(out self, other: Self):
        self.storage = other.storage

    fn __getitem__[i: Int](self) -> ref [origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)


alias CallablePack = GenericCallablePack[tr=ImmCallable]
alias CallableMsgPack = GenericCallablePack[tr=ImmCallableWithMessage]
