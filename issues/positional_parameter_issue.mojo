# Could not use a function as a positional only parameter in a struct


@fieldwise_init
struct FnWrapper[i: AnyType]:
    fn wraps[o: AnyType, //, f: fn (Self.i) -> o](self):
        pass

    @staticmethod
    fn static_wraps[o: AnyType, //, f: fn (Self.i) -> o]():
        pass


fn wrapped_fn(arg: Int) -> Float32:
    return arg


fn main():
    # Works when using keyword argument
    FnWrapper[Int].static_wraps[f=wrapped_fn]()
    FnWrapper[Int]().wraps[f=wrapped_fn]()

    # Fails. Gets confused with o: AnyType
    FnWrapper[Int].static_wraps[wrapped_fn]()
    # invalid call to 'static_wraps': callee parameter #1 has 'AnyType' type, but value has type 'fn(arg: Int) -> SIMD[float32, 1]'
    FnWrapper[Int]().wraps[wrapped_fn]()
    # invalid call to 'wraps': callee parameter #1 has 'AnyType' type, but value has type 'fn(arg: Int) -> SIMD[float32, 1]'
