from runtime.asyncrt import Task, TaskGroup
from sys.intrinsics import _type_is_eq_parse_time


comptime FnToOut[f: FnTrait] = f.O


trait FnTrait(Movable, TrivialRegisterPassable):
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDestructible
    comptime F: fn(Self.I) -> Self.O


@always_inline("nodebug")
fn seq_fn[
    In: AnyType,
    M: AnyType & ImplicitlyDestructible,
    O: AnyType & ImplicitlyDestructible,
    //,
    f: fn(In) -> M,
    l: fn(M) -> O,
](val: In) -> O:
    return l(f(val))


comptime InputsMatch[
    fns: Variadic.TypesOfTrait[FnTrait], T: FnTrait
] = _type_is_eq_parse_time[fns[0].I, T.I]()


@always_inline("nodebug")
fn par_fns[
    In: AnyType, *fns: FnTrait
](val: In, out outs: Tuple[*Variadic.map_types_to_types[fns, FnToOut]]):
    comptime assert Variadic.size(
        Variadic.filter_types[*fns, predicate = InputsMatch[fns]]
    ) == Variadic.size(fns), "All input types should be the same."

    tg = TaskGroup()

    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(outs))

    @parameter
    for ci in range(Variadic.size(fns)):

        @parameter
        async fn task():
            ref inp = rebind[fns[ci].I](val)
            outs[ci] = rebind_var[type_of(outs[ci])](fns[ci].F(inp))

        tg.create_task(task())

    tg.wait()


struct Fns[*fns: FnTrait](TrivialRegisterPassable):
    comptime i = Self.fns[0].I
    comptime o = Tuple[*Variadic.map_types_to_types[Self.fns, FnToOut]]
    comptime F = par_fns[Self.i, *Self.fns]

    @always_inline("builtin")
    fn __init__(out self):
        pass

    @always_inline("builtin")
    fn __add__(
        self, other: Fn[i = Self.i]
    ) -> Fns[*Variadic.concat_types[Self.fns, Variadic.types[Fn[other.F]]]]:
        return Fns[
            *Variadic.concat_types[Self.fns, Variadic.types[Fn[other.F]]]
        ]()

    @always_inline("builtin")
    fn __rshift__(self, other: Fn[i = Self.o]) -> Fn[seq_fn[Self.F, other.F]]:
        return Fn[seq_fn[Self.F, other.F]]()

    @always_inline("builtin")
    fn __rshift__(
        self, other: Fns[**_]
    ) -> Fn[
        seq_fn[Self.F, rebind[fn(Self.o) -> other.o](other.F)]
    ] where _type_is_eq_parse_time[Self.o, other.i]():
        return Fn[seq_fn[Self.F, rebind[fn(Self.o) -> other.o](other.F)]]()


struct Fn[i: AnyType, o: Movable & ImplicitlyDestructible, //, f: fn(i) -> o](
    FnTrait
):
    comptime I = Self.i
    comptime O = Self.o
    comptime F = Self.f

    @always_inline("builtin")
    fn __init__(out self):
        pass

    @always_inline("builtin")
    fn __rshift__(self, other: Fn[i = Self.o]) -> Fn[seq_fn[Self.F, other.F]]:
        return Fn[seq_fn[Self.F, other.F]]()

    @always_inline("builtin")
    fn __rshift__(
        self, other: Fns[**_]
    ) -> Fn[
        seq_fn[Self.F, rebind[fn(Self.o) -> other.o](other.F)]
    ] where _type_is_eq_parse_time[Self.o, other.i]():
        return Fn[seq_fn[Self.F, rebind[fn(Self.o) -> other.o](other.F)]]()

    @always_inline("builtin")
    fn __add__(self, other: Fn[i = Self.i]) -> Fns[Self, Fn[other.F]]:
        return Fns[Self, Fn[other.F]]()
