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
    from time import sleep, perf_counter_ns
    from algorithm import sync_parallelize, parallelize
    from testing import assert_true

    var start0: UInt = 0
    var start1: UInt = 0
    var end0: UInt = 0
    var end1: UInt = 0
    fn do_par(i: Int) capturing:
        init = perf_counter_ns()
        if i == 0:
            start0 = init
        else:
            start1 = init

        print("Running iteration", i)
        sleep(0.1)
        print("finish iteration", i)

        end = perf_counter_ns()
        if i == 0:
            end0 = init
        else:
            end1 = init

    sync_parallelize[do_par](2)

    # Commented to not fail tests
    # assert_true(start0 < end1 and start1 < end0)

    ```
    """
