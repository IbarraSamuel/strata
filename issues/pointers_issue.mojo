# Any struct
@value
struct Struct:
    pass


# Holds a Mutable and Immutable Origin. Only one is Mutable.
@value
struct PointerPair[o: MutableOrigin, o2: ImmutableOrigin]:
    var ref1: Pointer[Struct, o]
    var ref2: Pointer[Struct, o2]


fn main():
    ms = Struct()
    ms_ptr = Pointer(to=ms)

    # Again, only one is mutable.
    _ = PointerPair(ms_ptr, ms_ptr.get_immutable())  # fails with:
    # argument of '__init__' call allows writing a memory location previously writable through another aliased argument
    # pointers_issue.mojo(29, 20): 'ms' memory accessed through reference embedded in value of type 'Pointer[Struct, (muttoimm ms)]'
