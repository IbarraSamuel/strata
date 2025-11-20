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
"""Implements the Tuple type.

These are Mojo built-ins, so you don't need to import them.
"""

# # ===-----------------------------------------------------------------------===#
# # Tuple
# # ===-----------------------------------------------------------------------===#
# # Modified to be Defaultable
# # Also so values doen't need to be copyable, but right now isn't used because rebind requires copies.


from sys.intrinsics import _type_is_eq
from builtin import variadic_size

from utils._visualizers import lldb_formatter_wrapping_type


@lldb_formatter_wrapping_type
struct Tuple[
    mut: Bool,
    origin: Origin[mut],
    is_owned: Bool, //,
    *element_types: AnyType,
](Movable, Sized):
    """The type of a literal tuple expression.

    A tuple consists of zero or more values, separated by commas.

    Parameters:
        mut: If the tuple could be mutated.
        origin: The origin of the tuple.
        is_owned: If the values are captured by the tuple.
        element_types: The elements type.
    """

    alias Storage = VariadicPack[
        Self.is_owned, Self.origin, AnyType, *Self.element_types
    ]
    var storage: Self.Storage
    """The underlying storage for the tuple."""

    # Overload that crushes down IR generated on the caller side.
    @always_inline("nodebug")
    fn __init__(out self: Tuple[mut=True, origin=MutAnyOrigin, is_owned=False]):
        """Construct an empty tuple."""
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.storage)
        )

    @always_inline
    fn __init__(
        out self: Tuple[
            mut = args.origin.mut,
            origin = args.origin,
            is_owned = args.is_owned,
            *Self.element_types,
        ],
        *args: * Self.element_types,
    ):
        self.storage = self.Storage(args._value)

    fn __init__(
        out self: Tuple[
            mut = args.origin.mut,
            origin = args.origin,
            is_owned = args.is_owned,
            *Self.element_types,
        ],
        mut*args: * Self.element_types,
        mutable: type_of(True),
    ):
        self.storage = self.Storage(args._value)

    fn __init__(
        out self: Tuple[
            mut = args.origin.mut,
            origin = args.origin,
            is_owned = args.is_owned,
            *Self.element_types,
        ],
        var *args: * Self.element_types,
        own_elements: type_of(True),
    ):
        self.storage = self.Storage(args._value)

    fn __init__(
        out self,
        *,
        storage: Self.Storage,
    ):
        self.storage = Self.Storage(storage._value)

    # fn __del__(owned self):
    #     """Destructor that destroys all of the elements."""

    #     # Run the destructor on each member, the destructor of !kgen.pack is
    #     # trivial and won't do anything.
    #     @parameter
    #     for i in range(Self.__len__()):
    #         UnsafePointer(to=self[i]).destroy_pointee()

    # @always_inline("nodebug")
    # fn __copyinit__(out self, existing: Self):
    #     """Copy construct the tuple.

    #     Args:
    #         existing: The value to copy from.
    #     """
    #     # Mark 'storage' as being initialized so we can work on it.
    #     __mlir_op.`lit.ownership.mark_initialized`(
    #         __get_mvalue_as_litref(self.storage)
    #     )

    #     @parameter
    #     for i in range(Self.__len__()):
    #         UnsafePointer(to=self[i]).init_pointee_copy(existing[i])

    @always_inline
    fn copy(self, out o: Self):
        """Explicitly construct a copy of self.

        Returns:
            A copy of this value.
        """
        o = Self(storage=o.Storage(self.storage._value))

    @always_inline("nodebug")
    fn __moveinit__(out self, deinit existing: Self):
        """Move construct the tuple.

        Args:
            existing: The value to move from.
        """
        self.storage = existing.storage^
        # # Mark 'storage' as being initialized so we can work on it.
        # __mlir_op.`lit.ownership.mark_initialized`(
        #     __get_mvalue_as_litref(self.storage)
        # )

        # @parameter
        # for i in range(Self.__len__()):
        #     UnsafePointer(to=existing[i]).move_pointee_into(
        #         UnsafePointer(to=self[i])
        #     )
        # Note: The destructor on `existing` is auto-disabled in a moveinit.

    @always_inline
    @staticmethod
    fn __len__() -> Int:
        """Return the number of elements in the tuple.

        Returns:
            The tuple length.
        """

        return variadic_size(Self.element_types)

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Get the number of elements in the tuple.

        Returns:
            The tuple length.
        """
        return Self.__len__()

    @always_inline("nodebug")
    fn __getitem__[
        idx: Int
    ](ref self) -> ref [self.origin] Self.element_types[idx]:
        """Get a reference to an element in the tuple.

        Parameters:
            idx: The element to return.

        Returns:
            A reference to the specified element.
        """
        return self.storage[idx]

    @always_inline("nodebug")
    fn __contains__[T: Equatable & Copyable & Movable](self, value: T) -> Bool:
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

        alias size = variadic_size(Self.element_types)

        @parameter
        for i in range(size):

            @parameter
            if _type_is_eq[Self.element_types[i], T]():
                if rebind[T](self[i]) == value:
                    return True

        return False


fn test_compile():
    val1 = String(32)
    val2 = String(432)

    imm_tuple = Tuple(val1, val2)
    print(imm_tuple[0])
    mut_tuple = Tuple(val1, val2, mutable=True)
    mut_tuple[0] += "sam"
    print(mut_tuple[0])

    owned_tuple = Tuple(val1^, val2^, own_elements=True)
    _ = owned_tuple^
