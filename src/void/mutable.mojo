from std.algorithm import sync_parallelize
from std.builtin import Variadic

comptime MutCallablePack = VariadicPack[
    elt_is_mutable=True, False, MutCallable, ...
]


trait _Callable:
    fn __call__(mut self):
        ...


trait MutCallable(_Callable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    fn __rshift__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # When a pure MutCallable (first value) mets a var
    fn __add__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & ImplicitlyDestructible],
    ) -> ParallelTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        return {_TaskRef(self), other^}

    fn __rshift__[
        s: MutOrigin, //
    ](
        ref[s] self,
        var other: Some[Movable & _Callable & ImplicitlyDestructible],
    ) -> SequentialTaskPair[_TaskRef[origin=s, Self], type_of(other)]:
        return {_TaskRef(self), other^}


trait _MovableMutCallable(ImplicitlyDestructible, Movable, _Callable):
    fn __call__(mut self):
        ...

    fn __add__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __rshift__[
        o: MutOrigin, //
    ](var self, ref[o] other: Some[_Callable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __add__(
        var self, var other: Some[_Callable & Movable & ImplicitlyDestructible]
    ) -> ParallelTaskPair[Self, type_of(other)]:
        return {self^, other^}

    fn __rshift__(
        var self, var other: Some[_Callable & Movable & ImplicitlyDestructible]
    ) -> SequentialTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct SeriesTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[origin=Self.origin, *Self.ts]

    fn __init__(
        out self: SeriesTask[origin=args.origin, *Self.ts],
        mut *args: * Self.ts,
    ):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        comptime size = Variadic.size(Self.ts)

        comptime for ci in range(size):
            self.storage[ci].__call__()


struct ParallelTask[origin: MutOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[origin=Self.origin, *Self.ts]

    fn __init__(
        out self: ParallelTask[origin=args.origin, *Self.ts],
        mut *args: * Self.ts,
    ):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        comptime size = Variadic.size(Self.ts)

        @parameter
        fn run_task(i: Int):
            comptime for ci in range(size):
                if ci == i:
                    self.storage[ci].__call__()
                    return

        sync_parallelize[run_task](size)


@fieldwise_init
struct SequentialTaskPair[
    T1: Movable & _Callable & ImplicitlyDestructible,
    T2: Movable & _Callable & ImplicitlyDestructible,
](_MovableMutCallable):
    var t1: Self.T1
    var t2: Self.T2

    fn __call__(mut self):
        self.t1.__call__()
        self.t2.__call__()


@fieldwise_init
struct ParallelTaskPair[
    T1: Movable & _Callable & ImplicitlyDestructible,
    T2: Movable & _Callable & ImplicitlyDestructible,
](_MovableMutCallable):
    var t1: Self.T1
    var t2: Self.T2

    fn __call__(mut self):
        @parameter
        fn run_task(i: Int):
            if i == 0:
                self.t1.__call__()
            else:
                self.t2.__call__()

        sync_parallelize[run_task](2)


struct _TaskRef[origin: MutOrigin, //, T: _Callable](
    Movable, TrivialRegisterPassable, _Callable
):
    var inner: Pointer[Self.T, Self.origin]

    fn __init__(out self, ref[Self.origin] inner: Self.T):
        self.inner = Pointer(to=inner)

    fn __call__(self):
        self.inner[]()
