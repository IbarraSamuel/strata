"""Comprehensive edge-case tests across all Strata v2 Python modules."""

from __future__ import annotations

import asyncio
import contextlib
import math
import threading
import time
import traceback
import warnings
from typing import TYPE_CHECKING, Any, cast

import pytest

from strata import (
    BranchTask,
    MapTask,
    RetryTask,
    SelectTask,
    SequentialExecutor,
    TaskGroup,
    TracingExecutor,
    ZipTask,
    arun,
    async_task,
    branch,
    fallback,
    graph_stats,
    group,
    map_stage,
    map_task,
    mojo_strata,
    native_cpu_work,
    native_float_linear,
    native_float_poly,
    native_int_linear,
    native_stage,
    retry,
    select,
    task,
    timeout,
    to_dot,
    to_mermaid,
    zip_tasks,
)

if TYPE_CHECKING:
    from collections.abc import AsyncIterator, Iterator


class _CustomBaseError(BaseException):
    """Non-Exception BaseException subclass for testing BaseExceptionGroup."""


@task
def _inc(x: int) -> int:
    return x + 1


@task
def _double(x: int) -> int:
    return x * 2


@task
def _triple(x: int) -> int:
    return x * 3


@task
def _quad(x: int) -> int:
    return x * 4


@task
def _add_ten(x: int) -> int:
    return x + 10


# ===----------------------------------------------------------------------=== #
# 1. Immutability & Branching
# ===----------------------------------------------------------------------=== #


def test_immutability_and_branching_from_same_base() -> None:
    base = _inc | _double
    p1 = base | _inc
    p2 = base | _add_ten
    p3 = base & _triple

    expected_base = 8
    expected_p1 = 9
    expected_p2 = 18
    expected_p3 = (8, 9)

    for _ in range(3):
        assert base(3) == expected_base
        assert p1(3) == expected_p1
        assert p2(3) == expected_p2
        assert p3(3) == expected_p3

    expected_base_10 = 22
    expected_p1_10 = 23
    expected_p2_10 = 32
    expected_p3_10 = (22, 30)
    assert base(10) == expected_base_10
    assert p1(10) == expected_p1_10
    assert p2(10) == expected_p2_10
    assert p3(10) == expected_p3_10


# ===----------------------------------------------------------------------=== #
# 2. Parallel Flattening vs group(...) & Single-Element TaskGroup
# ===----------------------------------------------------------------------=== #


def test_parallel_flattening_grouping_and_single_task_group() -> None:
    # Associative flattening
    assert (_inc & (_double & _triple))(5) == (6, 10, 15)
    assert ((_inc & _double) & _triple)(5) == (6, 10, 15)
    assert ((_inc & _double) & (_triple & _quad))(5) == (6, 10, 15, 20)

    # Explicit nested grouping
    assert (group(_inc & _double) & group(_triple & _quad))(5) == ((6, 10), (15, 20))
    assert (group(_inc & _double) & _triple)(5) == ((6, 10), 15)
    assert (_inc & group(_double & _triple))(5) == (6, (10, 15))
    assert (group(group(_inc & _double)) & _triple)(5) == ((6, 10), 15)

    # Single-element TaskGroup
    single = TaskGroup(_double)
    expected_single = 14
    assert single(7) == expected_single
    assert single.stats().stage_count == 1


# ===----------------------------------------------------------------------=== #
# 3. Exception Propagation, BaseException, Tracebacks & Short-Circuiting
# ===----------------------------------------------------------------------=== #


def _deep_traceback_helper(x: int) -> int:
    msg = f"deep_boom:{x}"
    raise ValueError(msg)


@task
def _raise_deep_value_error(x: int) -> int:
    return _deep_traceback_helper(x)


@task
def _raise_custom_base(x: int) -> int:
    msg = f"base_boom:{x}"
    raise _CustomBaseError(msg)


@task
def _raise_keyboard_interrupt(x: int) -> int:
    msg = f"kbd:{x}"
    raise KeyboardInterrupt(msg)


def test_base_exception_and_exception_group_distinction() -> None:
    # Single BaseException subclass propagates intact (serial & parallel)
    with pytest.raises(_CustomBaseError, match="base_boom:4"):
        (_inc | _raise_custom_base | _double)(3)

    with pytest.raises(KeyboardInterrupt, match="kbd:5"):
        (_inc & _raise_keyboard_interrupt & _double)(5)

    # Mixed Exception + BaseException in parallel raises BaseExceptionGroup
    # (and NOT ExceptionGroup).
    mixed = _raise_deep_value_error & _raise_custom_base
    with pytest.RaisesGroup(
        pytest.RaisesExc(ValueError, match="deep_boom:9"),
        pytest.RaisesExc(_CustomBaseError, match="base_boom:9"),
    ) as exc_info:
        mixed(9)
    assert not isinstance(exc_info.value, ExceptionGroup)

    # Two standard Exceptions in parallel raise ExceptionGroup.
    @task
    def _raise_key_err(x: int) -> int:
        msg = f"key:{x}"
        raise KeyError(msg)

    std_both = _raise_deep_value_error & _raise_key_err
    with pytest.RaisesGroup(
        pytest.RaisesExc(ValueError, match="deep_boom:9"),
        pytest.RaisesExc(KeyError, match="key:9"),
    ) as std_info:
        std_both(9)
    assert isinstance(std_info.value, ExceptionGroup)


def test_exact_traceback_preservation_and_serial_short_circuit() -> None:
    # Single failure preserves original traceback frames including inner helper
    with pytest.raises(ValueError, match="deep_boom:4") as exc_info:
        (_inc | _raise_deep_value_error)(3)
    tb_names = [frame.name for frame in traceback.extract_tb(exc_info.tb)]
    assert "_deep_traceback_helper" in tb_names
    assert "_raise_deep_value_error" in tb_names

    # Parallel single failure also preserves original traceback
    with pytest.raises(ValueError, match="deep_boom:6") as par_exc:
        (_inc & _raise_deep_value_error & _double)(6)
    par_tb_names = [frame.name for frame in traceback.extract_tb(par_exc.tb)]
    assert "_deep_traceback_helper" in par_tb_names

    # Exception in serial middle stage short-circuits downstream stages
    downstream_calls = 0

    @task
    def _downstream(x: int) -> int:
        nonlocal downstream_calls
        downstream_calls += 1
        return x + 100

    pipe = _inc | _raise_deep_value_error | _downstream
    with pytest.raises(ValueError, match="deep_boom:11"):
        pipe(10)
    assert downstream_calls == 0


