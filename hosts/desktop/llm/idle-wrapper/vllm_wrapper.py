#!/usr/bin/env python3
"""
Socket-activated idle wrapper for a docker-based vLLM container.

See idle_wrapper.py for the shared machinery (socket activation, transparent
TCP relay, forced Connection: close, local /health, clean exit-0). This file
supplies the docker-container lifecycle:

  - The "child" is a docker container managed by a NixOS oci-containers
    systemd service (named `docker-<container>`).
  - start runs `systemctl start docker-<container>` (which `docker run`s the
    container) and then polls /health on the child port until ready. vLLM
    warmup is slow (model load + CUDA/FlashInfer), so the ready timeout is
    long. Before the start it clears a stuck `failed` / `start-limit-hit`
    state on the unit (`systemctl reset-failed`), so a prior crash-loop does
    not wedge the service and force a manual restart.
  - stop runs `systemctl stop docker-<container>`, then verifies the
    container is actually stopped via `docker inspect`; if it is still
    running it falls back to `docker stop` / `docker kill` to guarantee
    VRAM release.

vLLM emits no request-log-jsonl, so the idle signal is the set of live
relays + active handlers + recent client socket activity (the wrapper relays
every request and forces the child to close, so a completed request drops its
relay).
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import time

from idle_wrapper import (
    Backend,
    State,
    close_connections,
    log,
    main,
    probe_health,
)

DEFAULT_IDLE_SECONDS = 300.0
DEFAULT_READY_TIMEOUT = 60 * 60
DEFAULT_KILL_TIMEOUT = 30
DEFAULT_CHILD_PORT = 18090

# How often to poll /health while waiting for the container to become ready.
READY_POLL_INTERVAL = 2.0


# ---------------------------------------------------------------------------
# Command / container helpers
# ---------------------------------------------------------------------------


async def run_cmd(cmd: list[str], timeout: float) -> tuple[int, str]:
    """
    Run a command in a subprocess and return (exit_code, stdout).

    Returns (-1, "") on timeout or spawn failure. Never blocks the event loop.
    """

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError:
        log.exception("failed to spawn %s", cmd)
        return -1, ""

    try:
        out, _err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return (proc.returncode if proc.returncode is not None else -1), out.decode(
            errors="replace"
        )
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        with contextlib.suppress(Exception):
            await proc.wait()
        return -1, ""


async def container_status(name: str) -> str:
    """Return the docker container's State.Status, or 'not-found'."""
    rc, out = await run_cmd(
        ["docker", "inspect", "-f", "{{.State.Status}}", name],
        timeout=10,
    )
    return out.strip() if rc == 0 else "not-found"


# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------


async def ensure_image(state: State) -> None:
    """
    Ensure the container's image is present, pulling it (one-time) if not.

    The image is a pinned GHCR digest pulled by the switch (activation
    script); this is a safety net for the case where it is ever missing at
    request time (a re-pin, or a fresh boot). The pull is bounded by
    --pull-timeout. Called while holding the lifecycle lock, so concurrent
    handlers block on the single pull.
    """

    args = state.args

    rc, _out = await run_cmd(["docker", "image", "inspect", args.image], timeout=10)
    if rc == 0:
        return

    log.info(
        "image %s not present; pulling (one-time, may take a while)",
        args.image,
    )

    rc, out = await run_cmd(["docker", "pull", args.image], timeout=args.pull_timeout)
    if rc != 0:
        raise RuntimeError(f"docker pull {args.image} failed rc={rc}: {out[-2000:]}")

    rc, _out = await run_cmd(["docker", "image", "inspect", args.image], timeout=10)
    if rc != 0:
        raise RuntimeError(f"image {args.image} not present after pull")

    log.info("image %s ready", args.image)


