from move.message import Message


struct GenericPack[origin: Origin, tr: __type_of(AnyType), *Ts: tr](Copyable):
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
    from move.callable import GenericPack
    from testing import assert_true

    trait HasGetter:
        fn get(self) -> Int:
            ...

    struct MyTask(HasGetter):
        fn __init__(out self):
            pass

        fn get(self) -> Int:
            return 1

    # hack to point to the _value lifetime instead of the args lifetime.
    fn store_value[*Ts: HasGetter](*args: *Ts) -> GenericPack[__origin_of(args._value), HasGetter, *Ts]:
        return rebind[GenericPack[__origin_of(args._value), HasGetter, *Ts]](GenericPack(args._value))


    task = MyTask()
    cpacks = store_value(task)

    # Use the task here
    val = cpacks[0].get()
    assert_true(val == 1)
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
