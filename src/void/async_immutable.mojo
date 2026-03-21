from std.runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async def __call__(self):
        ...

    def __add__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref[s] self, ref[o] other: t) -> ParTaskPair[Self, t, s, o]:
        return {self, other}

    def __rshift__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref[s] self, ref[o] other: t) -> SerTaskPair[Self, t, s, o]:
        return {self, other}


struct SerTaskPair[
    m1: Bool,
    m2: Bool,
    //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[mut=m1],
    o2: Origin[mut=m2],
](AsyncCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async def __call__(self):
        await self.t1[]()
        await self.t2[]()

    def run(self):
        _run(self.__call__())


struct ParTaskPair[
    m1: Bool,
    m2: Bool,
    //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[mut=m1],
    o2: Origin[mut=m2],
](AsyncCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    def __init__(out self, ref[Self.o1] t1: Self.T1, ref[Self.o2] t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async def __call__(self):
        tg = TaskGroup()
        tg.create_task(self.t1[]())
        tg.create_task(self.t2[]())
        await tg

    def run(self):
        _run(self.__call__())
