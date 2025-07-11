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

    fn __call__(self, arg: I) -> O:
        ...


struct Task[
    T: Callable,
    origin: ImmutableOrigin,
    In: InType = T.I,
    Out: OutType = T.O,
](Callable, Movable):
    alias I = In
    alias O = Out
    alias CallableTask = Task[T, origin, In = T.I, Out = T.O]
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    # fn __init__[
    #     t: Callable, o: ImmutableOrigin
    # ](out self: Self.CallableTask[t, o], ref [o]inner: t):
    #     self.inner = Pointer(to=inner)

    # fn __init__(
    #     out self: Task[_Fn[In, Out], ImmutableAnyOrigin], func: fn (In) -> Out
    # ):
    #     self.inner = Pointer[_Fn[In, Out], ImmutableAnyOrigin](to=_Fn(func))

    fn __call__(self, arg: Self.I) -> Self.O:
        # SAFETY: This is safe because Self.I and T.I are the same type
        # and Self.O and T.O are the same type
        # Why? Because the only way to construct this struct is by using a reference to a Callable, which will define In and Out types automatically

        # TODO: Why we can't rebind something if there is no origin for it?
        return rebind[Self.O](self.inner[](rebind[T.I](arg)))

    fn __rshift__[
        t: Callable, o: ImmutableOrigin
    ](
        owned self: Task[T, origin, In = T.I, Out = t.I], ref [o]other: t
    ) -> Task[
        SerPair[T, t, origin, o], ImmutableAnyOrigin, In = T.I, Out = t.O
    ]:
        sp = SerPair(self^, Task(other))
        return Task[__type_of(sp), ImmutableAnyOrigin](sp)

    # fn __rshift__[
    #     I: TaskValue, O: TaskValue
    # ](owned self: Task[T, origin, Out=I], func: fn (I) -> O) -> Task[
    #     SerPair[T, _Fn[I, O], origin, ImmutableAnyOrigin], ImmutableAnyOrigin
    # ]:
    #     return {SerPair(self^, _Fn(func))}

    fn __add__[
        t: Callable, o: ImmutableOrigin
    ](
        owned self: Task[T, origin, In = t.I, Out = T.O], ref [o]other: t
    ) -> Task[
        ParPair[T, t, origin, o], ImmutableAnyOrigin, In = t.I, Out = (T.O, t.O)
    ]:
        pp = ParPair(self^, Task(other))
        return Task[__type_of(pp), ImmutableAnyOrigin](pp)

    # fn __add__[
    #     I: TaskValue, O: TaskValue
    # ](owned self: Task[T, origin, In=I], func: fn (I) -> O) -> Task[
    #     ParPair[T, _Fn[I, O], origin, ImmutableAnyOrigin], ImmutableAnyOrigin
    # ]:
    #     return {ParPair(self^, _Fn(func))}


@fieldwise_init
struct SerPair[
    C1: Callable,
    C2: Callable,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](Callable):
    alias I = C1.I
    alias O = C2.O

    var task_1: Task[C1, o1, In = C1.I, Out = C2.I]
    var task_2: Task[C2, o2, In = C2.I, Out = C2.O]

    fn __call__(self, arg: Self.I) -> Self.O:
        result_1 = self.task_1.inner[](arg)
        # Safety: You cannot even instanciate this struct if this is not true.
        inp_2 = rebind[C2.I](result_1)
        result_2 = self.task_2.inner[](inp_2)
        return result_2^


@fieldwise_init
struct ParPair[
    C1: Callable,
    C2: Callable,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](Callable):
    alias I = C2.I
    alias O = (C1.O, C2.O)

    var task_1: Task[C1, o1, In = C2.I, Out = C1.O]
    var task_2: Task[C2, o2, In = C2.I, Out = C2.O]

    fn __call__(self, arg: Self.I) -> Self.O:
        var res_1 = self.task_1.O()
        var res_2 = self.task_2.O()

        @parameter
        fn run_task(idx: Int):
            if idx == 0:
                inp_1 = rebind[C1.I](arg)
                res_1 = self.task_1.inner[](inp_1)
            else:
                # Safety: You cannot instanciate this struct if this is not true.
                res_2 = self.task_2.inner[](arg)

        sync_parallelize[run_task](2)

        return (res_1^, res_2^)


@fieldwise_init("implicit")
struct Fn[In: InType, Out: OutType](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
