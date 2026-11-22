"""Asynchronous in-place mutable stateful pipelines using `|` and `&` operators.

Consolidates legacy `strata.void.async_mutable` and `strata.void.async_immutable`
into a unified API where `&` fan-outs flatten into one `TaskGroup`.
"""

from .._internal.runtime import TaskGroup

comptime _MovableAsyncMut = _AsyncMutCall & Movable & Deinitable

comptime _concat_amut_one[
    v1: TypeList[Trait=_MovableAsyncMut, _], v2: _MovableAsyncMut
] = TypeList._concat[
    v1.values, TypeList.of[Trait=_MovableAsyncMut, v2].values
]

comptime _concat_amut_many[
    v1: TypeList[Trait=_MovableAsyncMut, _],
    v2: TypeList[Trait=_MovableAsyncMut, _],
] = TypeList._concat[v1.values, v2.values]


trait _AsyncMutCall:
    """Internal base trait for asynchronous mutable callables."""

    comptime _IS_PARALLEL: Bool = False
    """Internal marker distinguishing flat `AsyncParallel` stages."""

    __async def __call__(mut self):
        ...


trait AsyncMutStage(_AsyncMutCall):
    """Trait for asynchronous stateful stages supporting `|` and `&`."""

    def __or__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_AsyncMutCall]) -> AsyncSeries[
        _AsyncTaskRef[origin=s, Self],
        _AsyncTaskRef[origin=o, type_of(other)],
    ]:
        """Sequence two borrowed async stages (`self | other`).

        Parameters:
            s: Origin of `self`.
            o: Origin of `other`.

        Args:
            other: Next async stage.

        Returns:
            An `AsyncSeries` executing `self` then `other`.
        """
        return AsyncSeries(_AsyncTaskRef(self), _AsyncTaskRef(other))

    def __or__[
        s: MutOrigin, //
    ](ref[s] self, var other: Some[_MovableAsyncMut]) -> AsyncSeries[
        _AsyncTaskRef[origin=s, Self], type_of(other)
    ]:
        """Sequence a borrowed async stage with an owned async stage.

        Parameters:
            s: Origin of `self`.

        Args:
            other: Owned next async stage.

        Returns:
            An `AsyncSeries` executing `self` then `other`.
        """
        return AsyncSeries(_AsyncTaskRef(self), other^)

    def __and__[
        s: MutOrigin, o: MutOrigin, //
    ](ref[s] self, ref[o] other: Some[_AsyncMutCall]) -> AsyncParallel[
        _AsyncTaskRef[origin=s, Self],
        _AsyncTaskRef[origin=o, type_of(other)],
    ]:
        """Combine two borrowed async stages in parallel (`self & other`).

        Parameters:
            s: Origin of `self`.
            o: Origin of `other`.

        Args:
            other: Parallel async stage.

        Returns:
            A flat `AsyncParallel` running both concurrently.
        """
        return AsyncParallel(Tuple(_AsyncTaskRef(self), _AsyncTaskRef(other)))

    def __and__[
        s: MutOrigin, //
    ](ref[s] self, var other: Some[_MovableAsyncMut]) -> AsyncParallel[
        _AsyncTaskRef[origin=s, Self], type_of(other)
    ]:
        """Combine a borrowed async stage with an owned async stage in parallel.

        Parameters:
            s: Origin of `self`.

        Args:
            other: Owned parallel async stage.

        Returns:
            A flat `AsyncParallel` running both concurrently.
        """
        return AsyncParallel(Tuple(_AsyncTaskRef(self), other^))

    def __and__[
        s: MutOrigin, //, *other_ts: _MovableAsyncMut
    ](ref[s] self, var other: AsyncParallel[*other_ts]) -> AsyncParallel[
        *_concat_amut_many[
            TypeList.of[
                Trait=_MovableAsyncMut, _AsyncTaskRef[origin=s, Self]
            ](),
            other_ts,
        ]()
    ]:
        """Combine a borrowed stage with a right-hand `AsyncParallel`, flattening into one `TaskGroup`.

        Parameters:
            s: Origin of `self`.
            other_ts: Stages inside the right-hand `AsyncParallel`.

        Args:
            other: Owned right-hand `AsyncParallel` stage.

        Returns:
            A single flat `AsyncParallel` stage.
        """
        comptime Res = AsyncParallel[
            *_concat_amut_many[
                TypeList.of[
                    Trait=_MovableAsyncMut, _AsyncTaskRef[origin=s, Self]
                ](),
                other_ts,
            ]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                Tuple(_AsyncTaskRef(self)).concat(other^._into_tasks())
            )
        )


