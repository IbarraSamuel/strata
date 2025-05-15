# ISSUE: How to keep track of a *args origin?
# the Variadic Pack contains a lifetime but cannot be used


# Imagine I want to store a variadic pack
struct VPack[origin: Origin, *types: AnyType]:
    var value: VariadicPack[True, origin, AnyType, *types]

    fn __init__(out self: VPack[args.origin, *types], owned *args: *types):
        self.value = args^

    # Ok, but this is only if it's owned, I don't want to own each task.


struct VpackWorking[origin: Origin, *types: AnyType]:
    alias _mlir_type = VariadicPack[False, origin, AnyType, *types]._mlir_type
    var storage: Self._mlir_type

    fn __init__(out self: VpackWorking[args.origin, *types], *args: *types):
        self.storage = args._value
