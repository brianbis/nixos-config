#!/usr/bin/env python3
"""
Socket-activated idle wrapper for ninfer-serve.

Replaces the resident HTTP proxy (proxy.py). systemd owns the front-port
listening socket (socket activation); this process is started on the first
connection and exits (code 0) as soon as there is nothing left to do, so
between requests no process is resident at all — the model's VRAM and the
process's host memory are both released with the child.

Division of labour compared to the old proxy:
  - The HTTP relay is a transparent TCP relay; the request log (not
    connection state) is authoritative for in-flight requests.
  - The proxy's "one request per connection" contract is preserved by
    forcing Connection: close on the child side (rewrite_headers). That is
    what lets the idle unload happen while the front (Caddy) keeps
    connections pooled: the child closes its side after each response, the
    relay completes, and the idle window can expire.
  - GET /health is answered locally and never starts the model.
  - Child lifecycle: started on the first real request, terminated after
    the idle window, then the wrapper exits (code 0). systemd's socket unit
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
from typing import Optional

HEALTH_BODY = b'{"status":"ok"}'

MAX_HEADER_BYTES = 64 * 1024
READ_CHUNK = 64 * 1024

# How long to wait for a client to send its request head. A client that
# connects and sends nothing pins nothing (no child is started for it), but
# it must not pin the wrapper forever either.
HEAD_TIMEOUT = 60.0

DEFAULT_IDLE_SECONDS = 60
DEFAULT_READY_TIMEOUT = 30 * 60
DEFAULT_SHUTDOWN_TIMEOUT = 60
DEFAULT_KILL_TIMEOUT = 10
DEFAULT_DRAIN_TIMEOUT = 10

log = logging.getLogger("ninfer-wrapper")


def configure_logging() -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter(
            "[ninfer-wrapper] %(asctime)s %(levelname)s %(message)s",
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

    child: Optional[asyncio.subprocess.Process] = None
    child_ready: bool = False

    # Authoritative request state from the request log.
    instance_id: Optional[str] = None
    in_flight: set[tuple[str, str]] = field(default_factory=set)

    # Only client -> wrapper activity updates this (never /health).
    last_activity: float = field(default_factory=time.monotonic)

    # Active client <-> child relay pairs.
    connections: set[tuple[asyncio.StreamWriter, asyncio.StreamWriter]] = field(
        default_factory=set
    )

    # Handlers in progress (waiting for startup or relaying).
    active_handlers: int = 0

    # One lock governs every child lifecycle transition.
    lifecycle_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    stopping: bool = False


# ---------------------------------------------------------------------------
# Child lifecycle
# ---------------------------------------------------------------------------


async def probe_health(port: int, timeout: float = 2.0) -> bool:
    """
    Probe the child directly.

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
                    f"child did not become ready within "
                    f"{args.ready_timeout:.0f}s"
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
            # Startup in progress (another handler holds the lock and is
            # waiting for readiness): block until it settles, then re-check.
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
        method, target, version = (
            first_line.decode("latin-1").split()
        )
    except ValueError:
        raise ValueError("malformed HTTP request line")

    return method, target, version


def rewrite_headers(headers: bytes) -> bytes:
    """
    Normalize the request headers before forwarding them to the child.

    The wrapper uses one TCP connection per client request. The child
    server (ninfer-serve / cpp-httplib) otherwise honors HTTP keep-alive and
    keeps the accepted socket open after responding, which would leave the
    child side of the relay open forever and block the idle unload. Force
    the child to close its side once it has replied.
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
        b"Content-Length: "
        + str(len(HEALTH_BODY)).encode()
        + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n"
        + HEALTH_BODY
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
            # Wait for BOTH directions, not FIRST_COMPLETED: the client upload
            # can finish while the child is still streaming the response.
            await asyncio.gather(
                upload_task,
                download_task,
            )

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
            await ensure_child(state)
        except TimeoutError as exc:
            log.error("child startup timeout: %s", exc)

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
            log.exception("child startup failed")

            await send_response(
                writer,
                make_error_response(
                    503,
                    "Service Unavailable",
                    "model server unavailable",
                ),
            )
            return

        if (
            state.child is None
            or not state.child_ready
            or state.child.returncode is not None
        ):
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


async def idle_monitor(
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
    tailer_task: asyncio.Task,
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

    while (
        state.connections or state.active_handlers
    ) and time.monotonic() < deadline:
        await asyncio.sleep(0.1)

    # Stop the child regardless of current idle state.
    async with state.lifecycle_lock:
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

    tailer_task.cancel()
    monitor_task.cancel()

    await asyncio.gather(
        tailer_task,
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
        raise RuntimeError(
            "not socket-activated (LISTEN_PID does not match this pid)"
        )

    fds = os.environ.get("LISTEN_FDS", "0").strip()

    if fds != "1":
        raise RuntimeError(
            f"expected exactly one inherited socket, LISTEN_FDS={fds!r}"
        )

    # systemd passes the first (only) listening socket on fd 3.
    return socket.socket(fileno=3)


async def run(
    args: argparse.Namespace,
) -> int:
    state = State(args)

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

    tailer_task = asyncio.create_task(
        tail_request_log(state),
        name="request-log-tailer",
    )

    monitor_task = asyncio.create_task(
        idle_monitor(state, stop_event),
        name="idle-monitor",
    )

    try:
        await stop_event.wait()

    finally:
        await shutdown(
            state,
            listen,
            accept_task,
            tailer_task,
            monitor_task,
        )

    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(
    argv: list[str],
) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
    )

    parser.add_argument(
        "--child-port",
        type=int,
        default=8081,
    )

    parser.add_argument(
        "--idle-seconds",
        type=float,
        default=DEFAULT_IDLE_SECONDS,
    )

    parser.add_argument(
        "--request-log",
        required=True,
    )

    parser.add_argument(
        "--ready-timeout",
        type=float,
        default=DEFAULT_READY_TIMEOUT,
    )

    parser.add_argument(
        "--shutdown-timeout",
        type=float,
        default=DEFAULT_SHUTDOWN_TIMEOUT,
    )

    parser.add_argument(
        "--kill-timeout",
        type=float,
        default=DEFAULT_KILL_TIMEOUT,
    )

    parser.add_argument(
        "--drain-timeout",
        type=float,
        default=DEFAULT_DRAIN_TIMEOUT,
    )

    parser.add_argument(
        "child_command",
        nargs=argparse.REMAINDER,
    )

    args = parser.parse_args(argv)

    if args.child_command and args.child_command[0] == "--":
        args.child_command = args.child_command[1:]

    if not args.child_command:
        parser.error(
            "missing child command after --"
        )

    if args.idle_seconds < 0:
        parser.error("--idle-seconds must be >= 0")

    if args.ready_timeout <= 0:
        parser.error("--ready-timeout must be > 0")

    return args


def main() -> int:
    configure_logging()

    args = parse_args(sys.argv[1:])

    try:
        return asyncio.run(run(args))
    except RuntimeError as exc:
        # Not socket-activated (e.g. run by hand): fail loudly.
        log.error("%s", exc)
        return 1
    except Exception:
        log.exception("internal error")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())