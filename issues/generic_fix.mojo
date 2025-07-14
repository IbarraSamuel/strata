trait Callable:
    alias I: AnyType
    alias O: AnyType

    fn call(self, arg: I) -> O:
        ...


struct Mode[mode: IntLiteral = -1]:
    alias Sequential: Self = 1
    alias Parallel: Self = 2

    fn __init__(out self: Mode[1], mode: __type_of(1)):
        pass

    fn __init__(out self: Mode[2], mode: __type_of(2)):
        pass


struct Task[T: Callable & Movable](Callable):
    alias I = T.I
    alias O = T.O

    var v: T

    fn __init__(out self, owned v: T):
        self.v = v^

    fn call(self, arg: Self.I) -> Self.O:
        return self.v.call(arg)

    fn __rshift__(
        self, owned other: Task[T]
    ) -> TaskPair[Mode.Parallel, Self, T]:
        return {self^, other^}


struct TaskPair[M: Mode, T1: Callable & Movable, T2: Callable & Movable](
    Callable, Movable
):
    alias I = T1.I
    alias O = T2.O
    var t1: T1
    var t2: T2

    fn __init__(out self: TaskPair[1, T1, T2], owned t1: T1, owned t2: T2) requires T1.O == T2.I:
        self.t1 = t1^
        self.t2 = t2^

    fn call(self, arg: T1.I) -> T2.O:
        return self.t2.call(self.t1.call(arg))


struct Fn[In: AnyType, Out: AnyType](Callable, Movable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __init__(out self, func: fn (In) -> Out):
        self.func = func

    fn call(self, arg: Self.I) -> Self.O:
        return self.func(arg)


fn itostr(v: Int) -> String:
    return String(v)


fn strtoi(v: String) -> Int:
    try:
        return Int(v)
    except:
        return -1


fn main():
    graph = Task(Fn(itostr)) >> Fn(strtoi) >> Fn(itostr) >> Fn(strtoi)
