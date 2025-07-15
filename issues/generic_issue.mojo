trait WithAnAlias:
    alias A: AnyType


# Struct that conforms to `WithAnAlias`
struct SomeStruct(WithAnAlias):
    alias A = Int


# Needs a struct that conforms to `WithAnAlias`
# Will assing a and b automatically
struct SomeWrapper[t: WithAnAlias, a: AnyType, b: AnyType]:
    fn __init__(out self: SomeWrapper[t, t.A, t.A]):
        pass


fn main():
    sw = SomeWrapper[SomeStruct]()
    # invalid initialization: could not deduce parameter 'b' of parent struct 'SomeWrapper'