# ===----------------------------------------------------------------------=== #
# 4. Hybrid GIL-Free Mojo NativeStage Edge Cases
# ===----------------------------------------------------------------------=== #


def test_native_int_linear_boundaries_and_overflow() -> None:
    lin = native_int_linear(scale=2, bias=-3, name="lin")
    identity_int = native_int_linear(scale=1, bias=0, name="id_int")

    expected_zero = -3
    expected_neg1 = -5
    expected_neg100 = -203
    assert lin(0) == expected_zero
    assert lin(-1) == expected_neg1
    assert lin(-100) == expected_neg100

    max_i64 = (1 << 63) - 1
    min_i64 = -(1 << 63)
    assert identity_int(max_i64) == max_i64
    assert identity_int(min_i64) == min_i64
    assert identity_int(-1) == -1

    # Overflow above int64 max or below int64 min raises OverflowError cleanly
    with pytest.raises(OverflowError):
        identity_int(max_i64 + 1)

    with pytest.raises(OverflowError):
        identity_int(min_i64 - 1)


def test_native_float_inputs_special_values_and_errors() -> None:
    flin = native_float_linear(scale=2.5, bias=-1.0, name="flin")
    fpoly = native_float_poly(1.0, -2.0, 3.0, name="fpoly")

    # Accepts both Python int and float inputs
    assert flin(4) == pytest.approx(9.0)
    assert flin(-1) == pytest.approx(-3.5)
    assert flin(-1.0) == pytest.approx(-3.5)
    assert fpoly(2) == pytest.approx(9.0)
    assert fpoly(0) == pytest.approx(1.0)

    # NaN and +/-inf propagate according to IEEE-754
    assert math.isnan(flin(float("nan")))
    assert math.isinf(flin(float("inf")))
    assert flin(float("inf")) > 0
    assert math.isinf(flin(float("-inf")))
    assert flin(float("-inf")) < 0
    assert math.isnan(fpoly(float("nan")))
    assert math.isinf(fpoly(float("inf")))

    # Invalid string input raises TypeError
    with pytest.raises(TypeError, match="expected a float or int"):
        cast("Any", flin)("oops")

    with pytest.raises(TypeError, match="expected a float or int"):
        cast("Any", fpoly)("oops")


def test_native_fused_chains_type_coercion_and_errors() -> None:
    i_stage = native_int_linear(scale=3, bias=2, name="int_lin")
    f_stage = native_float_linear(scale=0.5, bias=1.0, name="flt_lin")

    # int -> float widens cleanly inside fused GIL-free chain
    int_to_float = i_stage | f_stage
    assert int_to_float(4) == pytest.approx(8.0)

    # float -> int raises TypeError cleanly at runtime
    float_to_int = cast("Any", f_stage) | i_stage
    with pytest.raises(TypeError, match="Incompatible types"):
        float_to_int(4.0)


def test_raw_pycapsule_directly_in_task_group_and_operators() -> None:
    raw_cap = mojo_strata.make_int_linear_capsule(4, 3)

    # Directly in TaskGroup without wrapping in native_stage(...)
    tg = TaskGroup(cast("Any", raw_cap))
    expected_tg = 23
    assert tg(5) == expected_tg

    # Directly with | and & alongside Python and NativeTask stages
    ser_pipe = _inc | cast("Any", raw_cap) | _double
    expected_ser = 54
    assert ser_pipe(5) == expected_ser

    par_pipe = _double & cast("Any", raw_cap) & native_int_linear(scale=2, bias=1)
    assert par_pipe(5) == (10, 23, 11)

    # Directly with native_int_linear (fused GIL-free chain)
    fused_cap = native_int_linear(scale=2, bias=0) | cast("Any", raw_cap)
    expected_fused = 43
    assert fused_cap(5) == expected_fused

    # Also works under arun
    assert asyncio.run(arun(par_pipe, 5)) == (10, 23, 11)


def test_native_cpu_work_zero_and_negative_iterations() -> None:
    work0 = native_cpu_work(0, name="zero_work")
    work_neg = native_cpu_work(-10, name="neg_work")

    res0 = work0(42)
    assert isinstance(res0, int)
    assert res0 >= 0
    assert work0(42) == res0
    assert work_neg(42) == res0


def test_hybrid_parallel_error_propagation_native_and_python() -> None:
    @task
    def _py_fail(x: Any) -> int:  # ruff: ignore[any-type]
        msg = f"py_val_err:{x}"
        raise ValueError(msg)

    # Case A: Native unboxing fails (TypeError) + Python raises ValueError
    hybrid_unbox = native_int_linear(scale=2, bias=1) & _py_fail
    with pytest.RaisesGroup(
        pytest.RaisesExc(TypeError, match="expected an int"),
        pytest.RaisesExc(ValueError, match="py_val_err:bad"),
    ):
        cast("Any", hybrid_unbox)("bad")

    # Case B: Fused native chain fails at runtime (float -> int) + Python ValueError
    bad_chain = cast("Any", native_float_linear(scale=1.0, bias=0.5)) | (
        native_int_linear(scale=2, bias=0)
    )
    hybrid_runtime = bad_chain & _py_fail
    with pytest.RaisesGroup(
        pytest.RaisesExc(TypeError, match="Incompatible types"),
        pytest.RaisesExc(ValueError, match="py_val_err:5"),
    ):
        hybrid_runtime(5)


# ===----------------------------------------------------------------------=== #
# 5. AsyncTask & arun Edge Cases
# ===----------------------------------------------------------------------=== #