async def start_container(state: State) -> None:
    """
    Start the container service and wait for it to become healthy.

    The lifecycle lock must be held by the caller; it is held for the whole
    startup wait, so concurrent handlers simply block on the lock until
    readiness.
    """

    args = state.args

    # Clean up a previous container that is up but not ready.
    if state.container_up:
        await stop_container(state)
        state.container_up = False
        state.container_ready = False

    log.info(
        "starting container service: %s (container %s)",
        args.container_service,
        args.container,
    )

    # Ensure a clean start: stop the service (if running) and remove any
    # existing container, so the NixOS service's `docker run` creates a fresh
    # container (a `docker run` whose name is already in use would fail). Both
    # are no-ops (harmless failures) when nothing is running.
    await run_cmd(
        ["systemctl", "stop", args.container_service],
        timeout=args.shutdown_timeout,
    )
    await run_cmd(
        ["docker", "rm", "-f", args.container],
        timeout=args.kill_timeout,
    )

    # Clear a stuck `failed` / `start-limit-hit` state on the service. After a
    # crash-loop (e.g. the pre-fix EACCES / unauthorized tight restart loop) the
    # unit can be left in a `failed` state that refuses `systemctl start` until
    # the start-limit accounting is reset. `reset-failed` is a no-op when the
    # unit is healthy, so this self-heals without a manual intervention.
    await run_cmd(
        ["systemctl", "reset-failed", args.container_service],
        timeout=10,
    )

    # Ensure the image is pulled (one-time, ~20 GB the first request); the
    # container cannot start without it. Holds the lifecycle lock, so
    # concurrent handlers block on the single pull.
    await ensure_image(state)

    started_at = time.monotonic()

    rc, _out = await run_cmd(
        ["systemctl", "start", args.container_service],
        timeout=60,
    )

    if rc != 0:
        raise RuntimeError(f"systemctl start {args.container_service} failed rc={rc}")

    # Mark the service up immediately (before readiness): stop_container()
    # only acts while container_up is set, so a SIGTERM or a ready-timeout
    # during the (slow) readiness wait must still stop the service and
    # release the VRAM.
    state.container_up = True

    try:
        deadline = started_at + args.ready_timeout

        while not state.stopping:
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"container did not become ready within "
                    f"{args.ready_timeout:.0f}s"
                )

            if await probe_health(args.child_port):
                state.container_up = True
                state.container_ready = True

                log.info(
                    "container %s ready in %.1fs",
                    args.container,
                    time.monotonic() - started_at,
                )

                return

            # /health failed; if the container has exited (crashed), abort
            # early rather than waiting the full ready timeout.
            status = await container_status(args.container)
            if status == "exited":
                raise RuntimeError(f"container {args.container} exited during startup")

            await asyncio.sleep(READY_POLL_INTERVAL)

    except BaseException:
        # We own this container if it was successfully started; clean up.
        await stop_container(state)
        state.container_up = False
        state.container_ready = False
        raise

    # Reached only when state.stopping became true: the shutdown path owns the
    # container from here on.


async def stop_container(state: State) -> None:
    """
    Stop the container service and verify the container is actually stopped.

    `systemctl stop` sends SIGTERM to the `docker run` process, which (in
    attached mode) stops the container. To guarantee VRAM release, verify via
    `docker inspect` and fall back to `docker stop` / `docker kill`.
    """

    args = state.args

    if not state.container_up:
        return

    log.info(
        "stopping container service: %s (container %s)",
        args.container_service,
        args.container,
    )

    await run_cmd(
        ["systemctl", "stop", args.container_service],
        timeout=args.shutdown_timeout,
    )

    status = await container_status(args.container)

    if status in ("running", "restarting"):
        log.warning(
            "container %s still %s after systemctl stop; docker stop",
            args.container,
            status,
        )

        await run_cmd(
            ["docker", "stop", args.container],
            timeout=args.shutdown_timeout,
        )

        status = await container_status(args.container)

        if status in ("running", "restarting"):
            log.warning(
                "container %s still %s; docker kill",
                args.container,
                status,
            )

            await run_cmd(
                ["docker", "kill", args.container],
                timeout=args.kill_timeout,
            )

    # Remove the stopped container so the next start is a fresh `docker run`.
    # Fails harmlessly if the container was never created.
    await run_cmd(
        ["docker", "rm", args.container],
        timeout=args.kill_timeout,
    )

    state.container_up = False
    state.container_ready = False


async def ensure_container(state: State) -> None:
    """
    Ensure a ready container exists.

    All callers may enter concurrently, but only one startup happens: the lock
    is held for the whole startup wait.
    """

    async with state.lifecycle_lock:
        if state.stopping:
            raise RuntimeError("wrapper is shutting down")

        if state.container_up and state.container_ready:
            return

        if state.container_up and not state.container_ready:
            # A startup is in progress (we hold the lock, so this is ours);
            # wait for it to settle rather than starting a second time.
            deadline = time.monotonic() + state.args.ready_timeout
            while (
                state.container_up and not state.container_ready and not state.stopping
            ):
                if time.monotonic() >= deadline:
                    raise TimeoutError("container did not become ready")
                await asyncio.sleep(0.5)
            if state.container_ready:
                return
            # The startup failed; fall through and retry.

        await start_container(state)


