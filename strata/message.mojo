from algorithm import sync_parallelize
from collections import Dict

alias Message = Dict[String, String]
"""A message to be readed and produced by tasks."""

alias CallableMsgPack = VariadicPack[False, _, CallableWithMessage, *_]


trait CallableWithMessage:
    """A `ImmCallable` with a Message to pass to the next task.

    ```mojo
    from strata.message import Message

    trait CallableWithMessage:
        fn __call__(mut self, owned msg: Message) -> Message:
            ...

    struct MyStruct(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            nm = msg.get("name", "Bob")
            msg["greet"] = String("Hello, ", nm, "!")
            return msg

    tsk = MyStruct()

    # Calling the instance.
    msg = Message()
    msg["name"] = "Samuel"
    res = tsk(msg)
    print(res["greet"])

    ```
    """

    # TODO: Consider using raises since manipulating Messages to cast string to something else is a little bit difficult with no raises
    fn __call__(self, owned msg: Message) -> Message:
        """Run a task using a `Message` (Alias for `Dict[String, String]` for now).
        You should return a message back.

        Args:
            msg: The information to be readed.

        Returns:
            The result of running this task.
        """
        ...


fn parallel_msg_runner[
    *C: CallableWithMessage
](owned msg: Message, *callables: *C) -> Message:
    """Run Runnable structs in parallel.
    In parallel, messages could not be modified.

    Parameters:
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A collection of `ImmCallable` types.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from strata.message import Message, parallel_msg_runner, CallableWithMessage
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](CallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()
            return msg

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = parallel_msg_runner(msg, t1, t2)

    # TODO: Add assertions on message.
    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```

    Syncs automatically.
    """
    return parallel_msg_runner(msg, callables)


