from runtime.asyncrt import (
    TaskGroupContext,
    AnyCoroutine,
    TaskGroup,
    _run as execute,
)


trait AsyncCallable:
    async fn __call__(self):
        ...


struct TaskRef[T: AsyncCallable, origin: Origin](AsyncCallable):
    var v: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]v: T):
        self.v = Pointer(to=v)

    async fn __call__(self):
        await self.v[]()

    fn __add__[
        t: AsyncCallable, o: Origin
    ](self, ref [o]other: t) -> ParTaskPair[T, t, origin, o]:
        return ParTaskPair(self.v[], other)

    fn __rshift__[
        t: AsyncCallable, o: Origin
    ](self, ref [o]other: t) -> SerTaskPair[T, t, origin, o]:
        return SerTaskPair(self.v[], other)


struct SerTaskPair[
    T1: AsyncCallable, T2: AsyncCallable, o1: Origin, o2: Origin
](AsyncCallable):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    async fn __call__(self):
        await self.t1[]()
        await self.t2[]()

    fn __add__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPair[Self, t, s, o]:
        return ParTaskPair(self, other)

    fn __rshift__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPair[Self, t, s, o]:
        return SerTaskPair(self, other)


struct ParTaskPair[
    T1: AsyncCallable, T2: AsyncCallable, o1: Origin, o2: Origin
](AsyncCallable):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    async fn __call__(self):
        tg = TaskGroup()
        tg.create_task(self.t1[]())
        tg.create_task(self.t2[]())
        await tg

    fn __add__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPair[Self, t, s, o]:
        return ParTaskPair(self, other)

    fn __rshift__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPair[Self, t, s, o]:
        return SerTaskPair(self, other)
