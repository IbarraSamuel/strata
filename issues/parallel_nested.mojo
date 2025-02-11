from algorithm import parallelize
from time import sleep


fn deeper():
    @parameter
    fn deep(i: Int):
        print("On deeper level, i", i)
        sleep(UInt(1))

    parallelize[deep](3)


fn run_para():
    @parameter
    fn print_something(i: Int):
        print("on level zero, i", i)
        deeper()
        sleep(UInt(1))

    parallelize[print_something](3)


fn main():
    run_para()
