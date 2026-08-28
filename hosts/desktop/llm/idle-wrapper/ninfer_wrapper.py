#!/usr/bin/env python3
"""
Socket-activated idle wrapper for ninfer-serve (child-process backend).

See idle_wrapper.py for the shared machinery (socket activation, transparent
TCP relay, forced Connection: close, local /health, clean exit-0). This file
supplies the child-process lifecycle:

  - The ninfer-serve child is spawned on the first request and terminated
    after the idle window.
  - ninfer-serve emits a JSONL request log; the in-flight request set is
    read from it (the request log, not connection state, is authoritative),
    so a long streaming response keeps the model loaded even while the
    relay is quiet.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import time

from idle_wrapper import (
    Backend,
    State,
    close_connections,
    log,
    main,
    probe_health,
)

DEFAULT_IDLE_SECONDS = 60
DEFAULT_READY_TIMEOUT = 30 * 60
DEFAULT_KILL_TIMEOUT = 10
DEFAULT_CHILD_PORT = 8081


# ---------------------------------------------------------------------------
# Child lifecycle
# ---------------------------------------------------------------------------


async def terminate_process(
    process: asyncio.subprocess.Process,
    *,
    terminate_timeout: float,
    kill_timeout: float,
) -> None:
    """
    Terminate a child without blocking the event loop.
    """

    if process.returncode is not None:
        return

    log.info("sending SIGTERM to child pid=%d", process.pid)

    try:
        process.terminate()
    except ProcessLookupError:
        return

    try:
        await asyncio.wait_for(
            process.wait(),
            timeout=terminate_timeout,
        )
        return

    except asyncio.TimeoutError:
        log.warning(
            "child pid=%d did not exit after %.1fs; killing",
            process.pid,
            terminate_timeout,
        )

    try:
        process.kill()
    except ProcessLookupError:
        return

    try:
        await asyncio.wait_for(
            process.wait(),
            timeout=kill_timeout,
        )
    except asyncio.TimeoutError:
        log.error(
            "child pid=%d did not exit after SIGKILL",
            process.pid,
        )


async def start_child(state: State) -> None:
    """
    Spawn the child and wait for it to become healthy.

    The lifecycle lock must be held by the caller; it is held for the whole
    startup wait, so concurrent handlers simply block on the lock until
    readiness.
    """

    args = state.args

    # Clean up a crashed-but-not-reaped previous child, if any.
    if state.child is not None:
        if state.child.returncode is None:
            await terminate_process(
                state.child,
                terminate_timeout=args.shutdown_timeout,
                kill_timeout=args.kill_timeout,
            )
        state.child = None
        state.child_ready = False

    log.info(
        "starting child: %s",
        " ".join(args.child_command),
    )

    started_at = time.monotonic()

    try:
        process = await asyncio.create_subprocess_exec(*args.child_command)
    except OSError:
        log.exception("failed to spawn child")
        raise

    state.child = process

    try:
        deadline = started_at + args.ready_timeout

        while not state.stopping:
            if process.returncode is not None:
                raise RuntimeError(
                    f"child exited during startup with rc={process.returncode}"
                )

            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"child did not become ready within " f"{args.ready_timeout:.0f}s"
                )

            if await probe_health(args.child_port):
                state.child_ready = True

                log.info(
                    "child pid=%d ready in %.1fs",
                    process.pid,
                    time.monotonic() - started_at,
                )

                return

            await asyncio.sleep(1)

    except BaseException:
        # We own this child if it was successfully spawned.
        if process.returncode is None:
            await terminate_process(
                process,
                terminate_timeout=args.shutdown_timeout,
                kill_timeout=args.kill_timeout,
            )

        state.child = None
        state.child_ready = False
        raise

    # Reached only when state.stopping became true: the shutdown path owns
    # the child from here on.


async def ensure_child(state: State) -> None:
    """
    Ensure a ready child exists.

    All callers may enter concurrently, but only one startup happens: the
    lock is held for the whole startup wait.
    """

    async with state.lifecycle_lock:
        if state.stopping:
            raise RuntimeError("wrapper is shutting down")

        if (
            state.child is not None
            and state.child_ready
            and state.child.returncode is None
        ):
            return

        if state.child is not None and state.child.returncode is None:
            # Defensive: a live child that is not ready should not exist while
            # we hold this lock (start_child reaps failed startups); wait for
            # it to settle rather than spawning a second child.
            deadline = time.monotonic() + state.args.ready_timeout
            while (
                state.child is not None
                and state.child.returncode is None
                and not state.child_ready
            ):
                if time.monotonic() >= deadline:
                    raise TimeoutError("child did not become ready")
                await asyncio.sleep(0.5)
            if state.child_ready:
                return
            # The startup failed; fall through and retry with a new child.

        await start_child(state)


# ---------------------------------------------------------------------------
# Request log
# ---------------------------------------------------------------------------


def process_event(
    state: State,
    record: dict,
) -> None:
    event = record.get("event")
    instance_id = record.get("server_instance_id")
    request_id = record.get("request_id")

    if event == "server_start":
        # A new server instance invalidates all prior request state.
        state.instance_id = instance_id
        state.in_flight.clear()
        return

    if instance_id != state.instance_id:
        return

    if request_id is None:
        return

    key = (instance_id, request_id)

    if event == "request_start":
        state.in_flight.add(key)

    elif event in (
        "request_done",
        "request_error",
        "request_rejected",
    ):
        state.in_flight.discard(key)


async def tail_request_log(
    state: State,
) -> None:
    """
    Tail JSONL request events.

    If the log disappears or is replaced, reopen it. We deliberately do not
    infer "zero in-flight requests" from a missing log.
    """

    path = state.args.request_log

    fh = None
    inode = None
    buffer = b""

    try:
        while not state.stopping:
            try:
                if fh is None:
                    fh = open(path, "rb")
                    inode = os.fstat(fh.fileno()).st_ino
                    buffer = b""
                    # Start at the end: events written before this wrapper
                    # started belong to a previous instance.
                    fh.seek(0, os.SEEK_END)

                stat = os.stat(path)

                if inode != stat.st_ino:
                    fh.close()
                    fh = None
                    inode = None
                    buffer = b""
                    continue

                if fh.tell() > stat.st_size:
                    fh.seek(0)
                    buffer = b""

                chunk = fh.read()

                if chunk:
                    buffer += chunk

                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        line = line.strip()

                        if not line:
                            continue

                        try:
                            record = json.loads(line)
                        except (ValueError, TypeError):
                            continue

                        if isinstance(record, dict):
                            process_event(state, record)

                else:
                    await asyncio.sleep(0.2)

            except FileNotFoundError:
                # Important: don't clear in_flight here.
                await asyncio.sleep(0.5)

            except OSError:
                if fh is not None:
                    with contextlib.suppress(OSError):
                        fh.close()

                fh = None
                inode = None
                buffer = b""

                await asyncio.sleep(0.5)

    finally:
        if fh is not None:
            with contextlib.suppress(OSError):
                fh.close()


# ---------------------------------------------------------------------------
# Idle monitor
# ---------------------------------------------------------------------------


async def child_idle_monitor(
    state: State,
    stop_event: asyncio.Event,
) -> None:
    """
    Poll once per second:

      - child crashed or failed startup -> stop the service (exit 0); the
        next connection re-activates it and retries the load lazily
      - no child and nothing in flight -> stop the service (exit 0); the
        wrapper has nothing to do
      - child idle (no in-flight, no live relays, no recent client
        activity) -> terminate the child and stop the service (exit 0)
    """

    while not state.stopping:
        await asyncio.sleep(1)

        child = state.child

        if child is not None and child.returncode is not None:
            log.error(
                "child pid=%d exited rc=%s; stopping service",
                child.pid,
                child.returncode,
            )

            close_connections(state)

            stop_event.set()
            return

        if child is None:
            if not state.connections and state.active_handlers == 0:
                log.info("nothing to do; stopping service")
                stop_event.set()
                return
            continue

        if not state.child_ready:
            continue

        if state.in_flight:
            continue
        if state.active_handlers:
            continue
        # A live relay means the child is servicing a client, even if there
        # has been no socket activity for a long time.
        if state.connections:
            continue

        idle = time.monotonic() - state.last_activity

        if idle < state.args.idle_seconds:
            continue

        log.info(
            "idle for %.1fs (timeout %.1fs); unloading child and stopping",
            idle,
            state.args.idle_seconds,
        )

        state.stopping = True

        async with state.lifecycle_lock:
            if state.child is child:
                await terminate_process(
                    child,
                    terminate_timeout=state.args.shutdown_timeout,
                    kill_timeout=state.args.kill_timeout,
                )

                state.child = None
                state.child_ready = False
                state.instance_id = None
                state.in_flight.clear()

        stop_event.set()
        return


# ---------------------------------------------------------------------------
# Backend
# ---------------------------------------------------------------------------


def add_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--request-log",
        required=True,
    )

    parser.add_argument(
        "child_command",
        nargs=argparse.REMAINDER,
    )


def validate(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    if args.child_command and args.child_command[0] == "--":
        args.child_command = args.child_command[1:]

    if not args.child_command:
        parser.error("missing child command after --")


def extra_tasks(state: State) -> list[asyncio.Task]:
    return [
        asyncio.create_task(
            tail_request_log(state),
            name="request-log-tailer",
        )
    ]


async def stop(state: State) -> None:
    """Stop the child. Called under the lifecycle lock."""
    if state.child is not None:
        await terminate_process(
            state.child,
            terminate_timeout=state.args.shutdown_timeout,
            kill_timeout=state.args.kill_timeout,
        )

    state.child = None
    state.child_ready = False
    state.instance_id = None
    state.in_flight.clear()


BACKEND = Backend(
    noun="child",
    log_prefix="ninfer-wrapper",
    default_idle_seconds=DEFAULT_IDLE_SECONDS,
    default_ready_timeout=DEFAULT_READY_TIMEOUT,
    default_kill_timeout=DEFAULT_KILL_TIMEOUT,
    default_child_port=DEFAULT_CHILD_PORT,
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
