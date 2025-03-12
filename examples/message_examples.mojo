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


struct Init(ImmCallableWithMessage):
    var count: Int

    fn __init__(out self, count: Int):
        self.count = count

    fn __call__(self, owned msg: Message) -> Message:
        print("Running [Init]:", msg.__str__())

        msg["init"] = String(self.count)
        return msg


struct Par1(ImmCallableWithMessage):
    fn __init__(out self):
        pass

    fn __call__(self, owned msg: Message) -> Message:
        print("Running [par1]...", msg.__str__())
        init = msg.pop("init", "0")
        no = str_to_int(init)

        no += 1
        msg["calc1"] = String(no)
        return msg


@value
struct Par2(ImmCallableWithMessage):
    fn __init__(out self):
        pass

    fn __call__(self, owned msg: Message) -> Message:
        print("Running [par2]...", msg.__str__())
        init = msg.pop("init", "0")
        no = str_to_int(init)

        no *= 10
        msg["calc2"] = String(no)
        return msg


struct Final(ImmCallableWithMessage):
    fn __init__(out self):
        pass

    fn __call__(self, owned msg: Message) -> Message:
        print("Running [Final]", msg.__str__())
        calc1 = str_to_int(msg.pop("calc1", "0"))
        calc2 = str_to_int(msg.pop("calc2", "0"))
        final = calc1 * calc2 + calc2

        msg["final"] = String(final)
        print("Finalized with Message:", msg.__str__())
        return msg


fn main() raises:
    print("\n\nHey! Running Message Examples...")
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

    # Functions

    fn first_task(owned msg: Message) -> Message:
        print("Running [First Task]:", msg.__str__())
        msg["init"] = String(12)
        return msg

    fn last_task(owned msg: Message) -> Message:
        print("Running [Last Task]...")
        cal1 = str_to_int(msg.pop("calc1", "0"))
        cal2 = str_to_int(msg.pop("calc2", "0"))
        f = cal1 * cal2 + cal2
        msg["final"] = String(f)
        print("Finalized with Message:", msg.__str__())
        return msg

    fn parallel1(owned msg: Message) -> Message:
        i = msg.pop("init", "0")
        no = str_to_int(i)
        no += 1
        msg["calc1"] = String(no)
        return msg

    fn parallel2(owned msg: Message) -> Message:
        i = msg.pop("init", "0")
        no = str_to_int(i)
        no *= 10
        msg["calc2"] = String(no)
        return msg

    from move.task.immutable import MsgFnTask as Fn

    ft = Fn(first_task)
    p1 = Fn(parallel1)
    p2 = Fn(parallel2)
    lt = Fn(last_task)
    print("[ Function Graph ]...")
    fn_graph = T(ft) >> T(p1) + p2 >> lt

    initial_msg = Message()
    res = fn_graph(initial_msg)
    val = str_to_int(res["final"])
    print("Functional last value is:", val)