def test_async_task_sync_call_inside_running_event_loop() -> None:
    @async_task
    async def _async_add(x: int) -> int:
        await asyncio.sleep(0.005)
        return x + 7

    async def _call_sync_from_loop() -> int:
        await asyncio.sleep(0)
        # Uses worker-thread fallback instead of failing on active event loop
        return _async_add(10)

    expected = 17
    assert asyncio.run(_call_sync_from_loop()) == expected


def test_arun_single_stages_map_and_timeout() -> None:
    @async_task
    async def _a_inc(x: int) -> int:
        await asyncio.sleep(0.001)
        return x + 1

    @async_task
    async def _a_slow(x: int) -> int:
        await asyncio.sleep(0.15)
        return x

    async def _run() -> None:
        expected_inc = 11
        expected_dbl = 20
        expected_native = 23

        assert await arun(_a_inc, 10) == expected_inc
        assert await arun(_double, 10) == expected_dbl
        assert await arun(native_int_linear(scale=2, bias=3), 10) == expected_native
        assert await arun(map_task(_a_inc, max_concurrency=2), []) == []

        assert await arun(timeout(_a_inc, seconds=1.0), 10) == expected_inc
        with pytest.raises(TimeoutError):
            await arun(timeout(_a_slow, seconds=0.02), 10)

    asyncio.run(_run())


def test_arun_retry_and_fallback_edge_cases() -> None:
    @async_task
    async def _a_inc(x: int) -> int:
        await asyncio.sleep(0)
        return x + 1

    @async_task
    async def _a_fail_val(x: int) -> int:
        await asyncio.sleep(0)
        msg = f"val_boom:{x}"
        raise ValueError(msg)

    @async_task
    async def _a_fail_key(x: int) -> int:
        await asyncio.sleep(0)
        msg = f"key_boom:{x}"
        raise KeyError(msg)

    secondary_calls = 0

    @async_task
    async def _a_secondary(x: int) -> int:
        nonlocal secondary_calls
        secondary_calls += 1
        await asyncio.sleep(0)
        return x * 100

    retry_calls = 0

    @async_task
    async def _a_always_fail(x: int) -> int:
        nonlocal retry_calls
        retry_calls += 1
        await asyncio.sleep(0)
        msg = f"attempt:{retry_calls}:{x}"
        raise RuntimeError(msg)

    async def _run() -> None:
        expected_inc = 11
        expected_retry_calls = 3
        expected_fb = 400

        # RetryTask exhausted after max_attempts
        r_fail = retry(_a_always_fail, max_attempts=3)
        with pytest.raises(RuntimeError, match="attempt:3:5"):
            await arun(r_fail, 5)
        assert retry_calls == expected_retry_calls

        # FallbackTask: primary succeeds -> secondary NOT called
        fb_ok = fallback(_a_inc, _a_secondary)
        assert await arun(fb_ok, 10) == expected_inc
        assert secondary_calls == 0

        # FallbackTask: catch tuple mismatch -> re-raises without secondary
        fb_mismatch = fallback(_a_fail_key, _a_secondary, catch=(ValueError,))
        with pytest.raises(KeyError, match="key_boom:4"):
            await arun(fb_mismatch, 4)
        assert secondary_calls == 0

        # FallbackTask: catch tuple matches -> invokes secondary
        fb_match = fallback(_a_fail_val, _a_secondary, catch=(ValueError,))
        assert await arun(fb_match, 4) == expected_fb
        assert secondary_calls == 1

    asyncio.run(_run())


# ===----------------------------------------------------------------------=== #
# 6. stream / map / astream Edge Cases
# ===----------------------------------------------------------------------=== #


def test_stream_and_map_boundary_cases() -> None:
    pipe = _inc | _double

    # Empty iterables
    assert pipe.map([]) == []
    assert list(pipe.stream([], max_in_flight=1)) == []
    assert list(pipe.stream([], max_in_flight=4, ordered=True)) == []
    assert list(pipe.stream([], max_in_flight=4, ordered=False)) == []

    # Single-element iterables
    assert pipe.map([5]) == [12]
    assert list(pipe.stream([5], max_in_flight=1)) == [12]
    assert list(pipe.stream([5], max_in_flight=8, ordered=True)) == [12]
    assert list(pipe.stream([5], max_in_flight=8, ordered=False)) == [12]

    # Sequential fast path (limit=1) and concurrency limit larger than input
    items = [1, 2, 3]
    assert list(pipe.stream(items, max_in_flight=1)) == [4, 6, 8]
    assert list(pipe.stream(items, max_in_flight=20, ordered=True)) == [4, 6, 8]
    assert sorted(pipe.stream(items, max_in_flight=20, ordered=False)) == [4, 6, 8]


def test_stream_unordered_error_propagation_clean_shutdown() -> None:
    @task
    def _boom_fast(x: int) -> int:
        if x == 1:
            msg = "unordered_boom"
            raise ValueError(msg)
        time.sleep(0.03)
        return x * 10

    with pytest.raises(ValueError, match="unordered_boom"):
        list(_boom_fast.stream([0, 1, 2, 3, 4], max_in_flight=3, ordered=False))


def test_astream_generators_and_validation() -> None:
    @async_task
    async def _a_double(x: int) -> int:
        await asyncio.sleep(0.002)
        return x * 2

    def _sync_gen() -> Iterator[int]:
        yield from [1, 2, 3, 4]

    async def _async_gen() -> AsyncIterator[int]:
        for i in [1, 2, 3, 4]:
            await asyncio.sleep(0.001)
            yield i

    async def _run() -> None:
        assert [v async for v in _a_double.astream([], max_in_flight=4)] == []
        assert [v async for v in _a_double.astream([5], max_in_flight=4)] == [10]

        assert [v async for v in _a_double.astream(_sync_gen(), max_in_flight=1)] == [
            2,
            4,
            6,
            8,
        ]
        assert [v async for v in _a_double.astream(_async_gen(), max_in_flight=1)] == [
            2,
            4,
            6,
            8,
        ]

        # Concurrency limit larger than item count
        assert [
            v async for v in _a_double.astream([2, 3], max_in_flight=16, ordered=True)
        ] == [4, 6]

        with pytest.raises(ValueError, match="max_in_flight"):
            _ = [v async for v in _a_double.astream([1, 2], max_in_flight=0)]
        with pytest.raises(ValueError, match="max_in_flight"):
            _ = [v async for v in _a_double.astream([1, 2], max_in_flight=-2)]

    asyncio.run(_run())


