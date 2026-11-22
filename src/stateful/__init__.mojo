"""In-place mutable stateful task pipelines using unified `|` and `&` operators.

Consolidates legacy `strata.void.mutable` into a single variadic representation
where chained `&` fan-outs flatten into one `TaskGroup` instead of spawning
nested `TaskGroup` trees.
"""

from .._internal.runtime import TaskGroup

comptime _MovableMut = _MutCall & Movable & Deinitable

comptime _concat_mut_one[
    v1: TypeList[Trait=_MovableMut, _], v2: _MovableMut
] = TypeList._concat[v1.values, TypeList.of[Trait=_MovableMut, v2].values]

comptime _concat_mut_many[
    v1: TypeList[Trait=_MovableMut, _], v2: TypeList[Trait=_MovableMut, _]
] = TypeList._concat[v1.values, v2.values]


trait _MutCall:
    """Internal base trait for mutable callables."""

    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `Parallel` stages."""

    def __call__(mut self):
        ...


trait MutStage(_MutCall):
    """Trait for stateful in-place mutable stages supporting `|` and `&`."""

    def __or__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_MutCall]) -> Series[
        _MutTaskRef[origin=s, Self], _MutTaskRef[origin=o, type_of(other)]
    ]:
        """Sequence two borrowed mutable stages (`self | other`).

        Parameters:
            s: Origin of `self`.
            o: Origin of `other`.

        Args:
            other: Next mutable stage.

        Returns:
            A `Series` executing `self` then `other`.
        """
        return Series(
            Tuple(_MutTaskRef(self), _MutTaskRef(other))
        )

    def __or__[
        s: MutOrigin, //
    ](ref[s] self, var other: Some[_MovableMut]) -> Series[
        _MutTaskRef[origin=s, Self], type_of(other)
    ]:
        """Sequence a borrowed mutable stage with an owned stage.

        Parameters:
            s: Origin of `self`.

        Args:
            other: Owned next stage.

        Returns:
            A `Series` executing `self` then `other`.
        """
        return Series(Tuple(_MutTaskRef(self), other^))

    def __and__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_MutCall]) -> Parallel[
        _MutTaskRef[origin=s, Self], _MutTaskRef[origin=o, type_of(other)]
    ]:
        """Combine two borrowed mutable stages in parallel (`self & other`).

        Parameters:
            s: Origin of `self`.
            o: Origin of `other`.

        Args:
            other: Parallel mutable stage.

        Returns:
            A flat `Parallel` executing both in one `TaskGroup`.
        """
        return Parallel(Tuple(_MutTaskRef(self), _MutTaskRef(other)))

    def __and__[
        s: MutOrigin, //
    ](ref[s] self, var other: Some[_MovableMut]) -> Parallel[
        _MutTaskRef[origin=s, Self], type_of(other)
    ]:
        """Combine a borrowed mutable stage with an owned stage in parallel.

        Parameters:
            s: Origin of `self`.

        Args:
            other: Owned parallel stage.

        Returns:
            A flat `Parallel` executing both in one `TaskGroup`.
        """
        return Parallel(Tuple(_MutTaskRef(self), other^))

    def __and__[
        s: MutOrigin, //, *other_ts: _MovableMut
    ](ref[s] self, var other: Parallel[*other_ts]) -> Parallel[
        *_concat_mut_many[
            TypeList.of[Trait=_MovableMut, _MutTaskRef[origin=s, Self]](),
            other_ts,
        ]()
    ]:
        """Combine a borrowed stage with a right-hand `Parallel`, flattening into one `TaskGroup`.

        Parameters:
            s: Origin of `self`.
            other_ts: Stages inside the right-hand `Parallel`.

        Args:
            other: Owned right-hand `Parallel` stage.

        Returns:
            A single flat `Parallel` stage.
        """
        comptime Res = Parallel[
            *_concat_mut_many[
                TypeList.of[Trait=_MovableMut, _MutTaskRef[origin=s, Self]](),
                other_ts,
            ]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                Tuple(_MutTaskRef(self)).concat(other^._into_tasks())
            )
        )


struct _MutTaskRef[origin: MutOrigin, //, T: _MutCall](
    Movable, TrivialRegisterPassable, _MutCall
):
    var inner: Pointer[Self.T, Self.origin]

    def __init__(out self, ref[Self.origin] inner: Self.T):
        self.inner = Pointer(to=inner)

    def __call__(mut self):
        self.inner[]()


struct Series[*Ts: _MovableMut](_MutCall, Movable):
    """Flattened sequential pipeline of borrowed or owned mutable stages.

    Parameters:
        Ts: Types of stages in execution order.
    """

    var tasks: Tuple[*Self.Ts]
    """Tuple storing stage references or owned stage values."""

    def __init__(out self, var tasks: Tuple[*Self.Ts]):
        """Initialize the `Series` from a tuple of stages.

        Args:
            tasks: Stages to execute in sequence.
        """
        self.tasks = tasks^

    def __call__(mut self):
        """Execute all stages sequentially in order."""
        comptime for i in range(Self.Ts.length):
            self.tasks[i].__call__()

    def __or__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_MutCall]) -> Series[
        *_concat_mut_one[Self.Ts, _MutTaskRef[origin=o, type_of(other)]]()
    ]:
        """Append a borrowed stage to this sequential pipeline.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Next borrowed mutable stage.

        Returns:
            Flattened `Series` with `other` appended.
        """
        comptime Res = Series[
            *_concat_mut_one[Self.Ts, _MutTaskRef[origin=o, type_of(other)]]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                self.tasks^.concat(Tuple(_MutTaskRef(other)))
            )
        )

    def __or__(
        deinit self, var other: Some[_MovableMut]
    ) -> Series[*_concat_mut_one[Self.Ts, type_of(other)]()]:
        """Append an owned stage to this sequential pipeline.

        Args:
            other: Owned next stage.

        Returns:
            Flattened `Series` with `other` appended.
        """
        comptime Res = Series[*_concat_mut_one[Self.Ts, type_of(other)]()]
        return Res(rebind_var[Tuple[*Res.Ts]](self.tasks^.concat(Tuple(other^))))

    def __and__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_MutCall]) -> Parallel[
        Self, _MutTaskRef[origin=o, type_of(other)]
    ]:
        """Run this sequential pipeline in parallel with a borrowed stage.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Parallel borrowed mutable stage.

        Returns:
            A `Parallel` executing both concurrently.
        """
        return Parallel(Tuple(self^, _MutTaskRef(other)))

    def __and__[
        Other: _MovableMut, //
    ](deinit self, var other: Other) -> Parallel[Self, Other] where (
        not Other._IS_PARALLEL
    ):
        """Run this sequential pipeline in parallel with an owned stage.

        Parameters:
            Other: Owned parallel stage type.

        Args:
            other: Owned parallel stage.

        Returns:
            A `Parallel` executing both concurrently.
        """
        return Parallel(Tuple(self^, other^))

    def __and__[
        *other_ts: _MovableMut
    ](deinit self, var other: Parallel[*other_ts]) -> Parallel[
        *_concat_mut_many[TypeList.of[Trait=_MovableMut, Self](), other_ts]()
    ]:
        """Run this sequential pipeline alongside a `Parallel` group in one `TaskGroup`.

        Parameters:
            other_ts: Stages inside the right-hand `Parallel`.

        Args:
            other: Right-hand `Parallel` stage.

        Returns:
            A single flat `Parallel` stage.
        """
        comptime Res = Parallel[
            *_concat_mut_many[
                TypeList.of[Trait=_MovableMut, Self](), other_ts
            ]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                Tuple(self^).concat(other^._into_tasks())
            )
        )


struct Parallel[*Ts: _MovableMut](_MutCall, Movable):
    """Flattened parallel pipeline executing all mutable stages in one `TaskGroup`.

    Chaining `a & b & c & d` or `(a & b) & (c & d)` merges all branches into a
    single flat `TaskGroup`, avoiding nested `TaskGroup` thread-pool contention.

    Parameters:
        Ts: Types of stages executed concurrently.
    """

    comptime _IS_PARALLEL: Bool = True
    """Marks `Parallel` for associative flattening."""

    var tasks: Tuple[*Self.Ts]
    """Tuple storing stage references or owned stage values."""

    def __init__(out self, var tasks: Tuple[*Self.Ts]):
        """Initialize the `Parallel` group from a tuple of stages.

        Args:
            tasks: Stages to execute concurrently.
        """
        self.tasks = tasks^

    def _into_tasks(deinit self) -> Tuple[*Self.Ts]:
        return self.tasks^

    @staticmethod
    __async def _run_task[T: _MutCall, o: MutOrigin](t: Pointer[T, o]):
        t[].__call__()

    def __call__(mut self):
        """Execute all mutable stages concurrently in one `TaskGroup`."""
        comptime N = Self.Ts.length
        comptime if N == 1:
            self.tasks[0].__call__()
            return
        comptime last = N - 1
        var tg = TaskGroup()
        comptime for i in range(last):
            tg.create_task(Self._run_task(Pointer(to=self.tasks[i])))
        self.tasks[last].__call__()
        tg.wait()

    def __and__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_MutCall]) -> Parallel[
        *_concat_mut_one[Self.Ts, _MutTaskRef[origin=o, type_of(other)]]()
    ]:
        """Append a borrowed mutable stage into this flat `Parallel` group.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Borrowed mutable stage to run concurrently.

        Returns:
            Flat `Parallel` with `other` appended.
        """
        comptime Res = Parallel[
            *_concat_mut_one[Self.Ts, _MutTaskRef[origin=o, type_of(other)]]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                self.tasks^.concat(Tuple(_MutTaskRef(other)))
            )
        )

    def __and__[
        Other: _MovableMut, //
    ](deinit self, var other: Other) -> Parallel[
        *_concat_mut_one[Self.Ts, Other]()
    ] where (not Other._IS_PARALLEL):
        """Append an owned mutable stage into this flat `Parallel` group.

        Parameters:
            Other: Owned mutable stage type.

        Args:
            other: Owned mutable stage to run concurrently.

        Returns:
            Flat `Parallel` with `other` appended.
        """
        comptime Res = Parallel[*_concat_mut_one[Self.Ts, Other]()]
        return Res(rebind_var[Tuple[*Res.Ts]](self.tasks^.concat(Tuple(other^))))

    def __and__[
        *other_ts: _MovableMut
    ](deinit self, var other: Parallel[*other_ts]) -> Parallel[
        *_concat_mut_many[Self.Ts, other_ts]()
    ]:
        """Merge another `Parallel` group into this one in a single flat `TaskGroup`.

        Parameters:
            other_ts: Stages inside the right-hand `Parallel`.

        Args:
            other: Right-hand `Parallel` stage to merge.

        Returns:
            Single flat `Parallel` containing all branches from both groups.
        """
        comptime Res = Parallel[*_concat_mut_many[Self.Ts, other_ts]()]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                self.tasks^.concat(other^._into_tasks())
            )
        )

    def __or__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_MutCall]) -> Series[
        Self, _MutTaskRef[origin=o, type_of(other)]
    ]:
        """Sequence a borrowed stage after this parallel barrier.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Next borrowed mutable stage.

        Returns:
            A `Series` running `self` then `other`.
        """
        return Series(Tuple(self^, _MutTaskRef(other)))

    def __or__(
        deinit self, var other: Some[_MovableMut]
    ) -> Series[Self, type_of(other)]:
        """Sequence an owned stage after this parallel barrier.

        Args:
            other: Owned next stage.

        Returns:
            A `Series` running `self` then `other`.
        """
        return Series(Tuple(self^, other^))
