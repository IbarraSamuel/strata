# ISSUE: How to keep track of a *args origin?
# the Variadic Pack contains a lifetime but cannot be used


# Imagine I want to store a variadic pack
struct VPack[origin: Origin, *types: AnyType]:
    var value: VariadicPack[origin, AnyType, *types]
    # How this can be initialized without some rebind?
    # VariadicPack requires a lifetime but its a @register_passable type, so __origin_of() dont work for it.
    # Also, ref[origin] *args is not allowed still. My workaround is to use the origin of args._value or not
    # store the VariadicPack, but the value itself, and do math to access it's elements,
    # or instantiate again a VariadicPack.


struct VpackWorking[origin: Origin, *types: AnyType]:
    alias _mlir_type = VariadicPack[origin, AnyType, *types]._mlir_type
    var storage: Self._mlir_type

    fn __init__(
        out self: VpackWorking[__origin_of(args._value), *types], *args: *types
    ):
        alias V = __type_of(self)._mlir_type
        self.storage = rebind[V](args._value)
