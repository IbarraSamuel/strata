@fieldwise_init
struct Fn[In: AnyType, Out: AnyType]:
    var func: fn (In) -> Out


fn string_to_int(value: String) -> Int:
    return 0


fn int_to_string(value: Int) -> String:
    return ""


fn main():
    # str_to_int = Fn(string_to_int) # invalid initialization: could not deduce parameter 'In' of parent struct 'Fn'
    int_to_str = Fn(int_to_string)  # All good! :)
