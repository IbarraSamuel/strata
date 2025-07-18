from random import random_float64


struct Point[origin: Origin]:
    var x: Float64
    var y: Float64

    fn __init__(out self, x: Float64, y: Float64):
        self.x = x
        self.y = y


struct PointBox[
    point_origin: Origin,
    origin: Origin,
](Movable):
    var point_ptr: Pointer[Point[origin], point_origin]

    fn __init__(
        out self,
        ref [point_origin]point: Point[origin],
    ):
        self.point_ptr = Pointer(to=point)


fn random_pointer[
    o: Origin, origin: Origin
](
    ref [o]point: Point[origin] = Point[origin](
        x=random_float64(), y=random_float64()
    )
) -> PointBox[o, origin]:
    var point_box = PointBox(
        point=point,
    )
    return point_box^


fn main():
    res_2 = random_pointer[MutableAnyOrigin, MutableAnyOrigin]()
    print(res_2.point_ptr[].x)
