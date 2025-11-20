from runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async fn __call__(self):
        ...

    fn __add__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref [s]self, ref [o]other: t) -> ParTaskPair[Self, t, s, o]:
        return {self, other}

    fn __rshift__[
        s: Origin, o: Origin, t: AsyncCallable
    ](ref [s]self, ref [o]other: t) -> SerTaskPair[Self, t, s, o]:
        return {self, other}


struct SerTaskPair[
    m1: Bool,
    m2: Bool, //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[m1],
    o2: Origin[m2],
](AsyncCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    fn __init__(out self, ref [Self.o1]t1: Self.T1, ref [Self.o2]t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async fn __call__(self):
        await self.t1[]()
        await self.t2[]()

    fn run(self):
        _run(self.__call__())


struct ParTaskPair[
    m1: Bool,
    m2: Bool, //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[m1],
    o2: Origin[m2],
](AsyncCallable):
    var t1: Pointer[Self.T1, Self.o1]
    var t2: Pointer[Self.T2, Self.o2]

    fn __init__(out self, ref [Self.o1]t1: Self.T1, ref [Self.o2]t2: Self.T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async fn __call__(self):
        tg = TaskGroup()
        tg.create_task(self.t1[]())
        tg.create_task(self.t2[]())
        await tg

    fn run(self):
        _run(self.__call__())
