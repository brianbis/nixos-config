#!/usr/bin/env python3
"""
Socket-activated idle wrapper for a native child-process model server
(sglang). See idle_wrapper.py for the shared machinery (socket activation,
transparent TCP relay, forced Connection: close, local /health, clean
exit-0).

This is the same child-process lifecycle as the NInfer backend (spawn on the
first request, terminate after the idle window), minus the NInfer-specific
JSONL request log. In-flight tracking uses two signals instead:

  - the relay/connection state the shared machinery already maintains (a
    live relay keeps the model loaded);
  - a poll of the child's own load metrics: while the child reports running
    or queued requests (vLLM / SGLang Prometheus /metrics), a sentinel is
    held in state.in_flight, so the idle monitor never unloads a busy child
    even when the client-side relay has already dropped (a disconnected
    client, a proxy holding the response).

Once the last connection closes, the child reports no in-flight work, and
the idle window expires, the child is terminated and the wrapper exits 0,
releasing the model's VRAM.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib

from idle_wrapper import Backend, State, main
from ninfer_wrapper import (
    DEFAULT_IDLE_SECONDS,
    DEFAULT_KILL_TIMEOUT,
    DEFAULT_READY_TIMEOUT,
    child_idle_monitor,
    ensure_child,
    stop,
)

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def add_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "child_command",
        nargs=argparse.REMAINDER,
    )


def validate(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    if args.child_command and args.child_command[0] == "--":
        args.child_command = args.child_command[1:]

    if not args.child_command:
        parser.error("missing child command after --")


# ---------------------------------------------------------------------------
# Child load polling (in-flight pinning)
# ---------------------------------------------------------------------------

# How often to poll the child's load metrics. The child stays pinned for at
# most this long after its last request actually finishes.
_LOAD_POLL_SECONDS = 2.0

# How long to wait for the child's /metrics reply.
_LOAD_TIMEOUT_SECONDS = 5.0

# Sentinel held in state.in_flight while the child reports work in flight.
_LOAD_SENTINEL = ("child-metrics", "in-flight")

# Metric names that mean "the child is servicing a request right now"
# (running or queued). vLLM and SGLang both expose Prometheus /metrics; any
# non-zero value pins the child.
_LOAD_METRIC_NAMES = (
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "sglang:num_running_requests",
    "sglang:num_queue_reqs",
)


def _parse_load(body: str) -> int:
    """Sum the in-flight request counters out of a Prometheus /metrics body."""
    total = 0

    for line in body.splitlines():
        if line.startswith("#"):
            continue

        name = line.split("{", 1)[0].strip()

        if name not in _LOAD_METRIC_NAMES:
            continue

        parts = line.split()

        # The value is the last field (these servers emit no timestamps).
        if len(parts) < 2:
            continue

        try:
            total += float(parts[-1])
        except ValueError:
            pass

    return total


async def _child_reports_load(state: State) -> bool:
    """
    Poll the child's /metrics and report whether it has requests running or
    queued.

    Any failure (child down, no /metrics route, timeout) reports False: the
    relay/connection state remains the fallback in-flight signal.
    """

    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", state.args.child_port),
            timeout=_LOAD_TIMEOUT_SECONDS,
        )
    except (OSError, asyncio.TimeoutError):
        return False

    try:
        writer.write(
            b"GET /metrics HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Connection: close\r\n"
            b"\r\n",
        )
        await writer.drain()

        # Connection: close, so the reply ends at EOF.
        body = await asyncio.wait_for(
            reader.read(-1),
            timeout=_LOAD_TIMEOUT_SECONDS,
        )
    except (OSError, asyncio.TimeoutError):
        return False
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()

    head, sep, body = body.partition(b"\r\n\r\n")

    if not sep:
        return False

    # Status line is "HTTP/1.1 <code> <reason>"; a 404 (no /metrics route)
    # or any non-200 means no load signal.
    status = head.split(b"\r\n", 1)[0].split(b" ", 2)

    if len(status) < 2 or status[1] != b"200":
        return False

    return _parse_load(body.decode("utf-8", "replace")) > 0


async def child_load_monitor(state: State) -> None:
    """
    Poll the child's load metrics and pin it while it has work in flight.

    The relay state only reflects the wrapper's own TCP relays: a client
    that disconnects mid-generation drops the relay while the model keeps
    generating. The child's own metrics are authoritative for its work, so
    hold a sentinel in state.in_flight (which the idle monitor treats as an
    in-flight request) for as long as the child reports running or queued
    requests.
    """

    while not state.stopping:
        await asyncio.sleep(_LOAD_POLL_SECONDS)

        if state.stopping:
            return

        child = state.child

        if child is None or not state.child_ready or child.returncode is not None:
            state.in_flight.discard(_LOAD_SENTINEL)
            continue

        if await _child_reports_load(state):
            state.in_flight.add(_LOAD_SENTINEL)
        else:
            state.in_flight.discard(_LOAD_SENTINEL)


def extra_tasks(state: State) -> list:
    # No request-log tailer: idle detection is connection/relay based, plus
    # the child's own load metrics (a busy child stays pinned even when the
    # client-side relay has dropped).
    return [
        asyncio.create_task(
            child_load_monitor(state),
            name="child-load-poller",
        )
    ]


BACKEND = Backend(
    noun="child",
    log_prefix="sglang-wrapper",
    default_idle_seconds=DEFAULT_IDLE_SECONDS,
    default_ready_timeout=DEFAULT_READY_TIMEOUT,
    default_kill_timeout=DEFAULT_KILL_TIMEOUT,
    default_child_port=8087,
    ensure=ensure_child,
    is_ready=lambda s: (
        s.child is not None and s.child_ready and s.child.returncode is None
    ),
    stop=stop,
    idle_monitor=child_idle_monitor,
    extra_tasks=extra_tasks,
    add_args=add_args,
    validate=validate,
)


if __name__ == "__main__":
    raise SystemExit(main(BACKEND))
