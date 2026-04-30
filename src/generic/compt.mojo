from std.runtime.asyncrt import Task, TaskGroup
from std.sys.intrinsics import _type_is_eq_parse_time
from std.memory import UnsafeMaybeUninit

comptime FnToOut[f: FnTrait] = f.O


comptime FnInputMatch[I: AnyType, T: FnTrait] = _type_is_eq_parse_time[I, T.I]()

# comptime InputsMatch[*fns: FnTrait] = Variadic.size_types[
#     Variadic.filter_types[*fns, predicate=_FnInputMatch[fns[0].I, _]]
# ] == Variadic.size_types[fns]


trait FnTrait(Movable, TrivialRegisterPassable):
    comptime I: AnyType
    comptime O: Movable & ImplicitlyDestructible
    comptime F: def(Self.I) thin -> Self.O


def seq_fn[
    In: AnyType,
    M: AnyType & ImplicitlyDestructible,
    O: AnyType & ImplicitlyDestructible,
    //,
    f: def(In) thin -> M,
    l: def(M) thin -> O,
](val: In) -> O:
    return l(f(val))


def par_fns[
    *fns: FnTrait where fns.all_satisfies[FnInputMatch[fns[0].I, _]]()
](val: fns[0].I, out outs: Tuple[*fns.map[FnToOut]()]):
    tg = TaskGroup()

    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(outs))

    comptime for ci in range(fns.size):

        @parameter
        async def task():
            ref inp = rebind[fns[ci].I](val)
            outs[ci] = rebind_var[outs.element_types[ci]](fns[ci].F(inp))

        tg.create_task(task())

    tg.wait()


@fieldwise_init
struct F[
    i: AnyType, o: Movable & ImplicitlyDestructible, //, f: def(i) thin -> o
](FnTrait):
    comptime I = Self.i
    comptime O = Self.o
    comptime F = Self.f

    comptime seq[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: def(Self.o) thin -> other_o,
    ] = F[seq_fn[Self.f, other_f]]

    comptime par[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: def(Self.i) thin -> other_o,
    ] = FG[Self, F[other_f]]

    # comptime par[
    #     *fns: FnTrait where InputsMatch[
    #         *Variadic.concat_types[T=FnTrait, Variadic.types[Self], fns]
    #     ]
    # ] = FG[*Variadic.concat_types[T=FnTrait, Variadic.types[Self], fns]]

    comptime comptime_run[i: Self.i] = Self.f(i)

    @staticmethod
    def run(inp: Self.i) -> Self.o:
        return Self.f(inp)


@fieldwise_init
struct FG[*fns: FnTrait where fns.all_satisfies[FnInputMatch[fns[0].I, _]]()]:
    comptime I = Self.fns[0].I
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    comptime F = par_fns[*Self.fns]

    comptime seq[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: def(Self.O) thin -> other_o,
    ] = F[seq_fn[Self.F, other_f]]

    comptime par[
        other_o: Movable & ImplicitlyDestructible,
        //,
        other_f: def(Self.I) thin -> other_o where TypeList._concat[
            Self.fns.values, TypeList.of[F[other_f]].values
        ]().all_satisfies[
            FnInputMatch[
                TypeList._concat[
                    Self.fns.values, TypeList.of[F[other_f]].values
                ]()[0].I,
                _,
            ]
        ](),
    ] = FG[*TypeList._concat[Self.fns.values, TypeList.of[F[other_f]].values]()]

    comptime comptime_run[i: Self.I] = Self.F(i)

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        return Self.F(inp)
