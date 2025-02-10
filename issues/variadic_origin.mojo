struct Foo[origin: Origin, *types: AnyType]:
    alias _mlir_type = VariadicPack[origin, AnyType, *types]._mlir_type
    var storage: Self._mlir_type

    @always_inline("nodebug")
    fn __init__[
        *, o: Origin
    ](out self: Foo[o, *types], pack: VariadicPack[o, AnyType, *types],):
        self.storage = pack._value

    @always_inline("nodebug")
    fn __init__(out self: Foo[__origin_of(args._value), *types], *args: *types):
        self = __type_of(self).__init__[o = __origin_of(args._value)](
            rebind[VariadicPack[__origin_of(args._value), AnyType, *types]](
                args
            )
        )


fn do_something():
    pass


# fn do_something():
#     value = String("test")
#     vlist = VariadicList[Int](1, 2, 3)
#     Foo[__origin_of(vlist), Intable]()

# Foo[__origin_of(value), Stringable](args=VariadicList(value))