def test_astream_midstream_error_cancels_remaining_tasks() -> None:
    async def _run() -> None:
        cancelled_unordered = 0

        @async_task
        async def _fail_or_sleep(x: int) -> int:
            nonlocal cancelled_unordered
            if x == 1:
                await asyncio.sleep(0.005)
                msg = "astream_boom"
                raise ValueError(msg)
            try:
                await asyncio.sleep(1.0)
            except asyncio.CancelledError:
                cancelled_unordered += 1
                raise
            return x

        with pytest.raises(ValueError, match="astream_boom"):
            _ = [
                v
                async for v in _fail_or_sleep.astream(
                    [0, 1, 2, 3], max_in_flight=4, ordered=False
                )
            ]
        assert cancelled_unordered >= 1

        cancelled_ordered = 0

        @async_task
        async def _fail_first_ordered(x: int) -> int:
            nonlocal cancelled_ordered
            if x == 0:
                await asyncio.sleep(0.005)
                msg = "ordered_boom"
                raise ValueError(msg)
            try:
                await asyncio.sleep(1.0)
            except asyncio.CancelledError:
                cancelled_ordered += 1
                raise
            return x

        with pytest.raises(ValueError, match="ordered_boom"):
            _ = [
                v
                async for v in _fail_first_ordered.astream(
                    [0, 1, 2, 3], max_in_flight=4, ordered=True
                )
            ]
        assert cancelled_ordered >= 1

    asyncio.run(_run())


# ===----------------------------------------------------------------------=== #
# 7. Combinators & Introspection Edge Cases
# ===----------------------------------------------------------------------=== #


def test_zip_timeout_retry_and_map_combinator_edge_cases() -> None:
    # ZipTask with 0, 1, and 4 stages
    with pytest.raises(ValueError, match="at least one stage"):
        ZipTask()

    z1 = zip_tasks(_double)
    assert z1((7,)) == (14,)

    z4 = zip_tasks(_inc, _double, _triple, _quad)
    assert z4((1, 2, 3, 4)) == (2, 4, 9, 16)

    # TimeoutTask validation & inner exception propagation (ensuring pool cleanup)
    with pytest.raises(ValueError, match="positive"):
        timeout(_inc, seconds=0)
    with pytest.raises(ValueError, match="positive"):
        timeout(_inc, seconds=-1.5)

    with pytest.raises(ValueError, match="deep_boom:3"):
        timeout(_raise_deep_value_error, seconds=1.0)(3)

    # RetryTask: retry_on=(ValueError,) skips KeyError; max_attempts <= 0 clamps to 1
    key_calls = 0

    @task
    def _fail_key(x: int) -> int:
        nonlocal key_calls
        key_calls += 1
        msg = f"k:{x}"
        raise KeyError(msg)

    r_selective = retry(_fail_key, max_attempts=4, retry_on=(ValueError,))
    with pytest.raises(KeyError, match="k:2"):
        r_selective(2)
    assert key_calls == 1

    val_calls = 0

    @task
    def _fail_val(x: int) -> int:
        nonlocal val_calls
        val_calls += 1
        msg = f"v:{x}"
        raise ValueError(msg)

    r_clamped = retry(_fail_val, max_attempts=0, retry_on=(ValueError,))
    assert r_clamped.max_attempts == 1
    with pytest.raises(ValueError, match="v:2"):
        r_clamped(2)
    assert val_calls == 1

    # MapTask: empty, single item, sequential, non-divisible waves, item error
    m_seq = map_task(_double, max_concurrency=1)
    assert m_seq([]) == []
    assert m_seq([9]) == [18]
    assert m_seq([1, 2, 3, 4, 5]) == [2, 4, 6, 8, 10]

    m_non_div = map_task(_double, max_concurrency=3)
    assert m_non_div([1, 2, 3, 4, 5, 6, 7]) == [2, 4, 6, 8, 10, 12, 14]

    @task
    def _fail_on_three(x: int) -> int:
        fail_target = 3
        if x == fail_target:
            msg = "three_boom"
            raise ValueError(msg)
        return x * 2

    with pytest.raises(ValueError, match="three_boom"):
        map_task(_fail_on_three, max_concurrency=2)([1, 2, 3, 4])


def test_tracing_executor_reuse_and_diagrams_with_quotes_and_nesting() -> None:
    pipe = (_inc & _double) | zip_tasks(_triple, _quad)

    # TracingExecutor: clear(), reuse, sequential=True vs sequential=False
    seq_tracer = TracingExecutor(sequential=True)
    assert seq_tracer.run(pipe, 3) == (12, 24)
    expected_spans = 4
    assert len(seq_tracer.spans) == expected_spans
    # Reuse accumulates spans
    assert seq_tracer.run(pipe, 4) == (15, 32)
    assert len(seq_tracer.spans) == expected_spans * 2
    seq_tracer.clear()
    assert seq_tracer.spans == []
    assert seq_tracer.total_duration_ns() == 0

    par_tracer = TracingExecutor(sequential=False)
    assert par_tracer.run(pipe, 3) == (12, 24)
    assert len(par_tracer.spans) == expected_spans
    par_tracer.clear()
    assert par_tracer.spans == []

    # Diagrams with quotes in stage labels AND nested group(...) + zip_tasks(...)
    quoted_native = native_int_linear(scale=2, bias=1, name='scale "fast"')

    def _quoted_fn(x: int) -> int:
        return x + 1

    _quoted_fn.__name__ = 'step "A"'
    quoted_task = task(_quoted_fn)

    complex_pipe = group(quoted_native & quoted_task) | zip_tasks(
        group(_inc & _double), _triple
    )

    min_subgraphs = 3
    mmd = to_mermaid(complex_pipe)
    assert "native(scale &quot;fast&quot;)" in mmd
    assert "step &quot;A&quot;" in mmd
    assert 'scale "fast"' not in mmd
    assert 'step "A"' not in mmd
    assert 'subgraph g0["group 0"]' in mmd
    assert '["zip"]' in mmd
    assert mmd.count("subgraph ") >= min_subgraphs

    dot = to_dot(complex_pipe)
    assert r"native(scale \"fast\")" in dot
    assert r"step \"A\"" in dot
    assert 'scale "fast"' not in dot
    assert 'step "A"' not in dot
    assert "subgraph cluster_0" in dot
    assert 'label="zip";' in dot
    assert dot.count("subgraph cluster_") >= min_subgraphs


