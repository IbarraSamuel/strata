"""Tests for async mutable void task pipelines."""

from std.testing import TestSuite, assert_equal
from std.time import sleep

from strata.void import async_mutable

comptime TIME = 0.001


@fieldwise_init
struct MutAsyncCounter(async_mutable.AsyncCallable, Movable):
    var count: Int

    __async def __call__(mut self):
        sleep(TIME)
        self.count += 1


def test_async_mutable_ref_series() raises:
    var t1 = MutAsyncCounter(0)
    var t2 = MutAsyncCounter(10)

    var ser = t1 >> t2
    ser.run()

    assert_equal(t1.count, 1)
    assert_equal(t2.count, 11)


def test_async_mutable_ref_parallel() raises:
    var t1 = MutAsyncCounter(0)
    var t2 = MutAsyncCounter(10)

    var par = t1 + t2
    par.run()

    assert_equal(t1.count, 1)
    assert_equal(t2.count, 11)


def test_async_mutable_ref_and_var() raises:
    var t_ref = MutAsyncCounter(0)
    var t_var = MutAsyncCounter(20)

    # ref + var
    var par = t_ref + (t_var^)
    par.run()
    assert_equal(t_ref.count, 1)

    # ref >> var
    var t_var2 = MutAsyncCounter(30)
    var ser = t_ref >> (t_var2^)
    ser.run()
    assert_equal(t_ref.count, 2)


def test_async_mutable_movable() raises:
    var t_ref = MutAsyncCounter(0)
    var t_var = MutAsyncCounter(10)

    # First construct a SerTaskPair (which implements AsyncCallableMovable)
    var ser1 = t_ref >> (t_var^)

    # var >> ref (AsyncCallableMovable.__rshift__ with ref)
    var t_ref2 = MutAsyncCounter(50)
    var ser2 = (ser1^) >> t_ref2
    ser2.run()
    assert_equal(t_ref2.count, 51)

    # var >> var (AsyncCallableMovable.__rshift__ with var)
    var t_var3 = MutAsyncCounter(100)
    var ser3 = (ser2^) >> (t_var3^)
    ser3.run()

    # var + ref (AsyncCallableMovable.__add__ with ref)
    var t_ref3 = MutAsyncCounter(60)
    var par1 = (ser3^) + t_ref3
    par1.run()
    assert_equal(t_ref3.count, 61)

    # var + var (AsyncCallableMovable.__add__ with var)
    var t_var4 = MutAsyncCounter(200)
    var par2 = (par1^) + (t_var4^)
    par2.run()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
