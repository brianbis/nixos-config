"""
Shared machinery for the socket-activated idle wrappers of the on-demand LLM
model servers (ninfer, vLLM).

systemd owns the front-port listening socket (socket activation); the wrapper
process is started on the first connection and exits (code 0) as soon as there
is nothing left to do, so between requests no process is resident at all and
the model's VRAM (and the process's host memory) is released.

This module is backend-agnostic. A backend (see ninfer_wrapper.py /
vllm_wrapper.py) supplies:

  - the lifecycle: ensure() / is_ready() / stop() of the model server
    (a spawned child process for ninfer, a docker container for vLLM)
  - the idle monitor: what counts as "nothing left to do"
  - the backend-specific CLI arguments

Everything else — the transparent TCP relay, the forced Connection: close,
the local /health, the socket-activation plumbing, the clean exit-0 — lives
here, once.

Division of labour compared to the old resident proxy:
  - The HTTP relay is a transparent TCP relay; the request log (not
    connection state) is authoritative for in-flight requests.
  - The proxy's "one request per connection" contract is preserved by
    forcing Connection: close on the child side (rewrite_headers). That is
    what lets the idle unload happen while the front (Caddy) keeps
    connections pooled: the child closes its side after each response, the
    relay completes, and the idle window can expire.
  - GET /health is answered locally and never starts the model.
  - Lifecycle: started on the first real request, terminated after the
    idle window, then the wrapper exits (code 0). systemd's socket unit
    keeps the port bound and re-activates the service on the next
    connection.

Exit codes:
  0  clean stop: idle unload, SIGTERM, or child failure. The service is
     inactive until the next connection re-activates it; a failed startup
     is retried lazily on the next request, not eagerly by systemd.
  1  unexpected internal error (systemd Restart=on-abnormal).
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import signal
import socket
import sys
import time
from dataclasses import dataclass, field
from typing import Awaitable, Callable, Optional

HEALTH_BODY = b'{"status":"ok"}'

MAX_HEADER_BYTES = 64 * 1024
READ_CHUNK = 64 * 1024

# How long to wait for a client to send its request head. A client that
# connects and sends nothing pins nothing (no model is started for it), but
# it must not pin the wrapper forever either.
HEAD_TIMEOUT = 60.0

DEFAULT_SHUTDOWN_TIMEOUT = 60
DEFAULT_DRAIN_TIMEOUT = 10

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
    child: Optional[asyncio.subprocess.Process] = None
    child_ready: bool = False

    # Authoritative request state from the request log (child backend).
    instance_id: Optional[str] = None
    in_flight: set[tuple[str, str]] = field(default_factory=set)

    # docker backend (vllm): an oci-containers container.
    container_up: bool = False
    container_ready: bool = False

    # Only client -> wrapper activity updates this (never /health).
    last_activity: float = field(default_factory=time.monotonic)

    # Active client <-> child relay pairs.
    connections: set[tuple[asyncio.StreamWriter, asyncio.StreamWriter]] = field(
        default_factory=set
    )

    # Handlers in progress (waiting for startup or relaying).
    active_handlers: int = 0

    # One lock governs every lifecycle transition.
    lifecycle_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    stopping: bool = False


@dataclass
class Backend:
    """What a lifecycle backend (a thin wrapper) must provide."""

    # Noun used in log / error messages ("child" / "container").
    noun: str
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
    # The idle monitor: what counts as "nothing left to do".
    idle_monitor: Callable[[State, asyncio.Event], Awaitable[None]]
    # Extra background tasks (e.g. the request-log tailer).
    extra_tasks: Callable[[State], list[asyncio.Task]]
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

            return data.startswith(b"HTTP/1.1 200")

        except OSError:
            return False

    return await asyncio.to_thread(_probe)


# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------


async def read_head(reader: asyncio.StreamReader) -> bytes:
    """
    Read until the end of the request head (\\r\\n\\r\\n).

    May consume bytes belonging to the request body; the caller re-appends
    them (rewrite_headers keeps everything after the head verbatim).
    """

    buf = b""
    deadline = time.monotonic() + HEAD_TIMEOUT

    while b"\r\n\r\n" not in buf:
        remaining = deadline - time.monotonic()

        if remaining <= 0:
            raise TimeoutError("request head timeout")

        chunk = await asyncio.wait_for(reader.read(READ_CHUNK), timeout=remaining)

        if not chunk:
            raise ConnectionError("client closed before sending the request head")

        buf += chunk

        if len(buf) > MAX_HEADER_BYTES:
            raise ValueError("request head too large")

    return buf


def parse_request_line(headers: bytes) -> tuple[str, str, str]:
    first_line = headers.split(b"\r\n", 1)[0]

    try:
        method, target, version = first_line.decode("latin-1").split()
    except ValueError:
        raise ValueError("malformed HTTP request line")

    return method, target, version


def rewrite_headers(headers: bytes) -> bytes:
    """
    Normalize the request headers before forwarding them to the child.

    The wrapper uses one TCP connection per client request. The child server
    otherwise honors HTTP keep-alive and keeps the accepted socket open after
    responding, which would leave the child side of the relay open forever and
    block the idle unload. Force the child to close its side once it has
    replied.
    """

    if b"\r\n\r\n" in headers:
        head, body = headers.split(b"\r\n\r\n", 1)
    else:
        head, body = headers, b""

    lines = head.split(b"\r\n")

    kept = []

    for line in lines:
        name, _, _ = line.partition(b":")
        if name.strip().lower() == b"connection":
            continue
        kept.append(line)

    # Always force the child to close: dropping an incoming keep-alive
    # header is not enough because HTTP/1.1 defaults to keep-alive when
    # absent.
    kept.append(b"Connection: close")

    return b"\r\n".join(kept) + b"\r\n\r\n" + body


def make_error_response(
    status: int,
    reason: str,
    message: str,
) -> bytes:
    body = (
        json.dumps(
            {
                "error": message,
            }
        )
    ).encode("utf-8")

    return (
        f"HTTP/1.1 {status} {reason}\r\n".encode()
        + b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + b"Connection: close\r\n"
        + b"\r\n"
        + body
    )


async def send_response(
    writer: asyncio.StreamWriter,
    response: bytes,
) -> None:
    writer.write(response)
    await writer.drain()


async def handle_local_health(
    writer: asyncio.StreamWriter,
) -> None:
    writer.write(
        b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(HEALTH_BODY)).encode() + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n" + HEALTH_BODY
    )

    await writer.drain()


async def relay(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    child_reader: asyncio.StreamReader,
    child_writer: asyncio.StreamWriter,
    initial_request: bytes,
    state: State,
) -> None:
    """
    Bidirectional streaming relay.

    The two directions have independent lifetimes.

    In particular, EOF from the client does NOT mean the response is done.
    A client can finish uploading its request while the model continues
    streaming a response.

    The connection is closed once both directions have completed, or if
    either side encounters an actual I/O failure.
    """

    pair = (client_writer, child_writer)
    state.connections.add(pair)

    try:
        state.last_activity = time.monotonic()

        # read_head() may have consumed bytes belonging to the request
        # body. Those bytes are included in initial_request by the caller.
        child_writer.write(initial_request)
        await child_writer.drain()

        async def client_to_child() -> None:
            try:
                while True:
                    data = await client_reader.read(READ_CHUNK)

                    if not data:
                        # The client has finished sending its request.
                        # Do NOT tear down the child->client direction.
                        # Half-close the child's write side if supported.
                        transport = child_writer.transport

                        if transport is not None:
                            with contextlib.suppress(Exception):
                                transport.write_eof()

                        return

                    state.last_activity = time.monotonic()

                    child_writer.write(data)
                    await child_writer.drain()

            except (ConnectionError, asyncio.IncompleteReadError):
                return

        async def child_to_client() -> None:
            try:
                while True:
                    data = await child_reader.read(READ_CHUNK)

                    if not data:
                        return

                    client_writer.write(data)
                    await client_writer.drain()

            except (ConnectionError, asyncio.IncompleteReadError):
                return

        upload_task = asyncio.create_task(
            client_to_child(),
            name="client-to-child",
        )

        download_task = asyncio.create_task(
            child_to_client(),
            name="child-to-client",
        )

        try:
            # Wait for the response to complete, not for the client to close.
            #
            # The child side closes as soon as the reply is sent (every request
            # is forced to Connection: close), so download_task settles when the
            # request is done. The client side, however, may stay open: a
            # keep-alive pooler (Caddy) reuses the connection for its next
            # request, so client_to_child blocks on read() long after the
            # reply. That pins this relay in state.connections (and the
            # handler in active_handlers), which blocks the idle unload. Close
            # the client side once the reply is complete so the relay drops
            # when the request finishes, not when the client finally closes.
            # The client upload is already done by then (the child cannot start
            # the reply until it has the full request), so closing is safe.
            await download_task

            with contextlib.suppress(Exception):
                client_writer.close()

            await upload_task

        finally:
            for task in (upload_task, download_task):
                if not task.done():
                    task.cancel()

            await asyncio.gather(
                upload_task,
                download_task,
                return_exceptions=True,
            )

    finally:
        state.connections.discard(pair)

        for writer in (client_writer, child_writer):
            writer.close()

        await asyncio.gather(
            client_writer.wait_closed(),
            child_writer.wait_closed(),
            return_exceptions=True,
        )


async def handle_connection(
    conn: socket.socket,
    state: State,
) -> None:
    """Wrap an accepted raw socket in a reader/writer and handle it."""
    loop = asyncio.get_running_loop()

    reader = asyncio.StreamReader(limit=MAX_HEADER_BYTES)
    protocol = asyncio.StreamReaderProtocol(reader)
    transport, _ = await loop.create_connection(lambda: protocol, sock=conn)
    writer = asyncio.StreamWriter(transport, protocol, reader, loop)

    try:
        await handle_client(reader, writer, state)
    finally:
        with contextlib.suppress(Exception):
            conn.close()


async def accept_loop(
    state: State,
    listen: socket.socket,
) -> None:
    """Accept connections on the inherited listening socket (event-driven)."""
    loop = asyncio.get_running_loop()

    while not state.stopping:
        try:
            conn, _addr = await loop.sock_accept(listen)
        except (BlockingIOError, InterruptedError):
            await asyncio.sleep(0.05)
            continue
        except OSError:
            # Listening socket closed during shutdown.
            return

        if state.stopping:
            conn.close()
            continue

        asyncio.create_task(
            handle_connection(conn, state),
            name="client-connection",
        )


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    state: State,
) -> None:
    peer = writer.get_extra_info("peername")

    # Counted from accept (not from a parsed request) so that a client that
    # connects and sends nothing cannot trigger the "nothing to do" exit
    # while its head read is still pending.
    state.active_handlers += 1

    try:
        try:
            headers = await read_head(reader)

        except (TimeoutError, ConnectionError, ValueError) as exc:
            log.info("no request from %s: %s", peer, exc)
            return

        method, target, version = parse_request_line(headers)

        if version not in ("HTTP/1.0", "HTTP/1.1"):
            await send_response(
                writer,
                make_error_response(
                    505,
                    "HTTP Version Not Supported",
                    "only HTTP/1.0 and HTTP/1.1 are supported",
                ),
            )
            return

        if method == "CONNECT":
            await send_response(
                writer,
                make_error_response(
                    405,
                    "Method Not Allowed",
                    "CONNECT is not supported",
                ),
            )
            return

        # Health checks are always local and must never count as client
        # activity or start the model.
        if method == "GET" and target == "/health":
            await handle_local_health(writer)
            return

        # Any non-health request is real client activity.
        state.last_activity = time.monotonic()

        try:
            await state.backend.ensure(state)
        except TimeoutError as exc:
            log.error("%s startup timeout: %s", state.backend.noun, exc)

            await send_response(
                writer,
                make_error_response(
                    503,
                    "Service Unavailable",
                    "model server failed to become ready",
                ),
            )
            return

        except Exception:
            log.exception("%s startup failed", state.backend.noun)

            await send_response(
                writer,
                make_error_response(
                    503,
                    "Service Unavailable",
                    "model server unavailable",
                ),
            )
            return

        if not state.backend.is_ready(state):
            await send_response(
                writer,
                make_error_response(
                    503,
                    "Service Unavailable",
                    "model server is not ready",
                ),
            )
            return

        try:
            child_reader, child_writer = await asyncio.open_connection(
                "127.0.0.1",
                state.args.child_port,
            )
        except OSError as exc:
            log.error(
                "could not connect to child: %s",
                exc,
            )

            await send_response(
                writer,
                make_error_response(
                    502,
                    "Bad Gateway",
                    "could not connect to model server",
                ),
            )
            return

        await relay(
            reader,
            writer,
            child_reader,
            child_writer,
            rewrite_headers(headers),
            state,
        )

    except asyncio.CancelledError:
        raise

    except Exception:
        log.exception(
            "connection error from %s",
            peer,
        )

    finally:
        state.active_handlers -= 1

        writer.close()

        with contextlib.suppress(Exception):
            await writer.wait_closed()


# ---------------------------------------------------------------------------
# Connection management
# ---------------------------------------------------------------------------


def close_connections(
    state: State,
) -> None:
    """
    Initiate connection closure.

    This is intentionally non-awaiting because it may be called while
    transitioning lifecycle state.
    """

    for client_writer, child_writer in list(state.connections):
        for writer in (client_writer, child_writer):
            with contextlib.suppress(Exception):
                writer.close()


# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------


async def shutdown(
    state: State,
    listen: socket.socket,
    accept_task: asyncio.Task,
    extra_tasks: list[asyncio.Task],
    monitor_task: asyncio.Task,
) -> None:
    log.info("stopping")

    state.stopping = True

    accept_task.cancel()

    # Awaiting a cancelled task raises CancelledError (a BaseException in
    # 3.8+), which must be swallowed here or the shutdown itself is
    # cancelled.
    with contextlib.suppress(asyncio.CancelledError):
        await accept_task

    listen.close()

    close_connections(state)

    # Give active handlers a brief opportunity to finish.
    deadline = time.monotonic() + state.args.drain_timeout

    while (state.connections or state.active_handlers) and time.monotonic() < deadline:
        await asyncio.sleep(0.1)

    # Stop the model server regardless of current idle state.
    async with state.lifecycle_lock:
        await state.backend.stop(state)

    for task in [*extra_tasks, monitor_task]:
        task.cancel()

    await asyncio.gather(
        *extra_tasks,
        monitor_task,
        return_exceptions=True,
    )

    log.info("stopped")


# ---------------------------------------------------------------------------
# Main runtime
# ---------------------------------------------------------------------------


def socket_activated_listen_socket() -> socket.socket:
    """
    Return the systemd-inherited listening socket (fd 3).

    This wrapper is only meaningful under socket activation; refuse to run
    any other way (a hand-run instance would bind nothing and serve nothing).
    """

    if os.environ.get("LISTEN_PID", "").strip() != str(os.getpid()):
        raise RuntimeError("not socket-activated (LISTEN_PID does not match this pid)")

    fds = os.environ.get("LISTEN_FDS", "0").strip()

    if fds != "1":
        raise RuntimeError(f"expected exactly one inherited socket, LISTEN_FDS={fds!r}")

    # systemd passes the first (only) listening socket on fd 3.
    return socket.socket(fileno=3)


async def run(
    args: argparse.Namespace,
    backend: Backend,
) -> int:
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

    listen = socket_activated_listen_socket()
    listen.setblocking(False)

    log.info(
        "socket-activated (inherited fd 3) child_port=%d idle=%.1fs",
        args.child_port,
        args.idle_seconds,
    )

    accept_task = asyncio.create_task(
        accept_loop(state, listen),
        name="accept-loop",
    )

    extra_tasks = backend.extra_tasks(state)

    monitor_task = asyncio.create_task(
        backend.idle_monitor(state, stop_event),
        name="idle-monitor",
    )

    try:
        await stop_event.wait()

    finally:
        await shutdown(
            state,
            listen,
            accept_task,
            extra_tasks,
            monitor_task,
        )

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

    parser.add_argument(
        "--drain-timeout",
        type=float,
        default=DEFAULT_DRAIN_TIMEOUT,
    )

    backend.add_args(parser)

    args = parser.parse_args(argv)

    if args.idle_seconds < 0:
        parser.error("--idle-seconds must be >= 0")

    if args.ready_timeout <= 0:
        parser.error("--ready-timeout must be > 0")

    backend.validate(args, parser)

    return args


def main(
    backend: Backend,
) -> int:
    args = parse_args(sys.argv[1:], backend)

    configure_logging(backend.log_prefix)

    try:
        return asyncio.run(run(args, backend))
    except RuntimeError as exc:
        # Not socket-activated (e.g. run by hand): fail loudly.
        log.error("%s", exc)
        return 1
    except Exception:
        log.exception("internal error")
        return 1