# ===----------------------------------------------------------------------=== #
# 8. Wave 1 Safety Regression Tests (C3, C4, C5, H2, H3, H4, H5, M2, L2)
# ===----------------------------------------------------------------------=== #


def test_c3_task_group_init_argument_validation() -> None:
    # Calling mojo_strata.TaskGroup() with no args must raise TypeError, not SIGSEGV
    with pytest.raises(TypeError):
        cast("Any", mojo_strata.TaskGroup)()

    # Passing both positional and keyword task must raise TypeError
    with pytest.raises(TypeError):
        cast("Any", mojo_strata.TaskGroup)(_inc, task=_double)

    # Extra positional arguments alongside keyword task must raise TypeError
    with pytest.raises(TypeError):
        cast("Any", mojo_strata.TaskGroup)(1, 2, task=_inc)

    # Unknown keyword argument must raise TypeError
    with pytest.raises(TypeError):
        cast("Any", mojo_strata.TaskGroup)(wrong=_inc)

    # Valid single positional or single keyword `task=` both work
    expected = 6
    assert mojo_strata.TaskGroup(_inc).call(5) == expected
    assert mojo_strata.TaskGroup(task=_inc).call(5) == expected


def test_c4_capsule_gc_during_active_exception_preserves_exception() -> None:
    def _raise_with_local_capsule() -> None:
        cap = mojo_strata.make_int_linear_capsule(3, 5)
        assert cap is not None
        msg = "active_exc_must_survive"
        raise RuntimeError(msg)

    with pytest.raises(RuntimeError, match="active_exc_must_survive"):
        _raise_with_local_capsule()

    # C-level error path decref'ing a temporary capsule while PyErr_Occurred() is set
    with pytest.raises(TypeError):
        int(cast("Any", mojo_strata.make_int_linear_capsule(2, 1)))


def test_c5_timeout_and_retry_nan_inf_validation() -> None:
    for bad_sec in (float("nan"), float("inf"), float("-inf"), 0.0, -0.5):
        with pytest.raises(ValueError, match="positive"):
            timeout(_inc, seconds=bad_sec)

    for bad_val in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(ValueError, match="backoff"):
            retry(_inc, backoff=bad_val)
        with pytest.raises(ValueError, match="backoff_multiplier"):
            retry(_inc, backoff_multiplier=bad_val)


def test_h2_stream_closes_generators_and_preserves_completed_items() -> None:
    # map_stage rejects negative max_in_flight
    with pytest.raises(ValueError, match="max_in_flight"):
        map_stage(_double, [1, 2, 3], max_in_flight=-1)

    # 1. Sync stream_stage closes upstream generator on early break/close
    for limit, ordered in ((1, True), (3, True), (3, False)):
        closed = False

        def _sync_src() -> Iterator[int]:
            nonlocal closed
            try:
                yield from range(100)
            finally:
                closed = True

        gen = _double.stream(_sync_src(), max_in_flight=limit, ordered=ordered)
        first = next(gen)
        assert isinstance(first, int)
        close_fn = getattr(gen, "close", None)
        assert callable(close_fn)
        close_fn()
        assert closed is True

    # 2. Sync stream_stage never drops completed items when upstream raises
    for limit, ordered in ((1, True), (3, True), (5, True), (3, False)):

        def _failing_src() -> Iterator[int]:
            yield 10
            yield 20
            yield 30
            msg = "upstream_sync_boom"
            raise RuntimeError(msg)

        collected: list[int] = []

        def _drain_sync(
            *,
            lim: int = limit,
            ord_flag: bool = ordered,
            sink: list[int] = collected,
        ) -> None:
            sink.extend(
                _double.stream(_failing_src(), max_in_flight=lim, ordered=ord_flag)
            )

        with pytest.raises(RuntimeError, match="upstream_sync_boom"):
            _drain_sync()
        assert sorted(collected) == [20, 40, 60]

    # 3. Early close does not block on slow in-flight worker threads
    @task
    def _slow_after_first(x: int) -> int:
        if x > 0:
            time.sleep(0.4)
        return x * 2

    max_unwind_s = 0.25
    gen_slow = _slow_after_first.stream(range(10), max_in_flight=3, ordered=True)
    assert next(gen_slow) == 0
    t0 = time.perf_counter()
    cast("Any", gen_slow).close()
    elapsed = time.perf_counter() - t0
    assert elapsed < max_unwind_s


def test_h2_astream_closes_upstream_generators() -> None:
    @async_task
    async def _a_double(x: int) -> int:
        await asyncio.sleep(0.001)
        return x * 2

    async def _run() -> None:
        for limit, ordered in ((1, True), (2, True), (2, False)):
            aclosed = False

            async def _async_src() -> AsyncIterator[int]:
                nonlocal aclosed
                try:
                    for i in range(100):
                        await asyncio.sleep(0.001)
                        yield i
                finally:
                    aclosed = True

            async with contextlib.aclosing(
                cast(
                    "Any",
                    _a_double.astream(
                        _async_src(), max_in_flight=limit, ordered=ordered
                    ),
                )
            ) as stream:
                async for _ in stream:
                    break
            assert aclosed is True

        sync_closed = False

        def _sync_src() -> Iterator[int]:
            nonlocal sync_closed
            try:
                yield from range(100)
            finally:
                sync_closed = True

        async with contextlib.aclosing(
            cast("Any", _a_double.astream(_sync_src(), max_in_flight=3, ordered=True))
        ) as stream:
            async for _ in stream:
                break
        assert sync_closed is True

    asyncio.run(_run())


