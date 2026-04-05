from std.sys.intrinsics import _type_is_eq_parse_time


trait WithA:
    comptime A: AnyType


@fieldwise_init
struct Concat[a: WithA, b: WithA where _type_is_eq_parse_time[a.A, b.A]()]:
    pass


trait WithASum(WithA):
    def __add__[
        o: WithA where _type_is_eq_parse_time[o.A, Self.A]()
    ](self, other: o) -> Concat[Self, o]:
        return {}
