from builtin.coroutine import Coroutine
from collections.optional import OptionalReg
from algorithm.functional import parallelize, sync_parallelize


trait Runnable:
    fn run(self):
        ...


trait IsTask(Runnable, CollectionElement):
    pass


fn run[T: IsTask](**task_collection: List[T]):
    for task_group in task_collection.items():
        print("Running the tasks under ", task_group[].key)
        var tasks = task_group[].value

        @parameter
        fn run_task(n: Int) capturing:
            print("Running Task no. ", n, "...")
            tasks[n].run()

        sync_parallelize[run_task](len(tasks))
        print("Task for", task_group[].key, "completed successfully!")


# fn run(**task_collection: List[Pointer[IsTask]]):
#     for task_group in task_collection.items():
#         print("Running the tasks under ", task_group[].key)
#         var tasks = task_group[].value

#         @parameter
#         fn run_task(n: Int) capturing:
#             print("Running Task no. ", n, "...")
#             var task = tasks[n]
#             task[].run()

#         sync_parallelize[run_task](len(tasks))
#         print("Task for", task_group[].key, "completed successfully!")
