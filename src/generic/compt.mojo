from std.runtime._asyncrt import Task, TaskGroup

# from std.memory import UnsafeMaybeUninit

comptime FnToOut[f: FnTrait] = f.O
comptime FnInputMatch[I: AnyType, T: FnTrait] = I == T.I


trait FnTrait(Movable, TrivialRegisterPassable):
    comptime I: AnyType
    comptime O: Movable & Deinitable
    comptime F: def(Self.I) thin -> Self.O

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        ...


def seq_fn[
    In: AnyType,
    M: Deinitable,
    O: AnyType,
    //,
    f: def(In) thin -> M,
    l: def(M) thin -> O,
](val: In) -> O:
    return l(f(val))


# def par_fns[
#     *fns: FnTrait
# ](val: fns[0].I, out outs: Tuple[*fns.map[FnToOut]()]) where fns.all[
#     FnInputMatch[fns[0].I, _]
# ]():
#     var tg = TaskGroup()

#     __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(outs))

#     comptime for ci in range(fns.length):

#         @__parameter
#         async def task():
#             ref inp = rebind[fns[ci].I](val)
#             comptime f = fns[ci].F
#             outs[ci] = rebind_var[outs.Ts[ci]](f(inp))

#         tg.create_task(task())


#     tg.wait()
@always_inline
__async def _run_fn_task[
    ci: Int,
    *fns: FnTrait,
    in_orig: ImmOrigin,
    out_orig: MutOrigin,
](
    in_ptr: Pointer[fns[0].I, in_orig],
    out_ptr: Pointer[Tuple[*fns.map[FnToOut]()].Ts[ci], out_orig],
):
    ref inp = rebind[fns[ci].I](in_ptr[])
    out_ptr[] = rebind_var[Tuple[*fns.map[FnToOut]()].Ts[ci]](fns[ci].run(inp))


def par_fns[
    *fns: FnTrait
](val: fns[0].I, out o: Tuple[*fns.map[FnToOut]()]) where fns.all[
    FnInputMatch[fns[0].I, _]
]():
    var tg = TaskGroup()
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(o))

    var in_ptr = Pointer(to=val)
    comptime for ci in range(fns.length):
        var out_ptr = Pointer(to=o[ci])
        tg.create_task(_run_fn_task[ci, *fns](in_ptr, out_ptr))
    tg.wait()


@fieldwise_init
struct F[i: AnyType, o: Movable & Deinitable, //, f: def(i) thin -> o](FnTrait):
    comptime I = Self.i
    comptime O = Self.o
    comptime F = Self.f

    comptime seq[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.o) thin -> other_o,
    ] = F[seq_fn[Self.f, other_f]]

    comptime par[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.i) thin -> other_o,
    ] = FG[Self, F[other_f]]

    comptime comptime_run[i: Self.i] = Self.f(i)

    @staticmethod
    def run(inp: Self.i) -> Self.o:
        return Self.f(inp)


# # TODO: Solve this deprecated message once we have an alternative for this...
@fieldwise_init
struct FG[*fns: FnTrait] where fns.all[FnInputMatch[fns[0].I, _]]():
    comptime I = Self.fns[0].I
    comptime O = Tuple[*Self.fns.map[FnToOut]()]
    comptime F = par_fns[*Self.fns]

    comptime seq[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.O) thin -> other_o,
    ] = F[seq_fn[Self.F, other_f]]

    comptime par[
        other_o: Movable & Deinitable,
        //,
        other_f: def(Self.I) thin -> other_o,
    ] where TypeList._concat[
        Self.fns.values, TypeList.of[F[other_f]].values
    ]().all[
        FnInputMatch[
            TypeList._concat[Self.fns.values, TypeList.of[F[other_f]].values]()[
                0
            ].I,
            _,
        ]
    ]() = FG[
        *TypeList._concat[Self.fns.values, TypeList.of[F[other_f]].values]()
    ]

    comptime comptime_run[i: Self.I] = Self.F(i)

    @staticmethod
    def run(inp: Self.I) -> Self.O:
        return Self.F(inp)
