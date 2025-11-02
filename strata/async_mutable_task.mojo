from runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async fn __call__(mut self):
        ...


struct TaskRef[T: AsyncCallable, origin: MutOrigin](AsyncCallable, Movable):
    var v: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]v: T):
        self.v = Pointer(to=v)

    async fn __call__(self):
        await self.v[]()

    fn __add__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __add__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __rshift__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}

    fn run(self):
        _run(self())


@fieldwise_init
struct SerTaskPair[T1: AsyncCallable & Movable, T2: AsyncCallable & Movable](
    AsyncCallable, Movable
):
    var t1: T1
    var t2: T2

    async fn __call__(mut self):
        await self.t1()
        await self.t2()

    fn __add__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __add__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __rshift__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}

    fn run(mut self):
        _run(self())


@fieldwise_init
struct ParTaskPair[T1: AsyncCallable & Movable, T2: AsyncCallable & Movable](
    AsyncCallable, Movable
):
    var t1: T1
    var t2: T2

    async fn __call__(mut self):
        tg = TaskGroup()
        tg.create_task(self.t1())
        tg.create_task(self.t2())
        await tg

    fn __add__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> ParTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __add__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> ParTaskPair[Self, t]:
        return {self^, other^}

    fn __rshift__[
        t: AsyncCallable,
        o: MutOrigin,
    ](var self, ref [o]other: t) -> SerTaskPair[Self, TaskRef[t, o]]:
        return {self^, TaskRef(other)}

    fn __rshift__[
        t: AsyncCallable & Movable
    ](var self, var other: t) -> SerTaskPair[Self, t]:
        return {self^, other^}

    fn run(mut self):
        _run(self())
