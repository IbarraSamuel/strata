from algorithm import sync_parallelize
from builtin import variadic_size

alias MutCallablePack = VariadicPack[False, _, MutCallable, *_]


trait _Callable:
    fn __call__(mut self):
        ...


trait MutCallable(_Callable):
    # ---- FOR MUTABLE VERSIONS -----
    fn __add__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[_Callable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    fn __rshift__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[_Callable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], _TaskRef[origin=o, type_of(other)]
    ]:
        return {_TaskRef(self), _TaskRef(other)}

    # When a pure MutCallable (first value) mets a var
    fn __add__[
        s: MutableOrigin, //
    ](ref [s]self, var other: Some[Movable & _Callable]) -> ParallelTaskPair[
        _TaskRef[origin=s, Self], type_of(other)
    ]:
        return {_TaskRef(self), other^}

    fn __rshift__[
        s: MutableOrigin, //
    ](ref [s]self, var other: Some[Movable & _Callable]) -> SequentialTaskPair[
        _TaskRef[origin=s, Self], type_of(other)
    ]:
        return {_TaskRef(self), other^}


trait _MovableMutCallable(Movable, _Callable):
    fn __call__(mut self):
        ...

    fn __add__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[_Callable]) -> ParallelTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __rshift__[
        o: MutableOrigin, //
    ](var self, ref [o]other: Some[_Callable]) -> SequentialTaskPair[
        Self, _TaskRef[origin=o, type_of(other)]
    ]:
        return {self^, _TaskRef(other)}

    fn __add__(
        var self, var other: Some[_Callable & Movable]
    ) -> ParallelTaskPair[Self, type_of(other)]:
        return {self^, other^}

    fn __rshift__(
        var self, var other: Some[_Callable & Movable]
    ) -> SequentialTaskPair[Self, type_of(other)]:
        return {self^, other^}


struct SeriesTask[o: MutableOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: SeriesTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        alias size = variadic_size(ts)

        @parameter
        for ci in range(size):
            self.storage[ci].__call__()


struct ParallelTask[o: MutableOrigin, //, *ts: MutCallable](MutCallable):
    var storage: MutCallablePack[o, *ts]

    fn __init__(out self: ParallelTask[o = args.origin, *ts], mut*args: *ts):
        self.storage = MutCallablePack(args._value)

    fn __call__(mut self):
        alias size = variadic_size(ts)

        @parameter
        fn run_task(i: Int):
            @parameter
            for ci in range(size):
                if ci == i:
                    self.storage[ci].__call__()
                    return

        sync_parallelize[run_task](size)


@fieldwise_init
struct SequentialTaskPair[T1: Movable & _Callable, T2: Movable & _Callable](
    _MovableMutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        self.t1.__call__()
        self.t2.__call__()


@fieldwise_init
struct ParallelTaskPair[T1: Movable & _Callable, T2: Movable & _Callable](
    _MovableMutCallable
):
    var t1: T1
    var t2: T2

    fn __call__(mut self):
        @parameter
        fn run_task(i: Int):
            if i == 0:
                self.t1.__call__()
            else:
                self.t2.__call__()

        sync_parallelize[run_task](2)


@register_passable("trivial")
struct _TaskRef[origin: MutableOrigin, //, T: _Callable](Movable & _Callable):
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        self.inner = Pointer(to=inner)

    fn __call__(self):
        self.inner[]()