def test_h2_astream_preserves_completed_items_on_upstream_error() -> None:
    @async_task
    async def _a_double(x: int) -> int:
        await asyncio.sleep(0.001)
        return x * 2

    async def _run() -> None:
        for limit, ordered in ((1, True), (3, True), (5, True), (3, False)):

            async def _failing_async_src() -> AsyncIterator[int]:
                for val in (10, 20, 30):
                    await asyncio.sleep(0)
                    yield val
                msg = "upstream_async_boom"
                raise RuntimeError(msg)

            collected: list[int] = []

            async def _drain_async(
                *,
                lim: int = limit,
                ord_flag: bool = ordered,
                sink: list[int] = collected,
            ) -> None:
                async for out in _a_double.astream(
                    _failing_async_src(), max_in_flight=lim, ordered=ord_flag
                ):
                    sink.append(out)  # ruff: ignore[manual-list-comprehension]

            with pytest.raises(RuntimeError, match="upstream_async_boom"):
                await _drain_async()
            assert sorted(collected) == [20, 40, 60]

    asyncio.run(_run())


def test_h3_native_bool_rejection_int64_overflow_and_mode_validation() -> None:
    lin = native_int_linear(scale=2, bias=1, name="strict_int")
    flin = native_float_linear(scale=2.0, bias=1.0, name="strict_float")
    flag_true = True
    flag_false = False

    # bool must be rejected as input to native int/float stages
    with pytest.raises(TypeError):
        lin(flag_true)
    with pytest.raises(TypeError):
        lin(flag_false)
    with pytest.raises(TypeError):
        flin(flag_true)

    # bool must also be rejected when constructing native_int_linear / capsule
    with pytest.raises(TypeError):
        mojo_strata.native_int_linear(flag_true, 0, "bad")
    with pytest.raises(TypeError):
        mojo_strata.make_int_linear_capsule(flag_true, 0)

    # Int64 arithmetic overflow must raise OverflowError, not silently wrap around
    big_val = 1 << 62
    with pytest.raises(OverflowError):
        native_int_linear(scale=2, bias=0, name="ovf")(big_val)
    with pytest.raises(OverflowError):
        native_stage(mojo_strata.make_int_linear_capsule(2, 0))(big_val)

    # TaskGroup.with_task must reject invalid _mode values and booleans
    raw_tg = mojo_strata.TaskGroup(_inc)
    with pytest.raises(ValueError, match="mode"):
        raw_tg.with_task(_double, cast("Any", 99))
    with pytest.raises((TypeError, ValueError)):
        raw_tg.with_task(_double, cast("Any", flag_true))


def test_h4_raw_native_stage_and_pycapsule_in_combinators_and_executors() -> None:
    raw_ns = mojo_strata.native_int_linear(3, 1, "raw_ns")
    raw_cap = mojo_strata.make_int_linear_capsule(4, 2)

    class _Provider:
        scale: int = 5
        bias: int = 1

        def as_native_capsule(self) -> object:
            return mojo_strata.make_int_linear_capsule(self.scale, self.bias)

    provider = _Provider()

    expected_ns = 16
    expected_cap = 22
    expected_prov = 26

    # Raw NativeStage is directly callable and works in all combinators & executors
    assert raw_ns(5) == expected_ns
    assert group(raw_ns)(5) == expected_ns
    assert retry(raw_ns, max_attempts=2)(5) == expected_ns
    assert fallback(raw_ns, _inc)(5) == expected_ns
    assert timeout(raw_ns, seconds=1.0)(5) == expected_ns
    assert branch(lambda x: x > 0, raw_ns, _inc)(5) == expected_ns
    assert map_task(raw_ns)([1, 2, 3]) == [4, 7, 10]
    assert zip_tasks(raw_ns, _double)((5, 3)) == (16, 6)
    assert SequentialExecutor().run(raw_ns, 5) == expected_ns
    assert TracingExecutor(sequential=True).run(raw_ns, 5) == expected_ns
    assert TracingExecutor(sequential=False).run(raw_ns, 5) == expected_ns
    assert asyncio.run(arun(raw_ns, 5)) == expected_ns

    # Raw PyCapsule works in combinators, TaskGroup, Sequential/TracingExecutor, arun
    cap_any = cast("Any", raw_cap)
    assert group(cap_any)(5) == expected_cap
    assert retry(cap_any)(5) == expected_cap
    assert map_task(cap_any)([1, 2]) == [6, 10]
    assert SequentialExecutor().run(TaskGroup(cap_any), 5) == expected_cap
    assert TracingExecutor(sequential=True).run(TaskGroup(cap_any), 5) == expected_cap
    assert TracingExecutor(sequential=False).run(TaskGroup(cap_any), 5) == expected_cap
    assert asyncio.run(arun(cap_any, 5)) == expected_cap

    # NativeCapsuleProvider works directly in executors & arun
    prov_any = cast("Any", provider)
    assert SequentialExecutor().run(prov_any, 5) == expected_prov
    assert TracingExecutor(sequential=True).run(prov_any, 5) == expected_prov
    assert asyncio.run(arun(prov_any, 5)) == expected_prov


