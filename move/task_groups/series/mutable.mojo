from move.callable import CallableMovable  # , Callable
from move.runners import series_runner


# Series Mutable Pair
struct SeriesTaskPair[t1: CallableMovable, t2: CallableMovable](
    CallableMovable
):
    var v1: t1
    var v2: t2

    @always_inline("nodebug")
    fn __init__(out self, owned v1: t1, owned v2: t2):
        self.v1 = v1^
        self.v2 = v2^

    @always_inline("nodebug")
    fn __moveinit__(out self, owned existing: Self):
        self.v1 = existing.v1^
        self.v2 = existing.v2^

    @always_inline("nodebug")
    fn __call__(mut self):
        series_runner(self.v1, self.v2)


# Parallel Mutable Collections: (NOT WORKING)
# struct SeriesTask[origin: Origin[True], *types: Callable](Callable):
#     var tasks: VariadicPack[origin, Callable, *types]

#     fn __init__(
#         out self: SeriesTask[
#             MutableOrigin.cast_from[__origin_of(args._value)].result, *types
#         ],
#         mut*args: *types,
#     ):
#         value = rebind[__type_of(self.tasks)._mlir_type](args._value)
#         self.tasks = VariadicPack(value, is_owned=False)

#     fn __call__(mut self):
#         series_runner(self.tasks)
