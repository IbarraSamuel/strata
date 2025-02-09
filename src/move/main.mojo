from task.model import Task
from time import sleep

# Tasks


@value
struct Initialize:
    fn run(self):
        print("Initializing Everything")
        sleep(UInt(1))


@value
struct Selection:
    fn run(self):
        print("Running My Selection Task.")
        sleep(UInt(1))


@value
struct Suppression1:
    fn run(self):
        print("S001")
        sleep(UInt(1))


@value
struct Suppression11:
    fn run(self):
        print("---- S011")
        sleep(UInt(1))


@value
struct Suppression12:
    fn run(self):
        print("---- S012")
        sleep(UInt(1))


@value
struct Suppression121:
    fn run(self):
        print("---- ---- S121")
        sleep(UInt(1))


@value
struct Suppression122:
    fn run(self):
        print("---- ---- S122")
        sleep(UInt(1))


@value
struct Suppression2:
    fn run(self):
        print("S002")
        sleep(UInt(1))


@value
struct Deliver:
    fn run(self):
        print("Deliver Everything")
        sleep(UInt(1))


fn main():
    # Run time values...
    init = Initialize()
    sel = Selection()
    s1 = Suppression1()
    s11 = Suppression11()
    s12 = Suppression12()
    s121 = Suppression121()
    s122 = Suppression122()
    s2 = Suppression2()
    d = Deliver()
    t = Task(init)

    graph = (
        Task(init)
        >> Task(sel)
        >> (
            (
                Task(s2) + Task(s1)
                >> (Task(s11) + (Task(s12) >> (Task(s121) + Task(s122))))
            )
        )
        >> Task(d)
    )

    # If the Runnable tasks are Defaultable, you can pass it as parameters!
    graph2 = (
        Task[Initialize]()
        >> Task[Selection]()
        >> Task[Suppression1]() + Task[Suppression2]()
        >> Task[Deliver]()
    )

    print("Running first graph...")
    graph.run()

    print("Running Second graph...")
    graph2.run()

    # runner.run()
