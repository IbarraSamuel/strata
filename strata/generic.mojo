from memory.pointer import Pointer
from sys.intrinsics import _type_is_eq
from algorithm import sync_parallelize
import os
from memory import UnsafePointer
from utils._visualizers import lldb_formatter_wrapping_type

alias TaskValue = Movable & Copyable & Defaultable
alias InType = TaskValue
alias OutType = TaskValue
"""
Both sould conform to the same trait since an output from a Task could be an input for the next task. 

* Needs to be Defaultable because on parallel, needs to be initialized before calling it. `var ..: type` is not enought
* Needs to be Copyable because I cannot rebind it in the output type if it's not copyable.
    I tried using refs, but then each one needs to return an ImmutableAnyOrigin, since those values are produced within the __call__ method.
    Then, we cannot use register_passable types, because they doesn't have origin. The API will be restricted to not register_passable types,
    and then things like SIMD cannot be used. Better just use Copyable things meanwhile the rebind doesn't work or we wait for requires or parametrized traits.
This tradeoff could be eliminated if I don't ensure type safety on the graph, but I want to ensure safety :).
"""


trait Callable:
    alias I: InType
    alias O: OutType

    fn __call__(self, arg: I) -> O:
        ...


# struct ATask[
#     T: Callable, origin: ImmutableOrigin, In: InType = T.I, Out: OutType = T.O
# ]:
#     var inner: Pointer[T, origin]

#     fn __init__(out self, ref [origin]inner: T):
#         self.inner = Pointer[T, origin](to=inner)


struct Task[
    T: Callable,
    origin: ImmutableOrigin,
    In: InType = T.I,
    Out: OutType = T.O,
](Callable, Movable):
    alias I = In
    alias O = Out
    var inner: Pointer[T, origin]

    fn __init__(out self, ref [origin]inner: T):
        """The only possible way to create a Task is to create it from a Callable.

        The callable will provide the values for In and Out parameters.
        We can trust that those parameters reflect the type of the callable.
        This is kind of parametrizing an trait?
        """
        self.inner = Pointer[T, origin](to=inner)

    fn __call__(self, arg: Self.I) -> Self.O:
        # SAFETY: This is safe because Self.I and T.I are the same type
        # and Self.O and T.O are the same type
        # Why? Because the only way to construct this struct is by using a reference to a Callable, which will define In and Out types automatically

        # TODO: Why we can't rebind something if there is no origin for it?
        return rebind[Self.O](self.inner[](rebind[T.I](arg)))

    fn __rshift__[
        t: Callable, o: ImmutableOrigin
    ](owned self: Task[T, origin, Out = t.I], ref [o]other: t) -> Task[
        SerTask[T, t, origin, o], ImmutableAnyOrigin
    ]:
        return {SerTask(self^, Task(other))}

    fn __add__[
        t: Callable, o: ImmutableOrigin
    ](owned self: Task[T, origin, In = t.I], ref [o]other: t) -> Task[
        ParTask[T, t, origin, o], ImmutableAnyOrigin
    ]:
        return {ParTask(self^, Task(other))}


@fieldwise_init
struct SerTask[
    C1: Callable, C2: Callable, o1: ImmutableOrigin, o2: ImmutableOrigin
](Callable):
    alias I = C1.I
    alias O = C2.O

    var task_1: Task[C1, Out = C2.I, origin=o1]
    var task_2: Task[C2, origin=o2]

    fn __call__(self, arg: Self.I) -> Self.O:
        result_1 = self.task_1.inner[](arg)
        # Safety: You cannot even instanciate this struct if this is not true.
        inp_2 = rebind[C2.I](result_1)
        result_2 = self.task_2.inner[](inp_2)
        return result_2^


@fieldwise_init
struct ParTask[
    C1: Callable,
    C2: Callable,
    o1: ImmutableOrigin,
    o2: ImmutableOrigin,
](Callable):
    alias I = C1.I
    alias O = (C1.O, C2.O)

    var task_1: Task[C1, In = C2.I, origin=o1]
    var task_2: Task[C2, origin=o2]

    fn __call__(self, arg: Self.I) -> Self.O:
        var res_1 = self.task_1.O()
        var res_2 = self.task_2.O()

        @parameter
        fn run_task(idx: Int):
            if idx == 0:
                res_1 = self.task_1.inner[](arg)
            else:
                # Safety: You cannot instanciate this struct if this is not true.
                inp_2 = rebind[C2.I](arg)
                res_2 = self.task_2.inner[](inp_2)

        sync_parallelize[run_task](2)

        return (res_1^, res_2^)


@fieldwise_init
struct Fn[In: InType, Out: OutType](Callable):
    alias I = In
    alias O = Out

    var func: fn (In) -> Out

    fn __call__(self, arg: Self.I) -> Self.O:
        return self.func(arg)


# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #


