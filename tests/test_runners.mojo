from strata import generic, immutable, mutable, type, generic_comptime
from testing import TestSuite, assert_true, assert_equal
from time import monotonic, sleep

comptime TIME = 0.1


struct GenericParallel(generic.Callable):
    alias I = Int
    alias O = NoneType

    var start: UnsafePointer[UInt, MutAnyOrigin]
    var end: UnsafePointer[UInt, MutAnyOrigin]

    fn __init__(out self, mut s: UInt, mut e: UInt):
        self.start = UnsafePointer(to=s)
        self.end = UnsafePointer(to=e)

    fn __call__(self, v: Int):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


fn test_generic_parallel() raises:
    comptime GP = GenericParallel

    var start1, end1 = (UInt(0), UInt(0))
    var start2, end2 = (UInt(0), UInt(0))
    var start3, end3 = (UInt(0), UInt(0))

    var p1 = GP(start1, end1)
    var p2 = GP(start2, end2)
    var p3 = GP(start3, end3)

    var graph = p1 + p2 + p3

    var result = graph(0)

    assert_true(p1.start[] < p1.end[])
    assert_true(p1.start[] < p2.end[])
    assert_true(p1.start[] < p3.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p2.end[])
    assert_true(p3.start[] < p2.end[])
    assert_true(p3.start[] < p3.end[])
    assert_true(p3.start[] < p3.end[])


fn int_to_float(v: Int) -> Float32:
    return v


fn sum_tuple(v: Tuple[Float32, Float32]) -> Int:
    return Int(v[0] + v[1])


fn test_generic_two_parallels() raises:
    var itof = generic.Fn(int_to_float)
    var stp = generic.Fn(sum_tuple)
    var graph = itof + itof >> stp + stp

    var r1, r2 = graph(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


fn test_generic_comptime_parallel() raises:
    fn comptime_parallel(v: NoneType) -> Tuple[UInt, UInt]:
        var start = monotonic()
        sleep(TIME)
        var end = monotonic()
        return start, end

    comptime MyFn = generic_comptime.Fn[comptime_parallel]
    var t1, t2, t3 = MyFn(), MyFn(), MyFn()

    var _graph = t1 + t2 + t3

    var p1, p2, p3 = _graph.F(None)

    assert_true(p1[0] < p1[1])
    assert_true(p1[0] < p2[1])
    assert_true(p1[0] < p3[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p2[1])
    assert_true(p3[0] < p2[1])
    assert_true(p3[0] < p3[1])
    assert_true(p3[0] < p3[1])


fn test_generic_comptime_two_parallels() raises:
    comptime itof = generic_comptime.Fn[int_to_float]()
    comptime stp = generic_comptime.Fn[sum_tuple]()

    comptime graph = itof + itof >> stp + stp

    var r1, r2 = graph.F(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


struct ImmutParallel(immutable.ImmutCallable):
    var start: UnsafePointer[UInt, MutAnyOrigin]
    var end: UnsafePointer[UInt, MutAnyOrigin]

    fn __init__(out self, mut s: UInt, mut e: UInt):
        self.start = UnsafePointer(to=s)
        self.end = UnsafePointer(to=e)

    fn __call__(self):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


fn test_immut_parallel() raises:
    comptime GP = ImmutParallel

    var start1, end1 = (UInt(0), UInt(0))
    var start2, end2 = (UInt(0), UInt(0))
    var start3, end3 = (UInt(0), UInt(0))

    var p1 = GP(start1, end1)
    var p2 = GP(start2, end2)
    var p3 = GP(start3, end3)

    var graph = p1 + p2 + p3

    graph()

    assert_true(p1.start[] < p1.end[])
    assert_true(p1.start[] < p2.end[])
    assert_true(p1.start[] < p3.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p1.end[])
    assert_true(p2.start[] < p2.end[])
    assert_true(p3.start[] < p2.end[])
    assert_true(p3.start[] < p3.end[])
    assert_true(p3.start[] < p3.end[])


@fieldwise_init
struct EImmutParallel(immutable.ImmutCallable):
    fn __call__(self):
        pass


fn test_immut_two_parallels() raises:
    comptime GP = EImmutParallel

    var p1 = GP()
    var p2 = GP()

    f = p1 + p2 >> p1 + p2
    f()


struct MutParallel(mutable.MutCallable):
    var start: UInt
    var end: UInt

    fn __init__(out self):
        self.start = 0
        self.end = 0

    fn __call__(mut self):
        self.start = monotonic()
        sleep(TIME)
        self.end = monotonic()


fn test_mut_parallel() raises:
    comptime GP = MutParallel

    var p1 = GP()
    var p2 = GP()
    var p3 = GP()

    var graph = p1 + p2 + p3

    graph()

    assert_true(p1.start < p1.end)
    assert_true(p1.start < p2.end)
    assert_true(p1.start < p3.end)
    assert_true(p2.start < p1.end)
    assert_true(p2.start < p1.end)
    assert_true(p2.start < p2.end)
    assert_true(p3.start < p2.end)
    assert_true(p3.start < p3.end)
    assert_true(p3.start < p3.end)


@fieldwise_init
struct EMutParallel(mutable.MutCallable):
    fn __call__(mut self):
        pass


fn test_mut_two_parallels() raises:
    comptime GP = EMutParallel

    var p1 = GP()
    var p2 = GP()
    var p3 = GP()
    var p4 = GP()

    f = p1 + p2 >> p3 + p4
    f()


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
