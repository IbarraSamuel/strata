@fieldwise_init
struct Fn[In: AnyType, Out: AnyType]:
    var func: fn (In) -> Out


fn string_to_string(value: String) -> String:
    return value


fn int_to_string(value: Int) -> String:
    return ""


fn string_to_int(value: String) -> Int:
    return 0


fn int_to_int(value: Int) -> Int:
    return value


fn none_to_int(inp: NoneType) -> Int:
    pass


fn int_to_none(value: Int):
    pass


fn int_to_simd(value: Scalar[DType.float32], out v: Scalar[DType.float32]):
    v = 1


# Always when Int is returned, there is an error
fn main():
    string_to_string = Fn(string_to_string)  # All good! :)
    int_to_str = Fn(int_to_string)  # All good! :)

    str_to_int = Fn(  # invalid initialization: could not deduce parameter 'In' of parent struct 'Fn'
        string_to_int
    )
    int_to_int = Fn(  # invalid initialization: could not deduce parameter 'In' of parent struct 'Fn'
        int_to_int
    )
    none_to_int = Fn(none_to_int)

    int_to_none = Fn(int_to_none)

    int_to_sim = Fn(int_to_simd)
