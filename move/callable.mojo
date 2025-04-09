from move.message import Message


trait Callable:
    """The struct should contain a fn __call__ method.

    ```mojo
    trait Callable:
        fn __call__(mut self):
            ...

    struct MyStruct(Callable):
        fn __init__(out self):
            pass

        fn __call__(mut self):
            print("calling...")

    inst = MyStruct()

    # Calling the instance.
    inst()
    ```
    """

    fn __call__(mut self):
        """Run a task with the possibility to mutate internal state."""
        ...


trait CallableMovable(Callable, Movable):
    """A `Callable` + `Movable`.

    ```mojo
    trait CallableMovable:
        fn __moveinit__(out self, owned existing: Self):
            ...

        fn __call__(mut self):
            ...

    struct MyStruct(CallableMovable):
        fn __init__(out self):
            pass

        fn __moveinit__(out self, owned existing: Self):
            pass

        fn __call__(mut self):
            print("calling...")

    inst = MyStruct()

    # Calling the instance.
    # moved = inst^
    inst()
    ```
    """

    ...


trait CallableDefaultable(Callable, Defaultable):
    """A `Callable` + `Defaultable`.

    ```mojo
    trait CallableDefaultable:
        fn __init__(out self):
            ...

        fn __call__(self):
            ...

    struct MyStruct(CallableDefaultable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("calling...")

    default = MyStruct()

    # Calling the instance.
    default()
    ```
    """

    ...


trait CallableWithMessage:
    """A `ImmCallable` with a Message to pass to the next task.

    ```mojo
    from move.message import Message

    trait CallableWithMessage:
        fn __call__(mut self, owned msg: Message) -> Message:
            ...

    struct MyStruct(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            nm = msg.get("name", "Bob")
            msg["greet"] = String("Hello, ", nm, "!")
            return msg

    tsk = MyStruct()

    # Calling the instance.
    msg = Message()
    msg["name"] = "Samuel"
    res = tsk(msg)
    print(res["greet"])

    ```
    """

    fn __call__(self, owned msg: Message) -> Message:
        """Run a task using a `Message` (Alias for `Dict[String, String]` for now).
        You should return a message back.

        Args:
            msg: The information to be readed.

        Returns:
            The result of running this task.
        """
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

    Parameters:
        is_mutable: Defines if the Origin is mutable or not.
        origin: The Origin of the Variadic Arguments.
        tr: Trait to use to filter possible values from the Pack.
        Ts: Types meeting the tr criteria.

    ```mojo
    from move.callable import GenericCallablePack, Callable

    struct MyTask(Callable):
        fn __init__(out self):
            pass

        fn __call__(self):
            print("Running my call...")

    # hack to point to the _value lifetime instead of the args lifetime.
    fn store_value[*Ts: Callable](*args: *Ts) -> GenericCallablePack[__origin_of(args._value), Callable, *Ts]:
        return rebind[GenericCallablePack[__origin_of(args._value), Callable, *Ts]](GenericCallablePack(args._value))


    task = MyTask()
    cpacks = store_value(task)

    # Use the task here
    cpacks[0]()

    ```
    """

    alias Storage = VariadicPack[origin, tr, *Ts]._mlir_type
    """The underlying _value storage for a VariadicPack. It's just a collection of pointers."""

    var storage: Self.Storage
    """The storage of pointers to each object."""

    @implicit
    fn __init__(out self, storage: Self.Storage):
        """Initialize a CallablePack using a storage from a VariadicPack.

        Args:
            storage: The VariadicPack value to store.
        """
        self.storage = storage

    fn __copyinit__(out self, other: Self):
        """Copy the CallablePack.

        Args:
            other: The value to be moved from.
        """
        self.storage = other.storage

    fn __getitem__[i: Int](self) -> ref [origin] Ts[i.value]:
        """Get one item from the CallablePack as a reference.

        Parameters:
            i: The index to use as an extractor.

        Returns:
            The reference to the item in the VariadicPack.
        """
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)


alias CallablePack = GenericCallablePack[tr=Callable]
alias CallableMsgPack = GenericCallablePack[tr=CallableWithMessage]
