"""
Shared machinery for the on-demand LLM model servers (ninfer, vLLM, sglang).

A backend (ninfer_wrapper.py / vllm_wrapper.py / sglang_wrapper.py) supplies the
model server's lifecycle (ensure/is_ready/stop for a spawned child or a docker
container) and its CLI arguments. The idle window, the clean exit-0, and the
health probe live here, once.

One runtime shape (--lifecycle-only, what every unit in this repo runs): no
port is bound and nothing is relayed. The gate (hosts/desktop/llm/gate) is the
single public door, starts this unit with `systemctl start --no-block`, and
forwards to the model's own port itself. This process only keeps the model
resident and exits when the gate stops stamping --activity-file, which is what
releases the VRAM. The HTTP plumbing lives in the gate, once: a wrapper that
bound its own front port would bypass the gate's load/redirect logic.

Exit codes:
  0  clean stop: idle unload, SIGTERM, or child failure.
  1  unexpected internal error (systemd Restart=on-abnormal).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import socket
import sys
import time
from dataclasses import dataclass, field
from typing import Awaitable, Callable

DEFAULT_SHUTDOWN_TIMEOUT = 60

log = logging.getLogger("idle-wrapper")


def configure_logging(prefix: str) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter(
            f"[{prefix}] %(asctime)s %(levelname)s %(message)s",
            "%Y-%m-%d %H:%M:%S",
        )
    )
    log.addHandler(handler)
    log.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


@dataclass
class State:
    args: argparse.Namespace
    backend: "Backend"

    # child backend (ninfer): a spawned local process.
    child: asyncio.subprocess.Process | None = None
    child_ready: bool = False

    # docker backend (vllm): an oci-containers container.
    container_up: bool = False
    container_ready: bool = False

    # One lock governs every lifecycle transition.
    lifecycle_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    stopping: bool = False


@dataclass
class Backend:
    """What a lifecycle backend (a thin wrapper) must provide."""

    # Log-line prefix, e.g. "[ninfer-wrapper]".
    log_prefix: str
    default_idle_seconds: float
    default_ready_timeout: float
    default_kill_timeout: float
    default_child_port: int
    # Ensure a ready model server exists (called under the lifecycle lock).
    ensure: Callable[[State], Awaitable[None]]
    # Whether the model server is up and ready to serve.
    is_ready: Callable[[State], bool]
    # Stop the model server (called under the lifecycle lock).
    stop: Callable[[State], Awaitable[None]]
    # Backend-specific CLI arguments.
    add_args: Callable[[argparse.ArgumentParser], None]
    # Backend-specific argument validation (may derive new args fields).
    validate: Callable[[argparse.Namespace, argparse.ArgumentParser], None]


# ---------------------------------------------------------------------------
# Health probe
# ---------------------------------------------------------------------------


async def probe_health(port: int, timeout: float = 2.0) -> bool:
    """
    Probe the model server's /health endpoint directly.

    Uses a short-lived blocking socket in an executor rather than blocking
    the asyncio event loop.
    """

    def _probe() -> bool:
        try:
            with socket.create_connection(
                ("127.0.0.1", port),
                timeout=timeout,
            ) as sock:
                sock.sendall(
                    b"GET /health HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\n"
                    b"Connection: close\r\n"
                    b"\r\n"
                )
                data = sock.recv(4096)

            # Any HTTP version in the status line counts: backends are not
            # required to be HTTP/1.1 (Strata's serve/server.py is pinned to
            # HTTP/1.0 for its SSE close semantics).
            first = data.split(b"\r\n", 1)[0]
            parts = first.split(b" ")

            return len(parts) >= 2 and parts[1] == b"200"

        except OSError:
            return False

    return await asyncio.to_thread(_probe)




# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------


async def shutdown(
    state: State,
    monitor_task: asyncio.Task,
) -> None:
    log.info("stopping")

    state.stopping = True

    # Stop the model server regardless of current idle state: this is the path
    # that releases the VRAM, so it runs even when the load failed.
    async with state.lifecycle_lock:
        await state.backend.stop(state)

    monitor_task.cancel()

    await asyncio.gather(monitor_task, return_exceptions=True)

    log.info("stopped")
# ---------------------------------------------------------------------------
# Lifecycle-only runtime (the gate owns the public front door)
# ---------------------------------------------------------------------------

ACTIVITY_POLL_SECONDS = 5.0


async def activity_idle_monitor(
    state: State,
    stop_event: asyncio.Event,
    poll: float = ACTIVITY_POLL_SECONDS,
) -> None:
    """
    End the residency window from the mtime of the gate's activity file.

    In lifecycle-only mode nothing connects to this process, so the client
    connection state that the socket-activated mode watches does not exist.
    The gate touches the activity file on every request it routes to this
    model (and heartbeats while one is in flight), so the file's mtime is the
    authoritative "the fleet still wants this model" signal: when it ages past
    idle_seconds, the model is unloaded and the wrapper exits.

    Wall-clock (time.time) is deliberate: the comparison is against a file
    mtime, which is wall clock.
    """

    started = time.time()

    while not stop_event.is_set():
        await asyncio.sleep(poll)

        try:
            touched = os.stat(state.args.activity_file).st_mtime
        except OSError:
            # No activity file yet: measure from process start, so a model
            # nobody ever asked for still unloads on its own.
            touched = started

        age = time.time() - touched

        if age > state.args.idle_seconds:
            log.info(
                "no gate request for %.1fs (idle window %.1fs): unloading",
                age,
                state.args.idle_seconds,
            )
            stop_event.set()
            return


def boot(args: argparse.Namespace, backend: Backend) -> tuple[State, asyncio.Event]:
    """The shared prologue: the run's State plus a stop event wired to SIGTERM.

    Every normal exit — idle unload, SIGTERM, or a failed load — runs through
    the same stop event, so the unload path and the signal path differ only in
    which task noticed first.
    """

    state = State(args=args, backend=backend)

    loop = asyncio.get_running_loop()

    stop_event = asyncio.Event()

    def request_shutdown() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(
            sig,
            request_shutdown,
        )

    return state, stop_event


async def run_lifecycle(
    args: argparse.Namespace,
    backend: Backend,
) -> int:
    """
    Load the model, keep it resident while the gate asks for it, exit 0.

    No port is bound and nothing is relayed: the gate is the front door and
    forwards to this model's own port. The unit is started with
    `systemctl start --no-block`, so the gate never blocks on this load.
    """

    state, stop_event = boot(args, backend)

    log.info(
        "lifecycle-only (no port bound) child_port=%d idle=%.1fs activity=%s",
        args.child_port,
        args.idle_seconds,
        args.activity_file,
    )

    # The only task: nothing tracks in-flight requests here, because the
    # wrapper relays none — the gate heartbeats the activity file while a
    # request is in flight, which keeps the model loaded for the whole
    # generation.
    monitor_task = asyncio.create_task(
        activity_idle_monitor(state, stop_event),
        name="activity-idle-monitor",
    )

    try:
        await backend.ensure(state)

        if not backend.is_ready(state):
            raise TimeoutError("model server is not ready after ensure()")

    except Exception:
        log.exception("model server failed to start")

        await shutdown(state, monitor_task)

        # A failed load is a failed unit: the gate retries it on the next
        # request rather than systemd restarting it eagerly.
        return 1

    try:
        await stop_event.wait()

    finally:
        await shutdown(state, monitor_task)

    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(
    argv: list[str],
    backend: Backend,
) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
    )

    parser.add_argument(
        "--child-port",
        type=int,
        default=backend.default_child_port,
    )

    parser.add_argument(
        "--idle-seconds",
        type=float,
        default=backend.default_idle_seconds,
    )

    parser.add_argument(
        "--ready-timeout",
        type=float,
        default=backend.default_ready_timeout,
    )

    parser.add_argument(
        "--shutdown-timeout",
        type=float,
        default=DEFAULT_SHUTDOWN_TIMEOUT,
    )

    parser.add_argument(
        "--kill-timeout",
        type=float,
        default=backend.default_kill_timeout,
    )

    # Lifecycle-only mode: the gate (hosts/desktop/llm/gate) owns the public
    # front door, so this wrapper binds NO port and relays nothing. systemd
    # starts it directly (systemctl start --no-block) and it just keeps the
    # model resident until the gate stops asking for it. Liveness then comes
    # from the mtime of an activity file the gate touches on every request
    # instead of from client connections.
    parser.add_argument(
        "--lifecycle-only",
        action="store_true",
        help="bind no port: load the model, keep it resident, exit when idle",
    )

    parser.add_argument(
        "--activity-file",
        default=None,
        help="activity file whose mtime keeps this model resident "
        "(lifecycle-only mode)",
    )

    backend.add_args(parser)

    args = parser.parse_args(argv)

    if args.idle_seconds < 0:
        parser.error("--idle-seconds must be >= 0")

    if args.ready_timeout <= 0:
        parser.error("--ready-timeout must be > 0")

    backend.validate(args, parser)

    # Lifecycle mode is the only runtime shape: a wrapper that binds no port
    # and gets no activity file would be a resident model nobody can unload.
    if not args.lifecycle_only:
        parser.error(
            "--lifecycle-only is the only runtime mode (the gate owns the"
            " front door)"
        )

    if args.activity_file is None:
        parser.error("--lifecycle-only needs --activity-file")

    return args


def main(
    backend: Backend,
) -> int:
    args = parse_args(sys.argv[1:], backend)

    configure_logging(backend.log_prefix)

    try:
        return asyncio.run(run_lifecycle(args, backend))
    except Exception:
        log.exception("internal error")
        return 1
