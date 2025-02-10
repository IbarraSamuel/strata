from move.task.traits import Runnable


struct RunnablePack[origin: Origin, *Ts: Runnable](Copyable):
    """Stores a reference variadic pack of `Runnable` structs."""

    alias _mlir_type = VariadicPack[origin, Runnable, *Ts]._mlir_type

    var storage: Self._mlir_type

    @implicit
    fn __init__(out self, storage: Self._mlir_type):
        self.storage = storage

    fn __copyinit__(out self, other: Self):
        self.storage = other.storage

    fn __getitem__[i: Int](self) -> ref [origin._mlir_origin] Ts[i.value]:
        value = __mlir_op.`lit.ref.pack.extract`[index = i.value](self.storage)
        return __get_litref_as_mvalue(value)
