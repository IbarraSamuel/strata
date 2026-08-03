from std.runtime.asyncrt import TaskGroup, _run

comptime MutCallablePack = VariadicPack[
    elt_is_mutable=True, element_trait=MutCallable, False, ...
]


trait _Callable:
    def __call__(mut self):
        ...


trait MutCallable(_Callable):
    # ---- FOR MUTABLE VERSIONS -----
    def __add__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    def __rshift__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # When a pure MutCallable (first value) mets a var
    def __add__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & ImplicitlyDeletable],
    ) -> ParallelTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        return {_TaskRef(self), other^}

    def __rshift__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & ImplicitlyDeletable],
    ) -> SequentialTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        return {_TaskRef(self), other^}


trait _MovableMutCallable(ImplicitlyDeletable, Movable, _Callable):
    def __call__(mut self):
        ...

    def __add__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    def __rshift__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    def __add__(
        var self, var other: Some[_Callable & Movable & ImplicitlyDeletable]
    ) -> ParallelTaskPair[Self, type_of(other)]:
        return {self^, other^}

    def __rshift__(
        var self, var other: Some[_Callable & Movable & ImplicitlyDeletable]
    ) -> SequentialTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct SeriesTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[origin=Self.origin, *Self.ts]

    def __init__(
        out self: SeriesTask[origin=args.origin, *Self.ts],
        mut *args: *Self.ts,
    ):
        self.storage = MutCallablePack[origin=args.origin, *Self.ts](
            args._value
        )

    def __call__(mut self):
        comptime for ci in range(Self.ts.length):
            self.storage[ci].__call__()


struct ParallelTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[origin=Self.origin, *Self.ts]

    def __init__(
        out self: ParallelTask[origin=args.origin, *Self.ts],
        mut *args: *Self.ts,
    ):
        self.storage = MutCallablePack[origin=args.origin, *Self.ts](
            args._value
        )

    def __call__(mut self):
        comptime size = Self.ts.length

        var tg = TaskGroup()
        comptime for ci in range(size):

            async def t() {mut}:
                self.storage[ci].__call__()

            tg.create_task(t())

        tg.wait()


@fieldwise_init
struct SequentialTaskPair[
    T1: Movable & _Callable & ImplicitlyDeletable,
    T2: Movable & _Callable & ImplicitlyDeletable,
](_MovableMutCallable):
    var t1: Self.T1
    var t2: Self.T2

    def __call__(mut self):
        self.t1.__call__()
        self.t2.__call__()


@fieldwise_init
struct ParallelTaskPair[
    T1: Movable & _Callable & ImplicitlyDeletable,
    T2: Movable & _Callable & ImplicitlyDeletable,
](_MovableMutCallable):
    var t1: Self.T1
    var t2: Self.T2

    def __call__(mut self):
        var tg = TaskGroup()

        async def t1() {mut}:
            self.t1.__call__()

        async def t2() {mut}:
            self.t2.__call__()

        tg.create_task(t1())
        tg.create_task(t2())
        tg.wait()


struct _TaskRef[origin: MutOrigin, //, T: _Callable](
    Movable, TrivialRegisterPassable, _Callable
):
    var inner: Pointer[Self.T, Self.origin]

    def __init__(out self, ref[Self.origin] inner: Self.T):
        self.inner = Pointer(to=inner)

    def __call__(self):
        self.inner[]()
