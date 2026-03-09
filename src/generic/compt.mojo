from std.runtime.asyncrt import Task, TaskGroup
from std.sys.intrinsics import _type_is_eq_parse_time
from std.memory import UnsafeMaybeUninit

comptime FnToOut[f: FnTrait] = f.O


comptime _FnInputMatch[I: AnyType, T: FnTrait] = _type_is_eq_parse_time[
    I, T.I
]()

comptime InputsMatch[*fns: FnTrait] = Variadic.size(
    Variadic.filter_types[*fns, predicate=_FnInputMatch[fns[0].I, _]]
) == Variadic.size(fns)


trait FnTrait(Movable, TrivialRegisterPassable):
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDestructible
    comptime F: fn(Self.I) -> Self.O


fn seq_fn[
    In: AnyType,
    M: AnyType & ImplicitlyDestructible,
    O: AnyType & ImplicitlyDestructible,
    //,
    f: fn(In) -> M,
    l: fn(M) -> O,
](val: In) -> O:
    return l(f(val))


fn par_fns[
    *fns: FnTrait where InputsMatch[*fns]
](val: fns[0].I, out outs: Tuple[*Variadic.map_types_to_types[fns, FnToOut]]):
    tg = TaskGroup()

    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(outs))

    comptime for ci in range(Variadic.size(fns)):

        @parameter
        async fn task():
            ref inp = rebind[fns[ci].I](val)
            outs[ci] = rebind_var[outs.element_types[ci]](fns[ci].F(inp))

        tg.create_task(task())

    tg.wait()


@fieldwise_init
struct F[i: AnyType, o: Movable & ImplicitlyDestructible, //, f: fn(i) -> o](
    FnTrait
):
    comptime I = Self.i
    comptime O = Self.o
    comptime F = Self.f

    comptime seq[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: fn(Self.o) -> other_o,
    ] = F[seq_fn[Self.f, other_f]]

    comptime par[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: fn(Self.i) -> other_o,
    ] = FG[Self, F[other_f]]

    comptime comptime_run[i: Self.i] = Self.f(i)

    @staticmethod
    fn run(inp: Self.i) -> Self.o:
        return Self.f(inp)


@fieldwise_init
struct FG[*fns: FnTrait where InputsMatch[*fns]]:
    comptime i = Self.fns[0].I
    comptime o = Tuple[*Variadic.map_types_to_types[Self.fns, FnToOut]]
    comptime f = par_fns[*Self.fns]

    comptime seq[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: fn(Self.o) -> other_o,
    ] = F[seq_fn[Self.f, other_f]]

    comptime par[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: fn(Self.i) -> other_o where InputsMatch[
            *Variadic.concat_types[Self.fns, Variadic.types[F[other_f]]]
        ],
    ] = FG[*Variadic.concat_types[Self.fns, Variadic.types[F[other_f]]]]

    comptime comptime_run[i: Self.i] = Self.f(i)

    @staticmethod
    fn run(inp: Self.i) -> Self.o:
        return Self.f(inp)
