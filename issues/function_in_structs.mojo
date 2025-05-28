@fieldwise_init
struct Fn[In: AnyType, Out: AnyType]:
    var func: fn (In) -> Out


fn string_to_int(value: String) -> Int:
    return 0


fn int_to_string(value: Int) -> String:
    return ""


fn int_to_int(value: Int) -> Int:
    return value


fn string_to_string(value: String) -> String:
    return value


fn main():
    str_to_int = Fn(  # invalid initialization: could not deduce parameter 'In' of parent struct 'Fn'
        string_to_int
    )
    int_to_str = Fn(int_to_string)  # All good! :)
    int_to_int = Fn(  # invalid initialization: could not deduce parameter 'In' of parent struct 'Fn'
        int_to_int
    )
    string_to_string = Fn(string_to_string)  # All good! :)
