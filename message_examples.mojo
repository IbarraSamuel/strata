from time import sleep
from move.message import Message
from move.callable import ImmCallableWithMessage


fn str_to_int(str: String) -> Int:
    """This is unsafe."""
    alias ord0 = ord("0")
    debug_assert(str.isdigit())
    size = len(str)

    v = 0
    for i in range(size):
        v += (10 ** (size - i - 1)) * (ord(str[i]) - ord0)

    return Int(v)


@value
struct Init(ImmCallableWithMessage):
    var count: Int

    fn __call__(self, owned msg: Message) -> Message:
        print("Running [Init]:", msg.__str__())

        msg["init"] = String(self.count)
        return msg


@value
struct Par1(ImmCallableWithMessage):
    fn __call__(self, owned msg: Message) -> Message:
        print("Running [par1]...", msg.__str__())
        init = msg.pop("init", "0")
        no = str_to_int(init)

        no += 1
        msg["calc1"] = String(no)
        return msg


@value
struct Par2(ImmCallableWithMessage):
    fn __call__(self, owned msg: Message) -> Message:
        print("Running [par2]...", msg.__str__())
        init = msg.pop("init", "0")
        no = str_to_int(init)

        no *= 10
        msg["calc2"] = String(no)
        return msg


@value
struct Final(ImmCallableWithMessage):
    fn __call__(self, owned msg: Message) -> Message:
        print("Running [Final]", msg.__str__())
        calc1 = str_to_int(msg.pop("calc1", "0"))
        calc2 = str_to_int(msg.pop("calc2", "0"))
        final = calc1 * calc2 + calc2

        msg["final"] = String(final)
        print("Finalized with Message:", msg.__str__())
        return msg


fn main() raises:
    print("Hey! Running Message Examples...")
    from move.task_groups.series.immutable import ImmSeriesMsgTask as S
    from move.task_groups.parallel.immutable import ImmParallelMsgTask as P

    init = Init(12)
    calc1 = Par1()
    calc2 = Par2()
    final = Final()

    graph = S(init, P(calc1, calc2), final)

    msg = Message()
    result_msg = graph(msg)
    value = str_to_int(result_msg["final"])
    print("final value is:", value)

    # Airflow Syntax
    from move.task.immutable import ImmMessageTask as T

    graph_2 = T(init) >> T(calc1) + calc2 >> final
    print("[GRAPH 2]...")
    result_msg = graph_2(msg)
    value = str_to_int(result_msg["final"])
    print("final value is:", value)

    # Functions (NOT YET)

    # fn first_task(msg: Message) -> Message:
    #     print("Initialize everything...")
    #     sleep(0.5)

    # fn last_task(msg: Message) -> Message:
    #     print("Finalize everything...")
    #     sleep(0.5)

    # fn parallel1(msg: Message) -> Message:
    #     print("Parallel 1...")
    #     sleep(0.5)

    # fn parallel2(msg: Message) -> Message:
    #     print("Parallel 2...")
    #     sleep(0.5)

    # from move.task.immutable import FnTask as Fn

    # ft = Fn(first_task)
    # p1 = Fn(parallel1)
    # p2 = Fn(parallel2)
    # lt = Fn(last_task)
    # print("[ Function Graph ]...")
    # fn_graph = IT(ft) >> IT(p1) + p2 >> lt
    # fn_graph()