# ===-----------------------------------------------------------------------===#
# Tuple
# ===-----------------------------------------------------------------------===#
# Modified to be Defaultable
# Also so values doen't need to be copyable, but right now isn't used because rebind requires copies.


@lldb_formatter_wrapping_type
struct Tuple[*element_types: Copyable & Movable](Sized, TaskValue):
    """The type of a literal tuple expression.

    A tuple consists of zero or more values, separated by commas.

    Parameters:
        element_types: The elements type.
    """

    alias _mlir_type = __mlir_type[
        `!kgen.pack<:!kgen.variadic<`,
        Copyable & Movable,
        `> `,
        element_types,
        `>`,
    ]

    var storage: Self._mlir_type
    """The underlying storage for the tuple."""

    # Overload that crushes down IR generated on the caller side.
    @always_inline("nodebug")
    fn __init__(out self):
        """Construct an empty tuple."""
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.storage)
        )

    @always_inline("nodebug")
    fn __init__(out self, owned *args: *element_types):
        """Construct the tuple.

        Args:
            args: Initial values.
        """
        self = Self(storage=args^)

    @always_inline("nodebug")
    fn __init__(
        out self,
        *,
        owned storage: VariadicPack[_, _, Copyable & Movable, *element_types],
    ):
        """Construct the tuple from a low-level internal representation.

        Args:
            storage: The variadic pack storage to construct from.
        """

        # Mark 'self.storage' as being initialized so we can work on it.
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.storage)
        )

        # Move each element into the tuple storage.
        @parameter
        for i in range(Self.__len__()):
            UnsafePointer(to=storage[i]).move_pointee_into(
                UnsafePointer(to=self[i])
            )

        # Do not destroy the elements when 'storage' goes away.
        __disable_del storage

    fn __del__(owned self):
        """Destructor that destroys all of the elements."""

        # Run the destructor on each member, the destructor of !kgen.pack is
        # trivial and won't do anything.
        @parameter
        for i in range(Self.__len__()):
            UnsafePointer(to=self[i]).destroy_pointee()

    @always_inline("nodebug")
    fn __copyinit__(out self, existing: Self):
        """Copy construct the tuple.

        Args:
            existing: The value to copy from.
        """
        # Mark 'storage' as being initialized so we can work on it.
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.storage)
        )

        @parameter
        for i in range(Self.__len__()):
            UnsafePointer(to=self[i]).init_pointee_copy(existing[i])

    @always_inline
    fn copy(self) -> Self:
        """Explicitly construct a copy of self.

        Returns:
            A copy of this value.
        """
        return self

    @always_inline("nodebug")
    fn __moveinit__(out self, owned existing: Self):
        """Move construct the tuple.

        Args:
            existing: The value to move from.
        """
        # Mark 'storage' as being initialized so we can work on it.
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.storage)
        )

        @parameter
        for i in range(Self.__len__()):
            UnsafePointer(to=existing[i]).move_pointee_into(
                UnsafePointer(to=self[i])
            )
        # Note: The destructor on `existing` is auto-disabled in a moveinit.

    @always_inline
    @staticmethod
    fn __len__() -> Int:
        """Return the number of elements in the tuple.

        Returns:
            The tuple length.
        """

        @parameter
        fn variadic_size(
            x: __mlir_type[`!kgen.variadic<`, Copyable & Movable, `>`]
        ) -> Int:
            return __mlir_op.`pop.variadic.size`(x)

        alias result = variadic_size(element_types)
        return result

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Get the number of elements in the tuple.

        Returns:
            The tuple length.
        """
        return Self.__len__()

    @always_inline("nodebug")
    fn __getitem__[idx: Int](ref self) -> ref [self] element_types[idx.value]:
        """Get a reference to an element in the tuple.

        Parameters:
            idx: The element to return.

        Returns:
            A reference to the specified element.
        """
        # Return a reference to an element at the specified index, propagating
        # mutability of self.
        var storage_kgen_ptr = UnsafePointer(to=self.storage).address

        # KGenPointer to the element.
        var elt_kgen_ptr = __mlir_op.`kgen.pack.gep`[index = idx.value](
            storage_kgen_ptr
        )
        # Use an immortal mut reference, which converts to self's origin.
        return UnsafePointer(elt_kgen_ptr)[]

    @always_inline("nodebug")
    fn __contains__[
        T: EqualityComparable & Copyable & Movable
    ](self, value: T) -> Bool:
        """Return whether the tuple contains the specified value.

        For example:

        ```mojo
        var t = Tuple(True, 1, 2.5)
        if 1 in t:
            print("t contains 1")
        ```

        Args:
            value: The value to search for.

        Parameters:
            T: The type of the value.

        Returns:
            True if the value is in the tuple, False otherwise.
        """

        @parameter
        for i in range(len(VariadicList(element_types))):

            @parameter
            if _type_is_eq[element_types[i], T]():
                if rebind[T](self[i]) == value:
                    return True

        return False
