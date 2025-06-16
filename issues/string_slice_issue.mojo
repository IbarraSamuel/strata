trait OtherTrait:
    # I choose something I know that exists on StringSlice
    # but could be any other trait StringSlice already conforms to.
    fn byte_length(self) -> Int:
        ...


# example 1: Works
@fieldwise_init
struct CopyableOnly[T: Copyable](Copyable):
    var value: T


# Example 2: Works
@fieldwise_init
struct MovableOnly[T: Movable](Movable):
    var value: T


# Failing on __moveinit__ call
@fieldwise_init
struct MovableAndOther[T: Movable & OtherTrait](Movable):
    var value: T


# Failing on __copyinit__ call
@fieldwise_init
struct CopyableAndOther[T: Copyable & OtherTrait](Copyable):
    var value: T


fn test():
    str = String("Hello")
    res = str.removesuffix("H")
    slice = (
        str.as_string_slice()
    )  # change it to .as_string_slice_mut() and all works :)

    # example 1
    var c = CopyableOnly(slice)
    other_c = c  # Works

    # example 2
    var m = MovableOnly(slice)
    other_m = m^  # Works

    # example 3 -- fails
    var s = MovableAndOther(slice)
    other_s = s^
    # argument of implicit __moveinit__ call allows writing a memory location previously readable through another aliased argument
    # 'str' memory accessed through reference embedded in value of type 'DictEntry[StringSlice[(muttoimm str)], Int]'

    # example 4 -- fails
    var o = CopyableAndOther(slice)
    other_o = o
    # argument of implicit __copyinit__ call allows writing a memory location previously readable through another aliased argument
    # 'str' memory accessed through reference embedded in value of type 'DictEntry[StringSlice[(muttoimm str)], Int]'

    # Implementing it manually (Movable and Copyable traits) doesn't solve the issue.


fn some_test() raises:
    some_str = String("hello,world")  # simple string
    slice = StringSlice(some_str)  # create an slice with an immutable origin
    parts = slice.split(",")
    dct = Dict[__type_of(slice).Immutable, Int]()
    for part in parts:
        dct[
            part
        ]  # Do not fail but it's unusable. Try to assign it to something and will fail
        dct[
            part
        ] = 0  # argument of '__setitem__' call allows writing a memory location previously readable through another aliased argument
        dct.setdefault(
            part, 0
        )  # argument of '__setitem__' call allows writing a memory location previously readable through another aliased argument
        dct.get(
            part, 0
        )  # argument of '__setitem__' call allows writing a memory location previously readable through another aliased argumentfn some_test() raises:
