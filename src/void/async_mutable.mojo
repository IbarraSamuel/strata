from runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async fn __call__(mut self):
        ...

    fn __add__[
        s: MutOrigin,
        o: MutOrigin,
    ](ref [s]self, ref [o]other: Some[AsyncCallable]) -> ParTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        return {self, other}

    fn __add__[
        s: MutOrigin,
    ](ref [s]self, var other: Some[AsyncCallable & Movable]) -> ParTaskPair[
        TaskRef[Self, s], type_of(other)
    ]:
        return {self, other^}

    fn __rshift__[
        s: MutOrigin,
        o: MutOrigin,
    ](ref [s]self, ref [o]other: Some[AsyncCallable]) -> SerTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        return {self, other}

    fn __rshift__[
        s: MutOrigin,
    ](ref [s]self, var other: Some[AsyncCallable & Movable]) -> SerTaskPair[
        TaskRef[Self, s], type_of(other)
    ]:
        return {self, other^}


trait AsyncCallableMovable(AsyncCallable, Movable):
    fn __add__[
        o: MutOrigin,
    ](var self, ref [o]other: Some[AsyncCallable]) -> ParTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        return {self^, other}

    fn __add__[](
        var self, var other: Some[AsyncCallable & Movable]
    ) -> ParTaskPair[Self, type_of(other)]:
        return {self^, other^}

    fn __rshift__[
        o: MutOrigin,
    ](var self, ref [o]other: Some[AsyncCallable]) -> SerTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        return {self^, other}

    fn __rshift__(
        var self, var other: Some[AsyncCallable & Movable]
    ) -> SerTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct TaskRef[T: AsyncCallable, origin: MutOrigin](AsyncCallableMovable):
    var v: Pointer[Self.T, Self.origin]

    @implicit
    fn __init__(out self, ref [Self.origin]v: Self.T):
        self.v = Pointer(to=v)

    async fn __call__(mut self):
        await self.v[]()


@fieldwise_init
struct SerTaskPair[T1: AsyncCallable & Movable, T2: AsyncCallable & Movable](
    AsyncCallableMovable
):
    var t1: Self.T1
    var t2: Self.T2

    async fn __call__(mut self):
        await self.t1()
        await self.t2()

    fn run(mut self):
        _run(self())


@fieldwise_init
struct ParTaskPair[T1: AsyncCallable & Movable, T2: AsyncCallable & Movable](
    AsyncCallableMovable
):
    var t1: Self.T1
    var t2: Self.T2

    async fn __call__(mut self):
        tg = TaskGroup()
        tg.create_task(self.t1())
        tg.create_task(self.t2())
        await tg

    fn run(mut self):
        _run(self())
