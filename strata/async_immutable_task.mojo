from runtime.asyncrt import TaskGroup, _run


trait AsyncCallable:
    async fn __call__(self):
        ...


struct TaskRef[T: AsyncCallable, origin: Origin](AsyncCallable):
    var v: Pointer[T, origin]

    @implicit
    fn __init__(out self, ref [origin]v: T):
        self.v = Pointer(to=v)

    @always_inline("nodebug")
    async fn __call__(self):
        await self.v[]()

    @always_inline("nodebug")
    fn __add__[
        t: AsyncCallable, o: Origin
    ](self, ref [o]other: t) -> ParTaskPair[T, t, origin, o]:
        return {self.v[], other}

    @always_inline("nodebug")
    fn __rshift__[
        t: AsyncCallable, o: Origin
    ](self, ref [o]other: t) -> SerTaskPair[T, t, origin, o]:
        return {self.v[], other}

    fn run(self):
        _run(self.__call__())


struct SerTaskPair[
    m1: Bool,
    m2: Bool, //,
    T1: AsyncCallable,
    T2: AsyncCallable,
    o1: Origin[m1],
    o2: Origin[m2],
](AsyncCallable):
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async fn __call__(self):
        await self.t1[]()
        await self.t2[]()

    @always_inline("nodebug")
    fn __add__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPair[Self, t, s, o]:
        return {self, other}

    @always_inline("nodebug")
    fn __rshift__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPair[Self, t, s, o]:
        return {self, other}

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
    var t1: Pointer[T1, o1]
    var t2: Pointer[T2, o2]

    fn __init__(out self, ref [o1]t1: T1, ref [o2]t2: T2):
        self.t1 = Pointer(to=t1)
        self.t2 = Pointer(to=t2)

    @always_inline("nodebug")
    async fn __call__(self):
        tg = TaskGroup()
        tg.create_task(self.t1[]())
        tg.create_task(self.t2[]())
        await tg

    @always_inline("nodebug")
    fn __add__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> ParTaskPair[Self, t, s, o]:
        return {self, other}

    @always_inline("nodebug")
    fn __rshift__[
        t: AsyncCallable, s: Origin, o: Origin
    ](ref [s]self, ref [o]other: t) -> SerTaskPair[Self, t, s, o]:
        return {self, other}

    fn run(self):
        _run(self.__call__())


# from time import sleep


# @fieldwise_init
# struct MyTask[i: Int](AsyncCallable):
#     async fn __call__(self):
#         print("Hello From:", i)
#         sleep(0.5)


# fn main():
#     t = MyTask[1]()
#     r = (
#         TaskRef(t)
#         >> MyTask[2]()
#         >> TaskRef(MyTask[3]()) + MyTask[4]()
#         >> MyTask[5]()
#     )
#     r.run()