# ---------------------------------------------------------------------------
# Idle monitor
# ---------------------------------------------------------------------------


async def docker_idle_monitor(
    state: State,
    stop_event: asyncio.Event,
) -> None:
    """
    Poll once per second:

      - container was ready but /health now fails (crash) -> stop the service
        (exit 0); the next connection re-activates it and retries the load
        lazily
      - container not up and nothing in flight -> stop the service (exit 0);
        the wrapper has nothing to do
      - container idle (no live relays, no active handlers, no recent client
        activity) -> stop the container and stop the service (exit 0)
    """

    while not state.stopping:
        await asyncio.sleep(1)

        if not state.container_up:
            if not state.connections and state.active_handlers == 0:
                log.info("nothing to do; stopping service")
                stop_event.set()
                return
            continue

        if not state.container_ready:
            # Still starting up (or a failed startup is being reaped); wait.
            continue

        # TEMPORARY diagnostic heartbeat (log-only, no behavior change).
        #
        # The monitor is otherwise silent while it is blocked, so the journal
        # cannot tell "idle is kept fresh by a poller" from "a relay/handler is
        # stuck" from "the stop path is failing". Log the blocking state once a
        # minute while the container is up and ready:
        #   idle keeps growing but stays < timeout, handlers/relays ~0
        #       -> an unnoticed poller keeps resetting last_activity (H2)
        #   relays or handlers stuck > 0 with no traffic
        #       -> a pinned relay / stuck handler (H5)
        #   idle >= timeout yet the container is still up on the next line
        #       -> the stop path itself is the problem (H3)
        if int(time.monotonic()) % 60 == 0:
            log.info(
                "idle-monitor: handlers=%d relays=%d idle=%.0fs",
                state.active_handlers,
                len(state.connections),
                time.monotonic() - state.last_activity,
            )

        # A ready container that no longer answers /health has crashed.
        if not await probe_health(state.args.child_port, timeout=3.0):
            log.error(
                "container %s failed /health; stopping service",
                state.args.container,
            )

            close_connections(state)

            state.stopping = True

            async with state.lifecycle_lock:
                await stop_container(state)

            stop_event.set()
            return

        if state.active_handlers:
            continue

        # A live relay means the container is servicing a client, even if there
        # has been no socket activity for a long time.
        if state.connections:
            continue

        idle = time.monotonic() - state.last_activity

        if idle < state.args.idle_seconds:
            continue

        log.info(
            "idle for %.1fs (timeout %.1fs); stopping container and exiting",
            idle,
            state.args.idle_seconds,
        )

        state.stopping = True

        async with state.lifecycle_lock:
            await stop_container(state)

        stop_event.set()
        return


# ---------------------------------------------------------------------------
# Backend
# ---------------------------------------------------------------------------


def add_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--container",
        required=True,
        help="docker container name (NixOS service is docker-<name>)",
    )

    parser.add_argument(
        "--image",
        required=True,
        help="local docker image tag the container runs from",
    )

    parser.add_argument(
        "--pull-timeout",
        type=float,
        default=7200,
        help="max seconds to wait for the one-time image pull",
    )


def validate(args: argparse.Namespace, parser: argparse.ArgumentParser) -> None:
    # Derive the NixOS oci-containers service name from the container name.
    args.container_service = f"docker-{args.container}"

    if args.pull_timeout <= 0:
        parser.error("--pull-timeout must be > 0")


def extra_tasks(state: State) -> list[asyncio.Task]:
    return []


async def stop(state: State) -> None:
    """Stop the container. Called under the lifecycle lock."""
    await stop_container(state)


BACKEND = Backend(
    noun="container",
    log_prefix="vllm-wrapper",
    default_idle_seconds=DEFAULT_IDLE_SECONDS,
    default_ready_timeout=DEFAULT_READY_TIMEOUT,
    default_kill_timeout=DEFAULT_KILL_TIMEOUT,
    default_child_port=DEFAULT_CHILD_PORT,
    ensure=ensure_container,
    is_ready=lambda s: s.container_up and s.container_ready,
    stop=stop,
    idle_monitor=docker_idle_monitor,
    extra_tasks=extra_tasks,
    add_args=add_args,
    validate=validate,
)


if __name__ == "__main__":
    raise SystemExit(main(BACKEND))
