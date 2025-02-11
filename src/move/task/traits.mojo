trait Runnable:
    """The struct should contain a fn run method.

    ```mojo
    trait Runnable:
        fn run(self):
            ...
    ```
    """

    fn run(self):
        ...


trait RunnableMovable(Runnable, Movable):
    """A `Runnable` + `Movable`.

    ```mojo
    trait RunnableMovable:
        fn __moveinit__(out self, owned existing: Self):
            ...

        fn run(self):
            ...
    ```
    """

    ...


trait RunnableDefaultable(Runnable, Defaultable):
    """A `Runnable` + `Defaultable`.

    ```mojo
    trait RunnableDefaultable:
        fn __init__(out self):
            ...

        fn run(self):
            ...
    ```
    """

    ...