def test_h4_sequential_executor_traverses_map_and_branch() -> None:
    caller_tid = threading.get_ident()
    seen_tids: list[int] = []
    intervals: list[tuple[int, int]] = []

    @task
    def _rec_a(x: int) -> int:
        seen_tids.append(threading.get_ident())
        s = time.perf_counter_ns()
        time.sleep(0.01)
        e = time.perf_counter_ns()
        intervals.append((s, e))
        return x + 1

    @task
    def _rec_b(x: int) -> int:
        seen_tids.append(threading.get_ident())
        s = time.perf_counter_ns()
        time.sleep(0.01)
        e = time.perf_counter_ns()
        intervals.append((s, e))
        return x * 2

    # SequentialExecutor inside map_task(a & b) runs 100% on caller thread, no overlap
    seq = SequentialExecutor()
    m_pipe = map_task(_rec_a & _rec_b)
    assert seq.run(m_pipe, [3, 4]) == [(4, 6), (5, 8)]
    assert set(seen_tids) == {caller_tid}
    for i in range(len(intervals) - 1):
        assert intervals[i][1] <= intervals[i + 1][0]

    # SequentialExecutor inside branch(p, a & b, c) also runs strictly sequentially
    seen_tids.clear()
    intervals.clear()
    br_pipe = branch(lambda x: x > 0, _rec_a & _rec_b, _inc & _double)
    assert seq.run(br_pipe, 5) == (6, 10)
    assert set(seen_tids) == {caller_tid}
    assert intervals[0][1] <= intervals[1][0]


def test_h4_tracing_stats_and_diagrams_traverse_combinators() -> None:
    # TracingExecutor traces leaf stages inside composite combinators (seq & par)
    for is_seq in (True, False):
        tracer = TracingExecutor(sequential=is_seq)
        res = tracer.run(
            retry(fallback(_inc & _double, _triple & _quad), max_attempts=2),
            5,
        )
        assert res == (6, 10)
        names = {s.stage for s in tracer.spans}
        assert {"_inc", "_double"} <= names

        tracer.clear()
        assert tracer.run(map_task(_inc & _double), [1, 2]) == [(2, 2), (3, 4)]
        expected_map_spans = 4
        assert len(tracer.spans) == expected_map_spans

    # graph_stats & diagrams traverse all composite combinators
    composite = branch(
        lambda x: x > 0,
        retry(_inc | _double, max_attempts=2),
        fallback(_triple, _quad),
    )
    stats = graph_stats(composite)
    expected_stages = 4
    expected_depth = 2
    assert stats.stage_count == expected_stages
    assert stats.max_parallel_width == 1
    assert stats.critical_depth == expected_depth

    mmd = to_mermaid(composite)
    dot = to_dot(composite)
    assert "branch" in mmd
    assert "retry" in mmd
    assert "fallback" in mmd
    assert "_inc" in mmd
    assert "_quad" in mmd
    assert "branch" in dot
    assert "retry" in dot
    assert "fallback" in dot


def test_h5_zip_length_validation_and_combinator_subclasses() -> None:
    z = zip_tasks(_inc, _double)

    # Extra elements raise ValueError instead of silently truncating
    with pytest.raises(ValueError, match="expected 2 elements, got 4"):
        cast("Any", z)((10, 20, 999, 888))

    # Too few elements raise ValueError
    with pytest.raises(ValueError, match="expected 2 elements, got 1"):
        cast("Any", z)((10,))

    # SequentialExecutor & TracingExecutor enforce the same validation
    with pytest.raises(ValueError, match="expected 2 elements, got 3"):
        SequentialExecutor().run(z, (1, 2, 3))
    with pytest.raises(ValueError, match="expected 2 elements, got 1"):
        TracingExecutor(sequential=True).run(z, (1,))

    # arun validates length BEFORE creating coroutines (zero unawaited RuntimeWarning!)
    @async_task
    async def _a_inc(x: int) -> int:
        await asyncio.sleep(0)
        return x + 1

    z_async = zip_tasks(_a_inc, _a_inc, _a_inc)
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always", RuntimeWarning)
        with pytest.raises(ValueError, match="expected 3 elements, got 1"):
            asyncio.run(arun(z_async, (1,)))
        with pytest.raises(ValueError, match="expected 3 elements, got 4"):
            asyncio.run(arun(z_async, (1, 2, 3, 4)))
    unawaited = [w for w in caught if "was never awaited" in str(w.message)]
    assert unawaited == []

    # Subclasses of combinators work in arun, introspect, and executors
    class _SubMap[I, O](MapTask[I, O]):
        pass

    class _SubBranch[I, O](BranchTask[I, O]):
        pass

    class _SubRetry[I, O](RetryTask[I, O]):
        pass

    sub_pipe = _SubMap(_SubBranch(lambda x: x % 2 == 0, _SubRetry(_a_inc), _double))
    assert asyncio.run(arun(sub_pipe, [2, 3, 4])) == [3, 6, 5]
    assert SequentialExecutor().run(sub_pipe, [2, 3, 4]) == [3, 6, 5]
    assert graph_stats(sub_pipe).stage_count == 2  # ruff: ignore[magic-value-comparison]
    assert "branch" in to_mermaid(sub_pipe)


def test_m2_select_typing_and_l2_diagram_escaping() -> None:
    @task
    def _to_str(x: int) -> str:
        return f"v={x}"

    pick_str = (_inc & _to_str) | select(1)
    picked: str = pick_str(5)
    assert picked == "v=5"
    assert isinstance(select(0), SelectTask)
    assert isinstance(select(1), SelectTask)

    # L2: Backslash, double quote, newline, and right bracket escaping
    def _tricky(x: int) -> int:
        return x

    _tricky.__name__ = 'a\\b "c"\nline2]end'
    tricky_task = task(_tricky)

    mmd = to_mermaid(tricky_task)
    assert r"a\\b &quot;c&quot;\nline2&#93;end" in mmd
    assert "\nline2" not in mmd

    dot = to_dot(tricky_task, name='My "Graph"\n1')
    assert r"a\\b \"c\"\nline2]end" in dot
    assert r'digraph "My \"Graph\"\n1" {' in dot

    with pytest.raises(ValueError, match="Unsupported diagram direction"):
        to_mermaid(_inc, direction="LR; evil")
    with pytest.raises(ValueError, match="Unsupported diagram direction"):
        to_dot(_inc, direction="LR; evil")
    with pytest.raises(ValueError, match="non-empty"):
        to_dot(_inc, name="   ")


# ===----------------------------------------------------------------------=== #
# 9. Wave 2 Performance & Safety Invariant Tests
# ===----------------------------------------------------------------------=== #


