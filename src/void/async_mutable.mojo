from std.runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async def __call__(mut self):
        ...

    def __add__[
        s: MutOrigin, o: MutOrigin
    ](ref[s] self, ref[o] other: Some[AsyncCallable]) -> ParTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        return {TaskRef(self), TaskRef(other)}

    def __add__[
        s: MutOrigin,
    ](
        ref[s] self,
        var other: Some[AsyncCallable & Movable & ImplicitlyDestructible],
    ) -> ParTaskPair[TaskRef[Self, s], type_of(other)]:
        return {TaskRef(self), other^}

    def __rshift__[
        s: MutOrigin,
        o: MutOrigin,
    ](ref[s] self, ref[o] other: Some[AsyncCallable]) -> SerTaskPair[
        TaskRef[Self, s], TaskRef[type_of(other), o]
    ]:
        return {TaskRef(self), TaskRef(other)}

    def __rshift__[
        s: MutOrigin,
    ](
        ref[s] self,
        var other: Some[AsyncCallable & Movable & ImplicitlyDestructible],
    ) -> SerTaskPair[TaskRef[Self, s], type_of(other)]:
        return {TaskRef(self), other^}


trait AsyncCallableMovable(AsyncCallable, ImplicitlyDestructible, Movable):
    def __add__[
        o: MutOrigin,
    ](var self, ref[o] other: Some[AsyncCallable]) -> ParTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        return {self^, TaskRef(other)}

    def __add__[](
        var self,
        var other: Some[AsyncCallable & Movable & ImplicitlyDestructible],
    ) -> ParTaskPair[Self, type_of(other)]:
        return {self^, other^}

    def __rshift__[
        o: MutOrigin,
    ](var self, ref[o] other: Some[AsyncCallable]) -> SerTaskPair[
        Self, TaskRef[type_of(other), o]
    ]:
        return {self^, TaskRef(other)}

    def __rshift__(
        var self,
        var other: Some[AsyncCallable & Movable & ImplicitlyDestructible],
    ) -> SerTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct TaskRef[T: AsyncCallable, origin: MutOrigin](AsyncCallableMovable):
    var v: Pointer[Self.T, Self.origin]

    # @implicit
    def __init__(out self, ref[Self.origin] v: Self.T):
        self.v = Pointer(to=v)

    async def __call__(mut self):
        await self.v[]()


@fieldwise_init
struct SerTaskPair[
    T1: AsyncCallable & Movable & ImplicitlyDestructible,
    T2: AsyncCallable & Movable & ImplicitlyDestructible,
](AsyncCallableMovable):
    var t1: Self.T1
    var t2: Self.T2

    async def __call__(mut self):
        await self.t1()
        await self.t2()

    def run(mut self):
        _run(self())


@fieldwise_init
struct ParTaskPair[
    T1: AsyncCallable & Movable & ImplicitlyDestructible,
    T2: AsyncCallable & Movable & ImplicitlyDestructible,
](AsyncCallableMovable):
    var t1: Self.T1
    var t2: Self.T2

    async def __call__(mut self):
        tg = TaskGroup()
        tg.create_task(self.t1())
        tg.create_task(self.t2())
        await tg

    def run(mut self):
        _run(self())
