struct Foo:
    """A Foo type.

    ```mojo
    struct Bar:
        fn __init__(out self): pass

    fn func[*Ts: AnyType](owned *args: *Ts): pass

    b = Bar()
    # func(b^)  # This errors the code.
    ```
    """

    pass


struct Bar:
    """A Bar type.

    ```mojo
    struct Baz:
        fn __init__(out self): pass
        fn __moveinit__(out self, owned o: Self): pass

    a = Baz()
    b = a^ # This triggers the error.
    ```
    """

    pass
