trait Callable:
    fn __call__(self):
        ...

    fn __add__[
        s: MutableOrigin, o: MutableOrigin, //
    ](ref [s]self, ref [o]other: Some[Callable]):
        print("Adding")


struct MyTask[name: StringLiteral](Callable):
    fn __init__(out self):
        pass

    fn __call__(self):
        pass


fn main():
    var _mt = MyTask["Hello"]()