fn parallel_msg_runner[
    o: Origin, *C: CallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    """Run Runnable structs in parallel.
    In parallel, messages could not be modified.

    Parameters:
        o: Origin of the CallableMsgPack.
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A CallableMsgPack.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from strata.message import Message, parallel_msg_runner, CallableWithMessage, CallableMsgPack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](CallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(1.0) # Less times didn't work well on doctests
            self.finish[] = perf_counter_ns()
            return msg

    fn fromvpack[*ts: CallableWithMessage](msg: Message, *args: *ts) -> Message:
        return parallel_msg_runner(msg, args)

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = fromvpack(msg, t1, t2)

    # TODO: Add assertions on message.
    assert_true(t2_starts < t1_finish and t1_starts < t2_finish)
    ```

    Syncs automatically.
    """
    alias size = len(VariadicList(C))
    inp = msg.copy()

    @parameter
    fn append_msg(i: Int):
        @parameter
        for ti in range(size):
            if ti == i:
                new_msg = callables[ti](inp)
                msg.update(new_msg)

    sync_parallelize[append_msg](size)
    return msg


fn series_msg_runner[
    *C: CallableWithMessage
](owned msg: Message, *callables: *C) -> Message:
    """Run Runnable structs in series.
    In series, messages could be modified.

    Parameters:
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A collection of `ImmCallable` types.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from strata.message import Message, series_msg_runner, CallableWithMessage
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](CallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and then t2
    msg = Message()
    msg_out = series_msg_runner(msg, t1, t2)
    # TODO: Add assertions on message.
    assert_true(t1_finish < t2_starts)
    ```

    Syncs automatically.
    """
    return series_msg_runner(msg, callables)


fn series_msg_runner[
    o: Origin, *C: CallableWithMessage
](owned msg: Message, callables: CallableMsgPack[o, *C]) -> Message:
    """Run Runnable structs in series.
    In series, messages could be modified.

    Parameters:
        o: Origin of the CallableMsgPack.
        C: Variadic `ImmCallableWithMessage` types.

    Args:
        msg: The message to read.
        callables: A CallableMsgPack.

    Returns:
        Message: The message to be sent back from the task.
    ```mojo
    from strata.message import Message, series_msg_runner, CallableWithMessage, CallableMsgPack
    from time import perf_counter_ns, sleep
    from memory import Pointer
    from testing import assert_true

    t1_starts = UInt(0)
    t1_finish = UInt(0)
    t2_starts = UInt(0)
    t2_finish = UInt(0)

    struct Task[o1: Origin[True], o2: Origin[True]](CallableWithMessage):
        var start: Pointer[UInt, o1]
        var finish: Pointer[UInt, o2]
        fn __init__(out self, ref[o1] start: UInt, ref[o2] finish: UInt):
            self.start = Pointer(to=start)
            self.finish = Pointer(to=finish)
        fn __call__(self, owned msg: Message) -> Message:
            self.start[] = perf_counter_ns()
            sleep(0.1)
            self.finish[] = perf_counter_ns()
            return msg

    fn fromvpack[*ts: CallableWithMessage](msg: Message, *args: *ts) -> Message:
        return series_msg_runner(msg, args)

    t1 = Task(t1_starts, t1_finish)
    t2 = Task(t2_starts, t2_finish)

    # Will run t1 and t2 at the same time
    msg = Message()
    msg_out = fromvpack(msg, t1, t2)

    assert_true(t1_finish < t2_starts)
    # TODO: Add assertions on message.
    ```

    Syncs automatically.
    """
    alias size = len(VariadicList(C))

    @parameter
    for i in range(size):
        msg = callables[i](msg^)

    return msg


@fieldwise_init("implicit")
struct MsgFnTask(CallableWithMessage):
    """This function takes any function with a signature: `fn(owned Message) -> Message`
    and hold it to later call it using `__call__()`.

    ```mojo
    from strata.message import MsgFnTask
    from strata.message import Message
    from testing import assert_true

    fn modify_message(owned msg: Message) -> Message:
        name = msg.get("name", "Sam")
        msg["greet"] = String("Hello, ", name)
        return msg

    msg = Message()
    msg["name"] = "Elio"
    task = MsgFnTask(modify_message)
    out_msg = task(msg)
    assert_true(out_msg.get("greet", "none"), "Hello, Elio")
    ```
    """

    var func: fn (owned Message) -> Message
    """Pointer to the function to call."""

    fn __call__(self, owned msg: Message) -> Message:
        """Call the inner function.

        Args:
            msg: The message to read.

        Returns:
            Message: The result of the task execution.
        """
        return self.func(msg^)

    fn __add__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return {self, other}

    fn __rshift__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return {self, other}


struct ImmMessageTask[origin: Origin, T: CallableWithMessage](
    CallableWithMessage
):
    """Refers to a task that cannot be mutated and receives a `Message` as argument,
    to give back a `Message` as output.

    Parameters:
        mut: Wether if the task is mutable or not.
        origin: The source of the task.
        T: It's a task that conforms to `ImmCallableWithMessage`.

    ```mojo
    from strata.message import ImmMessageTask, MsgFnTask
    from strata.message import Message
    from testing import assert_true

    fn message_task(owned msg: Message) -> Message:
        name = msg.get("name", "Sam")
        print("reading message: ", name)
        msg["greet"] = String("Hello, ", name)
        return msg

    msg = Message()
    msg["name"] = "Bob"
    fntask = MsgFnTask(message_task)
    task = ImmMessageTask(fntask)
    out_msg = task(msg)
    assert_true(out_msg["greet"], "Hello, Bob")
    ```
    """

    var inner: Pointer[T, origin]
    """Pointer to the Task."""

    @implicit
    fn __init__(out self, ref [origin]inner: T):
        """Create a wrapper to a ImmMessageTask using a pointer.

        Args:
            inner: The ImmMessageTask to be wrapped.
        """
        self.inner = Pointer(to=inner)

    fn __call__(self, owned msg: Message) -> Message:
        """Call the inner function.

        Args:
            msg: The message to read.

        Returns:
            Message: The result of the task execution.
        """
        return self.inner[](msg^)

    fn __add__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return {self, other}

    fn __rshift__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return {self, other}


# Parallel Pair
struct ImmParallelMsgTaskPair[
    m1: Bool,
    m2: Bool, //,
    o1: Origin[m1],
    o2: Origin[m2],
    t1: CallableWithMessage,
    t2: CallableWithMessage,
](CallableWithMessage):
    """A pair of Message Immutable Tasks.

    Parameters:
        m1: Wether if the origin is mutable.
        m2: Wether if the origin is mutable.
        o1: Origin for the first type.
        o2: Origin for the second type.
        t1: First type that conforms to `ImmCallableWithMessage`.
        t2: Second type that conforms to `ImmCallableWithMessage`.

    ```mojo
    from strata.message import ImmParallelMsgTaskPair
    from strata.message import Message, CallableWithMessage

    struct MsgTask(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Do something with the message")
            return msg

    t1 = MsgTask()
    t2 = MsgTask()
    stp = ImmParallelMsgTaskPair(t1, t2)

    # Run the pair
    msg = Message()
    msg_out = stp(msg)
    print(msg_out.__str__())
    ```
    """

    var v1: Pointer[t1, o1]
    """First msg task."""
    var v2: Pointer[t2, o2]
    """Second msg task."""

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        """Start a Msg Task pair using two reference to messages.

        Args:
            v1: First message task.
            v2: Second message task.
        """
        self.v1 = Pointer(to=v1)
        self.v2 = Pointer(to=v2)

    fn __call__(self, owned message: Message) -> Message:
        """Call both message tasks in parallel.

        Args:
            message: The message or context to read.

        Returns:
            The message output from this task or job.
        """
        return parallel_msg_runner(message, self.v1[], self.v2[])

    fn __add__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return {self, other}

    fn __rshift__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return {self, other}


# Series Pair
struct ImmSeriesMsgTaskPair[
    m1: Bool,
    m2: Bool, //,
    o1: Origin[m1],
    o2: Origin[m2],
    t1: CallableWithMessage,
    t2: CallableWithMessage,
](CallableWithMessage):
    """A pair of Message Immutalbe Tasks.

    Parameters:
        m1: Wether if the origin is mutable.
        m2: Wether if the origin is mutable.
        o1: Origin for the first type.
        o2: Origin for the second type.
        t1: First type that conforms to `ImmCallableWithMessage`.
        t2: Second type that conforms to `ImmCallableWithMessage`.

    ```mojo
    from strata.message import Message, ImmSeriesMsgTaskPair, CallableWithMessage

    struct MsgTask(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Do something with the message")
            return msg

    t1 = MsgTask()
    t2 = MsgTask()
    stp = ImmSeriesMsgTaskPair(t1, t2)

    # Run the pair
    msg = Message()
    msg_out = stp(msg)
    print(msg_out.__str__())
    ```
    """

    var v1: Pointer[t1, o1]
    """First msg task."""
    var v2: Pointer[t2, o2]
    """Second msg task."""

    fn __init__(out self, ref [o1]v1: t1, ref [o2]v2: t2):
        """Start a Msg Task pair using two reference to messages.

        Args:
            v1: First message task.
            v2: Second message task.
        """
        self.v1 = Pointer(to=v1)
        self.v2 = Pointer(to=v2)

    fn __call__(self, owned message: Message) -> Message:
        """Call both message tasks in sequence.

        Args:
            message: The message or context to read.

        Returns:
            The message output from this task or job.
        """
        return series_msg_runner(message, self.v1[], self.v2[])

    fn __add__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmParallelMsgTaskPair[s, o, Self, t]:
        """Add this task pair with another task, to be executed in parallel.
        This task will keep the internal order, but meanwhile the current one is running,
        the other one could run too.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed at the same time than this group.

        Returns:
            A pair of references to self, and other task, to be ran on parallel.
        """
        return {self, other}

    fn __rshift__[
        s: Origin, o: Origin, t: CallableWithMessage, //
    ](ref [s]self, ref [o]other: t) -> ImmSeriesMsgTaskPair[s, o, Self, t]:
        """Add another task to be executed after these two.
        It's like appending another task to a list of ordered tasks.

        Parameters:
            s: Origin of self.
            o: Origin of the other type.
            t: Type that conforms to `ImmCallableWithMessage`.

        Args:
            other: The task to be executed after this pair.

        Returns:
            A pair of references to self, and other task, to be ran on sequence.
        """
        return {self, other}


# Variadic Parallel
struct ImmParallelMsgTask[origin: Origin, *Ts: CallableWithMessage](
    CallableWithMessage
):
    """Immutable tasks that will use a message in, message out.

    Parameters:
        mut: Wether if the origin of `VariadicPack` is mutable or not.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallableWithMessage types that conforms to `ImmCallableWithMessage`.

    ```mojo
    from strata.message import ImmParallelMsgTask
    from strata.message import Message, CallableWithMessage

    struct MsgTask(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Reading message keys...")
            for k in msg.keys():
                print(k)

            return msg

    m1 = MsgTask()
    m2 = MsgTask()

    parallel = ImmParallelMsgTask(m1, m2)

    # this will run both message tasks in parallel.
    msg = Message()
    msg_out = parallel(msg)
    print(msg_out.__str__())
    ```
    """

    var callables: CallableMsgPack[origin, *Ts]
    """The underlying storage for message pointers."""

    fn __init__(out self: ImmParallelMsgTask[args.origin, *Ts], *args: *Ts):
        """Create a group of msg tasks.

        Args:
            args: The msg tasks to be included in the group.
        """
        self.callables = CallableMsgPack(args._value)

    fn __call__(self, owned msg: Message) -> Message:
        """This will run the underlying tasks using the message.
        The Message will be copied for each one.

        Args:
            msg: The message to read.

        Returns:
            The message modified.
        """
        return parallel_msg_runner(msg, self.callables)


# Variadic Parallel
struct ImmSeriesMsgTask[origin: Origin, *Ts: CallableWithMessage](
    CallableWithMessage
):
    """Immutable tasks that will use a message in, message out.

    Parameters:
        mut: Wether if the origin of `VariadicPack` is mutable or not.
        origin: The origin of the `VariadicPack` values.
        Ts: ImmutableCallableWithMessage types that conforms to `ImmCallableWithMessage`.

    ```mojo
    from strata.message import Message, ImmSeriesMsgTask, CallableWithMessage

    struct MsgTask(CallableWithMessage):
        fn __init__(out self):
            pass

        fn __call__(self, owned msg: Message) -> Message:
            print("Reading message keys...")
            for k in msg.keys():
                print(k)

            return msg

    m1 = MsgTask()
    m2 = MsgTask()

    series = ImmSeriesMsgTask(m1, m2)

    # this will run both message tasks in sequence.
    msg = Message()
    msg_out = series(msg)
    print(msg_out.__str__())
    ```
    """

    var callables: CallableMsgPack[origin, *Ts]
    """The underlying storage for message pointers."""

    fn __init__(out self: ImmSeriesMsgTask[args.origin, *Ts], *args: *Ts):
        """Create a group of msg tasks.

        Args:
            args: The msg tasks to be included in the group.
        """
        self.callables = CallableMsgPack(args._value)

    fn __call__(self, owned msg: Message) -> Message:
        """This will run the underlying tasks using the message,
        but the message could be modified in the execution of the sequence.

        Args:
            msg: The message to read.

        Returns:
            The message modified.
        """
        return series_msg_runner(msg, self.callables)
