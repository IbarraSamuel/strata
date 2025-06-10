# strata
Series/Parallel Task runner for Mojo based on asyncrt.

## Try it
Use the command and see how strata works:
```sh
cd examples
pixi run examples
```

The command will run these files:
* [Type Examples](examples/type_examples.mojo)
* [Immutable Examples](examples/immutable_examples.mojo)
* [Message Examples](examples/message_examples.mojo)
* [Mutable Examples](examples/mutable_examples.mojo)
* [Unsafe Examples](examples/unsafe_examples.mojo)
* [Async Immutable Examples](examples/async_immutable_task_examples.mojo)
* [Async Mutable Examples](examples/async_mutable_task_examples.mojo)
* [Generic Examples](examples/generic_examples.mojo)

Don't know why LSP is not recognising the package. If you want a better lint experience, add an `__init__.mojo` file on the examples folder.

We have python interop, but it doesn't work properly :(. You cannot run python objects in different threads. GIL things. :)