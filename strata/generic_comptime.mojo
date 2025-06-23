from memory.pointer import Pointer
from algorithm import sync_parallelize
from strata.custom_tuple import Tuple

alias TaskValue = Movable & Copyable & Defaultable
alias InType = TaskValue
alias OutType = TaskValue
"""
Both sould conform to the same trait since an output from a Task could be an input for the next task. 

* Needs to be Defaultable because on parallel, needs to be initialized before calling it. `var ..: type` is not enought
* Needs to be Copyable because I cannot rebind it in the output type if it's not copyable.
    I tried using refs, but then each one needs to return an ImmutableAnyOrigin, since those values are produced within the __call__ method.
    Then, we cannot use register_passable types, because they doesn't have origin. The API will be restricted to not register_passable types,
    and then things like SIMD cannot be used. Better just use Copyable things meanwhile the rebind doesn't work or we wait for requires or parametrized traits.
This tradeoff could be eliminated if I don't ensure type safety on the graph, but I want to ensure safety :).
"""


trait Callable:
    alias I: InType
    alias O: OutType

    @staticmethod
    fn __call__(arg: I) -> O:
        ...


@fieldwise_init
struct Task[C: Callable, *, In: InType = C.I, Out: OutType = C.O](Callable):
    alias I = In
    alias O = Out

    @staticmethod
    fn __call__(value: Self.I) -> Self.O:
        return rebind[Self.O](C.__call__(rebind[C.I](value)))

    fn __rshift__[
        c: Callable
    ](self: Task[C, Out = c.I], other: c) -> Task[SerPair[C, c]]:
        return {}

    fn __add__[
        c: Callable,
    ](self: Task[C, In = c.I], other: c) -> Task[ParPair[C, c]]:
        return {}


struct SerPair[
    C1: Callable,
    C2: Callable,
    t1: Task[C1, Out = C2.I] = {},
    t2: Task[C2] = {},
](Callable):
    alias I = t1.I
    alias O = t2.O

    # fn __init__(out self, t1: Task[C1, Out = C2.I], t2: Task[C2]):
    #     pass

    @staticmethod
    fn __call__(arg: Self.I) -> Self.O:
        out_1 = t1.__call__(arg)
        return t2.__call__(out_1^)


@fieldwise_init
struct ParPair[
    C1: Callable,
    C2: Callable,
    t1: Task[C1, In = C2.I] = {},
    t2: Task[C2] = {},
](Callable):
    alias I = t1.I
    alias O = (t1.Out, t2.Out)

    # fn __init__(out self, t1: Task[C1, In = C2.I], t2: Task[C2]):
    #     pass

    @staticmethod
    fn __call__(arg: Self.I) -> Self.O:
        var o1 = t1.Out()
        var o2 = t2.Out()

        @parameter
        fn run_task(i: Int):
            if i == 0:
                o1 = t1.__call__(arg)
            else:
                o2 = t2.__call__(arg)

        sync_parallelize[run_task](2)
        return (o1^, o2^)


@fieldwise_init
struct Fn[In: InType, Out: OutType, //, F: fn (In) -> Out, /](Callable):
    alias I = In
    alias O = Out

    @staticmethod
    fn __call__(value: Self.I) -> Self.O:
        return F(value)

    fn __rshift__[
        c: Callable
    ](self: Fn[Out = c.I], other: c) -> Task[SerPair[Self, c]]:
        return {}

    fn __add__[
        c: Callable,
    ](self: Fn[In = c.I], other: c) -> Task[ParPair[Self, c]]:
        return {}