def test_wave2_arun_subtree_batching_preserves_nested_async_loop() -> None:
    async def _run() -> None:
        main_loop = asyncio.get_running_loop()
        observed_loops: list[asyncio.AbstractEventLoop] = []

        @async_task
        async def _a_check_loop(x: int) -> int:
            observed_loops.append(asyncio.get_running_loop())
            await asyncio.sleep(0)
            return x + 1

        # Pure-sync/native TaskGroup subtree runs cleanly in arun
        native_chain = native_int_linear(scale=2, bias=1) | native_int_linear(
            scale=3, bias=-2
        )
        expected_native = 31
        assert await arun(native_chain, 5) == expected_native

        # Nested AsyncTask inside branch/fallback/retry/timeout/group inside a
        # TaskGroup MUST still execute on the caller's exact event loop!
        nested_branch = _inc | branch(lambda x: x > 0, _a_check_loop, _double)
        nested_fallback = _inc | fallback(_a_check_loop, _double)
        nested_retry = _inc | retry(_a_check_loop, max_attempts=2)
        nested_timeout = _inc | timeout(_a_check_loop, seconds=1.0)
        nested_group = _inc | group(_a_check_loop & _double)

        expected_seven = 7
        assert await arun(nested_branch, 5) == expected_seven
        assert await arun(nested_fallback, 5) == expected_seven
        assert await arun(nested_retry, 5) == expected_seven
        assert await arun(nested_timeout, 5) == expected_seven
        assert await arun(nested_group, 5) == (7, 12)
        assert observed_loops
        assert all(lp is main_loop for lp in observed_loops)

    asyncio.run(_run())


def test_wave2_tracing_executor_per_instance_cache_isolation() -> None:
    pipe = _inc | (_double & _triple) | zip_tasks(_inc, _add_ten)
    t1 = TracingExecutor(sequential=False)
    t2 = TracingExecutor(sequential=False)

    assert t1.run(pipe, 4) == (11, 25)
    assert t2.run(pipe, 5) == (13, 28)

    expected_spans = 5
    assert len(t1.spans) == expected_spans
    assert len(t2.spans) == expected_spans

    # Repeated cached runs only append to the invoking executor
    assert t1.run(pipe, 6) == (15, 31)
    assert len(t1.spans) == expected_spans * 2
    assert len(t2.spans) == expected_spans

    t1.clear()
    assert t1.spans == []
    assert t1.run(pipe, 2) == (7, 19)
    assert len(t1.spans) == expected_spans


def test_wave2_timeout_pool_reuse_and_no_deadlock_in_stream_and_map() -> None:
    guarded = timeout(_double, seconds=1.0)
    nested_guarded = timeout(timeout(_inc, seconds=1.0), seconds=2.0)

    expected_nested = 11
    assert nested_guarded(10) == expected_nested

    # Running TimeoutTask concurrently inside stream/map must never deadlock
    items = list(range(16))
    assert guarded.map(items, max_in_flight=8) == [x * 2 for x in items]
    assert list(guarded.stream(items, max_in_flight=8)) == [x * 2 for x in items]
    assert map_stage(nested_guarded, [5], max_in_flight=4) == [6]
    assert map_stage(nested_guarded, [], max_in_flight=4) == []


def test_wave2_from_tasks_is_pure_native_and_map_list() -> None:
    n1 = native_int_linear(scale=2, bias=1, name="n1")
    n2 = native_int_linear(scale=3, bias=-2, name="n2")
    n_chain = n1 | n2
    n_par = n1 & n2
    py_chain = _inc | _double
    hybrid_chain = n1 | _inc

    # is_pure_native checks
    assert n_chain.inner.is_pure_native() is True
    assert n_par.inner.is_pure_native() is False
    assert py_chain.inner.is_pure_native() is False
    assert hybrid_chain.inner.is_pure_native() is False

    # TaskGroup.from_tasks serial & parallel + validation
    tg_ser = mojo_strata.TaskGroup.from_tasks([_inc, _double, _triple], 0)
    expected_ser = 36
    assert tg_ser.call(5) == expected_ser
    tg_par = mojo_strata.TaskGroup.from_tasks([_inc, _double, _triple], 1)
    assert tg_par.call(5) == (6, 10, 15)

    flag_true = True
    with pytest.raises(ValueError, match="at least one task"):
        mojo_strata.TaskGroup.from_tasks([], 0)
    with pytest.raises(ValueError, match="mode"):
        mojo_strata.TaskGroup.from_tasks([_inc], 99)
    with pytest.raises(TypeError):
        mojo_strata.TaskGroup.from_tasks([_inc], flag_true)

    # GIL-free NativeStage.map_list and TaskGroup.map_list
    xs = list(range(32))
    expected_n1 = [x * 2 + 1 for x in xs]
    expected_chain = [(x * 2 + 1) * 3 - 2 for x in xs]

    raw_ns = mojo_strata.native_int_linear(2, 1, "raw_n1")
    assert raw_ns.map_list(xs, 0) == expected_n1
    assert raw_ns.map_list(xs, 1) == expected_n1
    assert raw_ns.map_list(xs, 4) == expected_n1
    assert raw_ns.map_list([], 4) == []

    assert n_chain.inner.map_list(xs, 0) == expected_chain
    assert n_chain.inner.map_list(xs, 4) == expected_chain
    assert map_task(n_chain, max_concurrency=4)(xs) == expected_chain
    assert map_stage(n_chain, xs, max_in_flight=4) == expected_chain
    assert map_task(n1, max_concurrency=4)(xs) == expected_n1
    assert map_stage(n1, xs, max_in_flight=4) == expected_n1

    # map_list validation errors
    with pytest.raises(ValueError, match="max_concurrency"):
        raw_ns.map_list(xs, -1)
    with pytest.raises(TypeError):
        raw_ns.map_list(xs, flag_true)
    with pytest.raises(TypeError):
        py_chain.inner.map_list(xs, 4)
    with pytest.raises(TypeError):
        n_par.inner.map_list(xs, 4)
    with pytest.raises(TypeError):
        raw_ns.map_list(cast("Any", [1, "bad", 3]), 4)
