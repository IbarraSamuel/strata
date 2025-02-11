trait Callable:
    """The struct should contain a fn run method.

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
