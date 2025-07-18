trait WithAnAlias:
    alias C: AnyType


@fieldwise_init
struct SomeStruct(WithAnAlias):
    alias C = Int


struct SomeWrapper[t: WithAnAlias, a: AnyType, b: AnyType]:
    fn __init__(out self: SomeWrapper[t, t.C, t.C]):
        pass


fn main():
    sw = SomeWrapper[SomeStruct]()
