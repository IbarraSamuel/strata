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
    # b = a^ # This triggers the error.
    ```
    """

    pass


struct SyncPar:
    """Sync Parallelize didn't work on doctests.

    ```mojo
    from time import sleep
    from algorithm import sync_parallelize, parallelize
    from testing import assert_true

    fn do_par(i: Int) capturing:
        print("Running iteration", i)
        sleep(0.1)
        print("finish iteration", i)

    sync_parallelize[do_par](4)

    assert_true(False)

    ```
    """
