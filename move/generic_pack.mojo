struct GenericPack[
    is_owned: Bool, origin: Origin, tr: __type_of(AnyType), *Ts: tr
]:
    # struct CallablePack[origin: Origin, *Ts: ImmCallable](Copyable):
    """Stores a reference variadic pack of (read only) `Callable` structs.

    The storage it's just the `VariadicPack` inner _value.

    If you are getting a variadic set of `Callable` arguments, you can store them in
    a CallablePack. Those can be used later, even out of the function. We use a lifetime
    hack to point to the _value lifetime instead of the args lifetime.

    Parameters:
        mut: Defines if the Origin is mutable or not.
        is_owned: If the arguments are owned by the pack or not.
        origin: The Origin of the Variadic Arguments.
        tr: Trait to use to filter possible values from the Pack.
        Ts: Types meeting the tr criteria.

    ```mojo
    from move.generic_pack import GenericPack
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
    fn store_value[*Ts: HasGetter](*args: *Ts) -> GenericPack[args.is_owned, args.origin, HasGetter, *Ts]:
        return GenericPack(args)


    task = MyTask()
    cpacks = store_value(task)

    # Use the task here
    val = cpacks[0].get()
    assert_true(val == 1)
    ```
    """
    var storage: VariadicPack[is_owned, origin, tr, *Ts]
    """The storage of pointers to each object."""

    @implicit
    fn __init__(
        out self: GenericPack[False, origin, tr, *Ts],
        pack: VariadicPack[False, origin, tr, *Ts],
    ):
        self.storage = VariadicPack[False, origin, tr, *Ts](pack._value)

    @implicit
    fn __init__(
        out self: GenericPack[True, origin, tr, *Ts],
        owned pack: VariadicPack[True, origin, tr, *Ts],
    ):
        self.storage = pack^

    # fn __copyinit__(
    #     out self: GenericPack[False, origin, tr, *Ts],
    #     other: GenericPack[False, origin, tr, *Ts],
    # ):
    #     self = GenericPack(other.storage)

    fn __moveinit__(out self, owned other: Self):
        self.storage = other.storage^

    fn __getitem__[i: Int](self) -> ref [origin] Ts[i.value]:
        """Get one item from the CallablePack as a reference.

        Parameters:
            i: The index to use as an extractor.

        Returns:
            The reference to the item in the VariadicPack.
        """
        return self.storage[i]
