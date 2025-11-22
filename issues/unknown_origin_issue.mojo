from random import random_float64


struct Point:
    var x: Float64
    var y: Float64

    fn __init__(out self, x: Float64, y: Float64):
        self.x = x
        self.y = y


struct PointBox[
    point_origin: Origin,
](Movable):
    var point_ptr: Pointer[Point, point_origin]

    fn __init__(
        out self,
        ref [point_origin]point: Point,
    ):
        self.point_ptr = Pointer(to=point)


fn random_pointer[
    o: Origin
](
    ref [o]point: Point = Point(x=random_float64(), y=random_float64())
) -> PointBox[o]:
    return PointBox(point=point)


fn main():
    print("hi")
    var res_2 = random_pointer[MutOrigin.external]()
    var ptr = res_2.point_ptr[]
    print(ptr)
    print("bye")
