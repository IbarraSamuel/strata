from sys.intrinsics import _type_is_eq_parse_time


trait C:
    alias I: AnyType


@fieldwise_init
struct Ser[c1: C, c2: C where _type_is_eq_parse_time[c1.I, c2.I]()](C):
    alias I = c1.I

    fn some_method[
        o: C where _type_is_eq_parse_time[Self.I, o.I]()
    ](self) -> Ser[Self, o]:  # Why not satisfied??
        return {}


struct C1(C):
    alias I = Int


fn main():
    res = Ser[C1, C1]()
    res.some_method[C1]()
