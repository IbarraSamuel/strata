trait Runnable:
    """The struct should contain a fn run method.

    ```mojo
    from move.task.traits import Runnable

    struct Run(Runnable):
        fn __init__(out self): pass

        fn run(self):
            print("Running...")

    Run().run()  # Running...
    ```
    """

    fn run(self):
        ...


trait RunnableDefaultable(Runnable, Defaultable):
    ...
