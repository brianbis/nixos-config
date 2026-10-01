#!/usr/bin/env python3
"""
Lifecycle wrapper for ninfer-serve (child-process backend).

See idle_wrapper.py for the shared machinery (the idle window, the activity
file the gate stamps, the clean exit-0, the health probe). This file supplies
the child-process lifecycle:

  - The ninfer-serve child is spawned when the gate starts the unit and
    terminated when the idle window expires, which is what releases the VRAM.
  - The gate heartbeats --activity-file while a request is in flight, so a
    long streaming response keeps the model loaded for the whole generation;
    the wrapper never sees the request itself.
"""

from __future__ import annotations

import argparse
import asyncio
import time

from idle_wrapper import (
    Backend,
    State,
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
# Backend
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


BACKEND = Backend(
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
    add_args=add_args,
    validate=validate,
)


if __name__ == "__main__":
    raise SystemExit(main(BACKEND))
