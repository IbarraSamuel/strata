# trait OwnCall:
#     comptime I: AnyType
#     comptime O: Movable

#     fn __call__(self, var arg: Self.I) -> Self.O:
#         ...


# trait OwnCallable(OwnCall):
#     fn __rshift__[
#         so: ImmutOrigin, oo: ImmutOrigin, o: OwnCall, s: OwnCall = Self
#     ](ref [so]self, ref [oo]other: o) -> Sequence[
#         O1=so, O2=oo, T1=s, T2=o, MakeVariadic[s, o]
#     ] where _type_is_eq_parse_time[s.O, o.I]():
#         # TODO: Fix rebind when this is properly handled by compiler.
#         ref _self = rebind[s](self)
#         return {_self, other}
# trait OwnCall:
#     comptime I: AnyType
#     comptime O: Movable

#     fn __call__(self, var arg: Self.I) -> Self.O:
#         ...


# trait OwnCallable(OwnCall):
#     fn __rshift__[
#         so: ImmutOrigin, oo: ImmutOrigin, o: OwnCall, s: OwnCall = Self
#     ](ref [so]self, ref [oo]other: o) -> Sequence[
#         O1=so, O2=oo, T1=s, T2=o, MakeVariadic[s, o]
#     ] where _type_is_eq_parse_time[s.O, o.I]():
#         # TODO: Fix rebind when this is properly handled by compiler.
#         ref _self = rebind[s](self)
#         return {_self, other}

    # fn __add__[
    #     so: ImmutOrigin, oo: ImmutOrigin, o: Call, s: Call = Self
    # ](ref [so]self, ref [oo]other: o) -> Parallel[
    #     origin = origin_of(so, oo), s, o
    # ] where _type_is_eq_parse_time[s.I, o.I]():
    #     # TODO: Fix rebind when this is properly handled by compiler.
    #     ref _self = rebind[s](self)
    #     return {_self, other}
