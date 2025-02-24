trait Callable:
    """The struct should contain a fn __call__ method.

    ```mojo
    trait Callable:
        fn __call__(self):
            ...
    ```
    """

    fn __call__(self):
        ...


trait CallableMovable(Callable, Movable):
    """A `Callable` + `Movable`.

    ```mojo
    trait CallableMovable:
        fn __moveinit__(out self, owned existing: Self):
            ...

        fn __call__(self):
            ...
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
    ```
    """

    ...


struct CallablePack[origin: Origin, *Ts: Callable](Copyable):
    """Stores a reference variadic pack of `Runnable` structs."""

    alias _mlir_type = VariadicPack[origin, Callable, *Ts]._mlir_type

    var storage: Self._mlir_type

    @implicit
    fn __init__(out self, storage: Self._mlir_type):
        self.storage = storage

    fn __copyinit__(out self, other: Self):
        self.storage = other.storage

    fn __getitem__[i: Int](self) -> ref [origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)
