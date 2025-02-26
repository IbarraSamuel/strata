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
