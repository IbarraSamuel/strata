from strata.void import async_immutable, async_mutable
from testing import TestSuite, assert_equal
from time import sleep

comptime TIME = 0.1


@fieldwise_init
struct Task(async_immutable.AsyncCallable):
    async fn __call__(self):
        sleep(TIME)
        # print("hello")


@fieldwise_init
struct Task2(async_immutable.AsyncCallable):
    async fn __call__(self):
        sleep(TIME)
        # print("world")


fn test_immutable() raises:
    var graph = (
        Task()
        >> Task()
        >> Task()
        >> Task2() + Task2() + Task2()
        >> Task()
        >> Task()
    )
    graph.run()


# @fieldwise_init("implicit")
# struct MTask(async_mutable.AsyncCallable):
#     var a: Int

#     async fn __call__(mut self):
#         self.a += 1
#         # sleep(TIME)
#         print("hello")


# @fieldwise_init("implicit")
# struct MTask2(async_mutable.AsyncCallable):
#     var a: Int

#     async fn __call__(mut self):
#         self.a += 1
#         # sleep(TIME)
#         print("world")


# fn get_tref(var v: async_mutable.TaskRef):
#     pass


# fn test_mutable() raises:
#     var a = MTask(0)
#     var b = MTask(0)
#     var c = MTask(0)
#     var d = MTask(0)
#     var e = MTask2(0)
#     var f = MTask2(0)
#     var g = MTask2(0)
#     var h = MTask2(0)
#     var i = MTask2(0)

#     var graph = a >> b >> c >> d + e + f >> g + h >> i
#     graph.run()

#     assert_equal(a.a, 1)
#     assert_equal(b.a, 1)
#     assert_equal(c.a, 1)
#     assert_equal(d.a, 1)
#     assert_equal(e.a, 1)
#     assert_equal(f.a, 1)
#     assert_equal(g.a, 1)
#     assert_equal(h.a, 1)
#     assert_equal(i.a, 1)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