struct _AsyncTaskRef[origin: MutOrigin, //, T: _AsyncMutCall](
    Movable, TrivialRegisterPassable, _AsyncMutCall
):
    var inner: Pointer[Self.T, Self.origin]

    def __init__(out self, ref[Self.origin] inner: Self.T):
        self.inner = Pointer(to=inner)

    __async def __call__(mut self):
        __await self.inner[]()


@fieldwise_init
struct AsyncSeries[T1: _MovableAsyncMut, T2: _MovableAsyncMut](
    _AsyncMutCall, Movable
):
    """Sequential composition of two async mutable stages.

    Parameters:
        T1: First async stage type.
        T2: Second async stage type.
    """

    var t1: Self.T1
    """First stage."""
    var t2: Self.T2
    """Second stage."""

    __async def __call__(mut self):
        """Asynchronously execute `t1`, then `t2`."""
        __await self.t1()
        __await self.t2()

    def run(mut self):
        """Execute this async sequential pipeline synchronously via a `TaskGroup`."""
        var tg = TaskGroup()
        tg.create_task(self())
        tg.wait()

    def __or__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_AsyncMutCall]) -> AsyncSeries[
        Self, _AsyncTaskRef[origin=o, type_of(other)]
    ]:
        """Append a borrowed async stage to this sequence.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Next borrowed async stage.

        Returns:
            `AsyncSeries` executing `self` then `other`.
        """
        return AsyncSeries(self^, _AsyncTaskRef(other))

    def __or__(
        deinit self, var other: Some[_MovableAsyncMut]
    ) -> AsyncSeries[Self, type_of(other)]:
        """Append an owned async stage to this sequence.

        Args:
            other: Next owned async stage.

        Returns:
            `AsyncSeries` executing `self` then `other`.
        """
        return AsyncSeries(self^, other^)

    def __and__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_AsyncMutCall]) -> AsyncParallel[
        Self, _AsyncTaskRef[origin=o, type_of(other)]
    ]:
        """Run this async sequence in parallel with a borrowed async stage.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Parallel borrowed async stage.

        Returns:
            An `AsyncParallel` running both concurrently.
        """
        return AsyncParallel(Tuple(self^, _AsyncTaskRef(other)))

    def __and__[
        Other: _MovableAsyncMut, //
    ](deinit self, var other: Other) -> AsyncParallel[Self, Other] where (
        not Other._IS_PARALLEL
    ):
        """Run this async sequence in parallel with an owned async stage.

        Parameters:
            Other: Parallel owned async stage type.

        Args:
            other: Parallel owned async stage.

        Returns:
            An `AsyncParallel` running both concurrently.
        """
        return AsyncParallel(Tuple(self^, other^))

    def __and__[
        *other_ts: _MovableAsyncMut
    ](deinit self, var other: AsyncParallel[*other_ts]) -> AsyncParallel[
        *_concat_amut_many[
            TypeList.of[Trait=_MovableAsyncMut, Self](), other_ts
        ]()
    ]:
        """Run this async sequence alongside an `AsyncParallel` group in one `TaskGroup`.

        Parameters:
            other_ts: Stages inside the right-hand `AsyncParallel`.

        Args:
            other: Right-hand `AsyncParallel` stage.

        Returns:
            Single flat `AsyncParallel` stage.
        """
        comptime Res = AsyncParallel[
            *_concat_amut_many[
                TypeList.of[Trait=_MovableAsyncMut, Self](), other_ts
            ]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](Tuple(self^).concat(other^._into_tasks()))
        )


