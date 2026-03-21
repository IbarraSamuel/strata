from std.testing import TestSuite, assert_true, assert_equal
from std.time import monotonic, sleep

from strata import generic
from strata.generic import compt
from strata.void import immutable, mutable, type, async_immutable, async_mutable


comptime TIME = 0.001


# def sleep(time: Float64) -> None:
#     pass


struct GenericParallel(generic.Callable):
    comptime I = Int
    comptime O = NoneType

    var start: UnsafePointer[UInt, MutAnyOrigin]
    var end: UnsafePointer[UInt, MutAnyOrigin]

    def __init__(out self, mut s: UInt, mut e: UInt):
        self.start = UnsafePointer(to=s)
        self.end = UnsafePointer(to=e)

    def __call__(self, v: Int):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


def test_generic_parallel() raises:
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


def int_to_float(v: Int) -> Float32:
    return Float32(v)


def int_to_int(v: Int) -> Int:
    return v


def sum_tuple(v: Tuple[Float32, Int]) -> Int:
    return Int(v[0] + Float32(v[1]))


def test_generic_two_parallels() raises:
    var itof = generic.Fn(int_to_float)
    var itoi = generic.Fn(int_to_int)
    var stp = generic.Fn(sum_tuple)
    var graph = itof + itoi >> stp + stp

    var r1, r2 = graph(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


def string_to_int(str: String) -> Int:
    # print("string to int...")
    sleep(TIME)
    try:
        return Int(str)
    except:
        return 0


def int_to_float_g(value: Int) -> Float32:
    # print("int to float...")
    sleep(TIME)
    return Float32(value)


def int_mul[by: Int](value: Int) -> Int:
    # print("Mutliply by", by, "...")
    sleep(TIME)
    return value * by


def sum_tuple_g(value: Tuple[Int, Float32, Int]) -> Float32:
    # print("Sum tuple...")
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


def float_to_string(value: Float32) -> String:
    # print("float to string...")
    sleep(TIME)
    return String(value)


# Struct Versions
@fieldwise_init
struct StringToIntTask(generic.Callable):
    comptime I = String
    comptime O = Int

    def __call__(self, arg: Self.I) -> Self.O:
        # print("string to int...")
        sleep(TIME)
        try:
            return Int(arg)
        except:
            return 0


@fieldwise_init
struct IntToFloatTask(generic.Callable):
    comptime I = Int
    comptime O = Float32

    def __call__(self, arg: Int) -> Float32:
        # print("int to float...")
        sleep(TIME)
        return Float32(arg)


@fieldwise_init
struct IntMulTask[by: Int](generic.Callable):
    comptime I = Int
    comptime O = Int

    def __call__(self, arg: Self.I) -> Self.O:
        # print("Mutliply by", Self.by, "...")
        sleep(TIME)
        return arg * Self.by


@fieldwise_init
struct SumTuple(generic.Callable):
    comptime I = Tuple[Int, Float32, Int]
    comptime O = Float32

    def __call__(self, arg: Self.I) -> Self.O:
        # print("Sum tuple...")
        sleep(TIME)
        return Float32(arg[0]) + arg[1] + Float32(arg[2])


@fieldwise_init
struct FloatToStringTask(generic.Callable):
    comptime I = Float32
    comptime O = String

    def __call__(self, arg: Float32) -> String:
        # print("float to string...")
        sleep(TIME)
        return String(arg)


def test_generic_examples() raises:
    # NOTE: Compile times could be faster if you use struct instead of functions.
    # print("Building graph with functions...")
    comptime Fn = generic.Fn

    var stoi = Fn(string_to_int)
    var mul2 = Fn(int_mul[2])
    var mul3 = Fn(int_mul[3])
    var itof = Fn(int_to_float_g)
    var sum_tp = Fn(sum_tuple_g)
    var ftos = Fn(float_to_string)

    var final_graph = stoi >> mul2 + itof + mul3 >> sum_tp >> ftos

    # print("Starting Graph execution")
    var result = final_graph("32")
    # print("Meet expected?:", result, "vs 192.0:", result == "192.0")
    assert_equal(result, "192.0")

    # print("Building Struct graph")

    var struct_graph = (
        StringToIntTask()
        >> IntMulTask[2]() + IntToFloatTask() + IntMulTask[3]()
        >> SumTuple()
        >> FloatToStringTask()
    )

    # print("Starting Graph execution")
    var result_2 = struct_graph("32")
    # print("Meet expected?:", result_2, "vs 192.0:", result_2 == "192.0")
    assert_equal(result_2, "192.0")


def test_generic_comptime_parallel() raises:
    def comptime_parallel(v: NoneType) -> Tuple[UInt, UInt]:
        var start = monotonic()
        sleep(TIME)
        var end = monotonic()
        return start, end

    comptime _graph = (
        compt.F[comptime_parallel].par[comptime_parallel].par[comptime_parallel]
    )

    var p1, p2, p3 = _graph.run(None)

    assert_true(p1[0] < p1[1])
    assert_true(p1[0] < p2[1])
    assert_true(p1[0] < p3[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p1[1])
    assert_true(p2[0] < p2[1])
    assert_true(p3[0] < p2[1])
    assert_true(p3[0] < p3[1])
    assert_true(p3[0] < p3[1])


def test_generic_comptime_two_parallels() raises:
    comptime graph = compt.F[int_to_float].par[int_to_int].seq[
        compt.F[sum_tuple].par[sum_tuple].F
    ]

    var r1, r2 = graph.run(1)

    assert_equal(r1, 2)
    assert_equal(r2, 2)


def string_to_int_c(str: String) -> Int:
    # print("string to int...")
    sleep(TIME)
    try:
        return Int(str)
    except:
        return 0


def int_to_float_t(value: Int) -> Float32:
    # print("int to float...")
    sleep(TIME)
    return Float32(value)


def int_mul_c[by: Int](value: Int) -> Int:
    # print("Mutliply by", by, "...")
    sleep(TIME)
    return value * by


def sum_tuple3(value: Tuple[Int, Float32, Int]) -> Float32:
    # print("Sum tuple...")
    sleep(TIME)
    return Float32(value[0]) + value[1] + Float32(value[2])


# Struct example
struct FloatToString:
    @staticmethod
    def call(value: Float32) -> String:
        # print("Float to string...")
        sleep(TIME)
        return String(value)


async def async_itof(v: Int) -> Float32:
    return Float32(v)


async def async_ftoi(v: Float32) -> Int:
    return Int(v)


def test_generic_comptime_examples() raises:
    # print("Building graph")

    comptime Fn = compt.F
    comptime f1 = Fn[string_to_int]()
    comptime f21 = Fn[int_mul[2]]()
    comptime f22 = Fn[int_to_float]()
    comptime f23 = Fn[int_mul[3]]()
    comptime sumtp = Fn[sum_tuple_g]()
    comptime fts = Fn[FloatToString.call]()

    comptime final_g = (
        Fn[string_to_int]
        .seq[Fn[int_mul[2]].par[int_to_float].par[int_mul[3]].F]
        .seq[sum_tuple3]
        .seq[FloatToString.call]
    )
    # comptime parpp = f21 + f22
    # comptime pargp = parpp + f23
    # comptime runpar = f1 >> pargp
    # comptime cnct = runpar >> sumtp
    # comptime final_g = cnct >> fts

    var final_result_f = final_g.F("32")
    assert_equal(final_result_f, "192.0")
    # print("final result all comptimeed:", final_result_f)

    # comptime final_graph = (
    #     Fn[string_to_int]()
    #     >> Fn[int_mul[2]]() + Fn[int_to_float_t]() + Fn[int_mul[3]]()
    #     >> Fn[sum_tuple3]()
    #     >> Fn[FloatToString.call]()
    # )

    # print("Starting Graph execution")
    # var final_result = final_graph.F("32")
    # print(final_result)


def test_generic_comptime_explicit() raises:
    # print("Building graph")

    def stoi(v: String) -> Int:
        try:
            return Int(v)
        except:
            return 0

    def int_m[q: Int](v: Int) -> Int:
        return q * v

    def itof(v: Int) -> Float32:
        return Float32(v)

    def sumtp(v: Tuple[Int, Float32, Int]) -> Float32:
        return Float32(v[0]) + v[1] + Float32(v[2])

    def ftos(v: Float32) -> String:
        return String(v)

    comptime F = compt.F
    comptime explicit_graph = (
        F[stoi].seq[F[int_m[2]].par[itof].par[int_m[3]].F].seq[sumtp].seq[ftos]
    )

    # comptime f_compt_result = explicit_graph.comptime_run["32"]
    # comptime s_compt_result = explicit_graph.run("32")

    # var f_runt_result = explicit_graph.comptime_run["32"]
    var s_runt_result = explicit_graph.run("32")

    assert_equal(s_runt_result, "192.0")
    # assert_equal(f_compt_result, s_compt_result)
    # assert_equal(s_compt_result, f_runt_result)
    # assert_equal(f_runt_result, s_runt_result)

    # print("final result all comptimeed:", s_runt_result)


struct ImmutParallel(immutable.ImmutCallable):
    var start: UnsafePointer[UInt, MutAnyOrigin]
    var end: UnsafePointer[UInt, MutAnyOrigin]

    def __init__(out self, mut s: UInt, mut e: UInt):
        self.start = UnsafePointer(to=s)
        self.end = UnsafePointer(to=e)

    def __call__(self):
        self.start[] = monotonic()
        sleep(TIME)
        self.end[] = monotonic()


def test_immut_parallel() raises:
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
    def __call__(self):
        pass


def test_immut_two_parallels() raises:
    comptime GP = EImmutParallel

    var p1 = GP()
    var p2 = GP()

    f = p1 + p2 >> p1 + p2
    f()


@fieldwise_init
struct MyTask[job: StringLiteral](immutable.ImmutCallable):
    var some_data: String

    def __call__(self):
        # print("Running [", Self.job, "]:", self.some_data)
        sleep(TIME)


def test_immut_examples() raises:
    # print("\n\nHey! Running Immutable Examples...")
    comptime IS = immutable.SequentialTask
    comptime IP = immutable.ParallelTask

    init = MyTask["Initialize"]("Setting up...")
    load = MyTask["Load Data"]("Reading from some place...")
    find_min = MyTask["Min"]("Calculating...")
    find_max = MyTask["Max"]("Calculating...")
    find_mean = MyTask["Mean"]("Calculating...")
    find_median = MyTask["Median"]("Calculating...")
    merge_results = MyTask["Merge Results"]("Getting all together...")

    # Using Type syntax
    graph_1 = IS(
        init,
        load,
        IP(find_min, find_max, find_mean, find_median),
        merge_results,
    )
    # print("[GRAPH 1]...")
    graph_1()

    # Airflow Syntax

    graph_2 = (
        init
        >> load
        >> find_min + find_max + find_mean + find_median
        >> merge_results
    )
    # print("[GRAPH 2]...")
    graph_2()

    # What about functions? Yes, those can be considered as ImmTasks.
    # But, you need to wrap those function into a FnTask type.
    # No arguments or captures are allowed, no returns. So it's not so useful.

    def first_task():
        # print("Initialize everything...")
        sleep(TIME)

    def last_task():
        # print("Finalize everything...")
        sleep(TIME)

    def parallel_some():
        # print("Parallel some...")
        sleep(TIME)

    def parallel2():
        # print("Parallel 2...")
        sleep(TIME)

    # NOTE: You need to do it here, because we need to have an Origin to be able to
    # use a reference to this functions. We can do it also by passing ownership, but I
    # don't want to do it right now. It will require to duplicate a lot of functions and
    # structs. But this is how I did for Mutable ones.

    comptime Fn = immutable.Fn

    ft = Fn(first_task)
    ps = Fn(parallel_some)
    p2 = Fn(parallel2)
    lt = Fn(last_task)
    # print("[ Function Graph ]...")
    fn_graph = ft >> ps + p2 + ps >> lt
    fn_graph()

    # Hey, but these things are not useful, because you cannot mutate anything.
    # That's not true, but if you really need that, see mutable_examples.mojo


struct MutParallel(mutable.MutCallable):
    var start: UInt
    var end: UInt

    def __init__(out self):
        self.start = 0
        self.end = 0

    def __call__(mut self):
        self.start = monotonic()
        sleep(TIME)
        self.end = monotonic()


def test_mut_parallel() raises:
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
    def __call__(mut self):
        pass


def test_mut_two_parallels() raises:
    comptime GP = EMutParallel

    var p1 = GP()
    var p2 = GP()
    var p3 = GP()
    var p4 = GP()

    f = p1 + p2 >> p3 + p4
    f()


@fieldwise_init
struct InitTask[name: String = "Init"](mutable.MutCallable):
    var value: Int

    def __call__(mut self):
        # print("Starting [", Self.name, "Task]: Value is", self.value, "...")
        self.value += 1
        sleep(TIME)
        # print("Finishing [", Self.name, "Task]: The value is:", self.value)


def test_mut_examples() raises:
    # print("\n\nHey! Running Mutable Examples (No cross Reference)...")
    # Type syntax. Not so flexible because we cannot mix var / mut refs in Variadic Inputs.
    # * Some need to be owned because those groups will not have origin.
    # * Some need to be mutrefs because we want to point to the original struct without using a wrapper to then transfer the wrapper.
    # It needs to be one or the other.
    # To solve it, we can:
    # * Declare a groups of Mut Ref structs into a variable.
    # * Refer to this variable using Mut Ref again.

    # Other way is making the groups to own the values but this will make things difficult when you need to keep track of the changes on the structs.
    # from move import ParallelTask as P, SeriesTask as S
    # group1 = S(group1_1, group1_2)
    # group2 = S(group2_1, group2_2)
    # groups = P(group1, group2)
    # mutable_type_graph = S(initial, groups, final)

    # BUG: This is currently not working. Maybe it's because of a lot of castings and magic.
    # I'm storing a VariadicPack inside each group, the VariadicPack should be mutable but not owned and we should be able to transfer it.

    # mutable_type_graph()

    comptime ST = mutable.SeriesTask
    comptime PT = mutable.ParallelTask

    task1 = InitTask["first"](0)
    task2 = InitTask["second"](0)
    task31 = InitTask["third parallel 1"](1)
    task32 = InitTask["third parallel 2"](1)
    task33 = InitTask["third parallel 2"](1)
    task34 = InitTask["third parallel 2"](1)
    task4 = InitTask["pre-last"](2)
    task5 = InitTask["last"](2)

    # print("Type graph...")
    grp = PT(task31, task32, task33, task34)
    type_graph = ST(task1, task2, grp, task4, task5)
    type_graph()

    # Airflow Syntax. We solve all these problems.
    # You can just wrap the initial struct with a MutableTask and do operations.

    # For tasks with independent values:

    # print("Airflow graph...")
    graph = (
        task1 >> task2 >> task31 + task32 + task33 + task34 >> task4 >> task5
    )
    graph()

    # NOTE: This will not work if you want to do cross references to other tasks in the graph.
    # If you have this usecase, go to unsafe examples.


@fieldwise_init
struct MyTypeTask[name: StringLiteral](
    type.TypeCallable, TrivialRegisterPassable
):
    @staticmethod
    def __call__():
        # print("Task [", Self.name, "] Running...")
        sleep(TIME)


def test_type_examples() raises:
    comptime SD = type.SeriesTypeTask
    comptime PD = type.ParallelTypeTask

    comptime Initialize = MyTypeTask["Initialize"]
    comptime LoadData = MyTypeTask["LoadData"]
    comptime FindMin = MyTypeTask["FindMin"]
    comptime FindMax = MyTypeTask["FindMax"]
    comptime FindMean = MyTypeTask["FindMean"]
    comptime FindMedian = MyTypeTask["FindMedian"]
    comptime MergeResults = MyTypeTask["MergeResults"]

    comptime TypesGraph = SD[
        Initialize,
        LoadData,
        PD[FindMin, FindMax, FindMean, FindMedian],
        MergeResults,
    ]
    # print("[Types Graph 1]...")
    TypesGraph.__call__()

    # # Airflow Syntax.

    comptime airflow_graph = (
        Initialize()
        >> LoadData()
        >> FindMin() + FindMax() + FindMean() + FindMedian()
        >> MergeResults()
    )
    # print("[Airflow Graph]...")
    airflow_graph.__call__()


@fieldwise_init
struct ATask(async_immutable.AsyncCallable):
    async def __call__(self):
        sleep(TIME)
        # print("hello")


@fieldwise_init
struct ATask2(async_immutable.AsyncCallable):
    async def __call__(self):
        sleep(TIME)
        # print("world")


def test_immutable() raises:
    var graph = (
        ATask()
        >> ATask()
        >> ATask()
        >> ATask2() + ATask2() + ATask2()
        >> ATask()
        >> ATask()
    )
    graph.run()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
