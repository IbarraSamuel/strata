from dataclasses import dataclass
from operator import add
from time import sleep, time_ns
from typing import cast

import pytest

from move import Combinable, ParallelTask, SerialTask, Task


@dataclass
class MyTask:
    value: int = 0

    def __call__(self, message: int) -> int:
        self.value += message
        return self.value


def test_task():
    my_task = MyTask()
    motask = Task(my_task)

    value = 1
    result = motask(value)
    result = motask(result)
    assert my_task.value == value * 2


@dataclass
class AddOneTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> int:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return message + 1


@dataclass
class IntToStrTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: int) -> str:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return str(message)


@dataclass
class StrToIntTask(Combinable):
    start: int = 0
    end: int = 0

    def __call__(self, message: str) -> int:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return int(message)


@dataclass
class SumTuple(Combinable):
    start: int = 0
    end: int = 0

    def __call__[T](self, message: tuple[T, T]) -> T:
        self.start = time_ns()
        sleep(1.0)
        self.end = time_ns()
        return cast("T", add(message[0], message[1]))


def test_serial_task():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    serial_task = SerialTask(my_task_1, my_task_2)

    print("[Serial Task]...")

    message = 5
    out = serial_task(message)

    print("[End of Task]...")

    assert out == "7", "tasks should add 1 to each input"
    assert my_task_1.end < my_task_2.start, "task1 should finish before task2 starts"


def test_serial_task_combination():
    str_to_int = StrToIntTask()
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    int_to_str = IntToStrTask()
    serial_task = str_to_int >> my_task_1 >> my_task_2 >> int_to_str

    print("[Serial Task]...")

    message = "5"
    out = serial_task(message)

    print("[End of Task]...")

    assert out == str(int(message) + 2), "tasks should add 1 to each input"
    assert my_task_1.end < my_task_2.start, "task1 should finish before task2 starts"


@pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_parallel_task():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    serial_task = ParallelTask(my_task_1, my_task_2)

    print("[Serial Task]...")

    message = 5
    out = serial_task(message)

    print("[End of Task]...")

    assert out == (message + 1, message + 1), "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 starts before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 starts before t2 finishes"


@pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_parallel_task_combination():
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    serial_task = my_task_1 + my_task_2

    print("[Serial Task]...")

    message = 5
    out = serial_task(message)

    print("[End of Task]...")

    assert out == (message + 1, message + 1), "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 starts before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 starts before t2 finishes"


@pytest.mark.skip("Causes sigfoult when trying to run in parallel.")
def test_mixed_task_combination():
    str_to_int = StrToIntTask()
    my_task_1 = AddOneTask()
    my_task_2 = AddOneTask()
    sum_tuple = SumTuple()
    int_to_str = IntToStrTask()

    serial_task = str_to_int >> my_task_1 + my_task_2 >> sum_tuple >> int_to_str
    print("[Serial Task]...")

    message = "5"
    out = serial_task(message)

    print("[End of Task]...")

    assert out == "12", "tasks should add 1 to each input"
    assert my_task_1.end > my_task_2.start, "t2 starts before t1 finishes"
    assert my_task_2.end > my_task_1.start, "t1 starts before t2 finishes"