struct AsyncParallel[*Ts: _MovableAsyncMut](_AsyncMutCall, Movable):
    """Flattened parallel pipeline executing all async mutable stages in one `TaskGroup`.

    Parameters:
        Ts: Types of async stages executed concurrently.
    """

    comptime _IS_PARALLEL: Bool = True
    """Marks `AsyncParallel` for associative flattening."""

    var tasks: Tuple[*Self.Ts]
    """Tuple storing stage references or owned stage values."""

    def __init__(out self, var tasks: Tuple[*Self.Ts]):
        """Initialize the `AsyncParallel` group from a tuple of stages.

        Args:
            tasks: Async stages to execute concurrently.
        """
        self.tasks = tasks^

    def _into_tasks(deinit self) -> Tuple[*Self.Ts]:
        return self.tasks^

    __async def __call__(mut self):
        """Asynchronously execute all stages concurrently in one `TaskGroup`."""
        var tg = TaskGroup()
        comptime for i in range(Self.Ts.length):
            tg.create_task(self.tasks[i]())
        __await tg

    def run(mut self):
        """Execute this async parallel pipeline synchronously via a `TaskGroup`."""
        var tg = TaskGroup()
        comptime for i in range(Self.Ts.length):
            tg.create_task(self.tasks[i]())
        tg.wait()

    def __and__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_AsyncMutCall]) -> AsyncParallel[
        *_concat_amut_one[Self.Ts, _AsyncTaskRef[origin=o, type_of(other)]]()
    ]:
        """Append a borrowed async stage into this flat `AsyncParallel` group.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Borrowed async stage to execute concurrently.

        Returns:
            Flat `AsyncParallel` with `other` appended.
        """
        comptime Res = AsyncParallel[
            *_concat_amut_one[
                Self.Ts, _AsyncTaskRef[origin=o, type_of(other)]
            ]()
        ]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                self.tasks^.concat(Tuple(_AsyncTaskRef(other)))
            )
        )

    def __and__[
        Other: _MovableAsyncMut, //
    ](deinit self, var other: Other) -> AsyncParallel[
        *_concat_amut_one[Self.Ts, Other]()
    ] where (not Other._IS_PARALLEL):
        """Append an owned async stage into this flat `AsyncParallel` group.

        Parameters:
            Other: Owned async stage type.

        Args:
            other: Owned async stage to execute concurrently.

        Returns:
            Flat `AsyncParallel` with `other` appended.
        """
        comptime Res = AsyncParallel[*_concat_amut_one[Self.Ts, Other]()]
        return Res(rebind_var[Tuple[*Res.Ts]](self.tasks^.concat(Tuple(other^))))

    def __and__[
        *other_ts: _MovableAsyncMut
    ](deinit self, var other: AsyncParallel[*other_ts]) -> AsyncParallel[
        *_concat_amut_many[Self.Ts, other_ts]()
    ]:
        """Merge another `AsyncParallel` group into this one associatively.

        Parameters:
            other_ts: Stages inside the right-hand `AsyncParallel`.

        Args:
            other: Right-hand `AsyncParallel` stage.

        Returns:
            Single flat `AsyncParallel` containing all branches from both groups.
        """
        comptime Res = AsyncParallel[*_concat_amut_many[Self.Ts, other_ts]()]
        return Res(
            rebind_var[Tuple[*Res.Ts]](
                self.tasks^.concat(other^._into_tasks())
            )
        )

    def __or__[
        o: MutOrigin, //
    ](deinit self, ref[o] other: Some[_AsyncMutCall]) -> AsyncSeries[
        Self, _AsyncTaskRef[origin=o, type_of(other)]
    ]:
        """Sequence a borrowed async stage after this parallel barrier.

        Parameters:
            o: Origin of `other`.

        Args:
            other: Next borrowed async stage.

        Returns:
            An `AsyncSeries` running `self` then `other`.
        """
        return AsyncSeries(self^, _AsyncTaskRef(other))

    def __or__(
        deinit self, var other: Some[_MovableAsyncMut]
    ) -> AsyncSeries[Self, type_of(other)]:
        """Sequence an owned async stage after this parallel barrier.

        Args:
            other: Next owned async stage.

        Returns:
            An `AsyncSeries` running `self` then `other`.
        """
        return AsyncSeries(self^, other^)
