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
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __init__(
        out self: Task[_Fn[In, Out], ImmutableAnyOrigin], func: fn (In) -> Out
    ):
        self.inner = Pointer[_Fn[In, Out], ImmutableAnyOrigin](to=_Fn(func))

    fn __call__(self, arg: Self.I) -> Self.O:
        # SAFETY: This is safe because Self.I and T.I are the same type
        # and Self.O and T.O are the same type
        # Why? Because the only way to construct this struct is by using a reference to a Callable, which will define In and Out types automatically

        # TODO: Why we can't rebind something if there is no origin for it?
        return rebind[Self.O](self.inner[](rebind[T.I](arg)))

    fn __rshift__[
        t: Callable, o: ImmutableOrigin
    ](owned self: Task[T, origin, Out = t.I], ref [o]other: t) -> Task[
        SerTask[T, t, origin, o], ImmutableAnyOrigin
    ]:
        return {SerTask(self^, Task(other))}

    fn __rshift__[
        I: TaskValue, O: TaskValue
    ](owned self: Task[T, origin, Out=I], func: fn (I) -> O) -> Task[
        SerTask[T, _Fn[I, O], origin, ImmutableAnyOrigin], ImmutableAnyOrigin
    ]:
        return {SerTask(self^, Task(func))}

    fn __add__[
        t: Callable, o: ImmutableOrigin
    ](owned self: Task[T, origin, In = t.I], ref [o]other: t) -> Task[
        ParTask[T, t, origin, o], ImmutableAnyOrigin
    ]:
        return {ParTask(self^, Task(other))}

    fn __add__[
        I: TaskValue, O: TaskValue
    ](owned self: Task[T, origin, In=I], func: fn (I) -> O) -> Task[
        ParTask[T, _Fn[I, O], origin, ImmutableAnyOrigin], ImmutableAnyOrigin
    ]:
        return {ParTask(self^, Task(func))}


@fieldwise_init
struct SerTask[
    C1: Callable, C2: Callable, o1: ImmutableOrigin, o2: ImmutableOrigin
](Callable):
    alias I = C1.I
    alias O = C2.O

    var task_1: Task[C1, Out = C2.I, origin=o1]
    var task_2: Task[C2, origin=o2]

    fn __call__(self, arg: Self.I) -> Self.O:
        result_1 = self.task_1.inner[](arg)
        # Safety: You cannot even instanciate this struct if this is not true.
        inp_2 = rebind[C2.I](result_1)
        result_2 = self.task_2.inner[](inp_2)
        return result_2^


@fieldwise_init
struct ParTask[
    C1: Callable,
    C2: Callable,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](Callable):
    alias I = C1.I
    alias O = (C1.O, C2.O)

    var task_1: Task[C1, In = C2.I, origin=o1]
    var task_2: Task[C2, origin=o2]

    fn __call__(self, arg: Self.I) -> Self.O:
        var res_1 = self.task_1.O()
        var res_2 = self.task_2.O()

        @parameter
        fn run_task(idx: Int):
            if idx == 0:
                res_1 = self.task_1.inner[](arg)
            else:
                # Safety: You cannot instanciate this struct if this is not true.
                inp_2 = rebind[C2.I](arg)
                res_2 = self.task_2.inner[](inp_2)

        sync_parallelize[run_task](2)

        return (res_1^, res_2^)


@fieldwise_init("implicit")
struct _Fn[In: InType, Out: OutType](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)
