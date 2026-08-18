#!/usr/bin/env python3

"""
On-demand weight manager for ninfer-serve.

The proxy itself remains resident on the front port. The model-serving child
is started on demand, kept alive while requests are active/recent, and
terminated after the configured idle period.

HTTP contract:
  - HTTP/1.1 request/response streaming
  - one request per client TCP connection
  - no HTTP keep-alive
  - no HTTP pipelining
  - no CONNECT
  - request/response bodies are streamed transparently
  - /health is answered locally while the child is cold

The request log is used only to determine whether the child has authoritative
in-flight requests. If request state is ambiguous, the proxy errs on the side
of keeping the child alive.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import enum
import json
import logging
import os
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from typing import Optional


HEALTH_BODY = b'{"status":"ok"}'

MAX_HEADER_BYTES = 64 * 1024
READ_CHUNK = 64 * 1024

DEFAULT_STARTUP_TIMEOUT = 30 * 60
DEFAULT_SHUTDOWN_TIMEOUT = 30
DEFAULT_KILL_TIMEOUT = 10
DEFAULT_IDLE_SECONDS = 30


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log = logging.getLogger("ninfer-proxy")


def configure_logging() -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter(
            "[ninfer-proxy] %(asctime)s %(levelname)s %(message)s",
            "%Y-%m-%d %H:%M:%S",
        )
    )
    log.addHandler(handler)
    log.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


class ChildState(enum.Enum):
    STOPPED = "stopped"
    STARTING = "starting"
    READY = "ready"
    STOPPING = "stopping"


@dataclass
class Child:
    process: asyncio.subprocess.Process
    started_at: float
    ready_at: Optional[float] = None


@dataclass
class RuntimeState:
    args: argparse.Namespace

    lifecycle: ChildState = ChildState.STOPPED
    child: Optional[Child] = None

    # Authoritative request state from the request log.
    instance_id: Optional[str] = None
    in_flight: set[tuple[str, str]] = field(default_factory=set)

    # Only client -> proxy activity updates this.
    last_client_activity: float = field(
        default_factory=time.monotonic
    )

    # Active client/child relay pairs.
    connections: set[tuple[asyncio.StreamWriter, asyncio.StreamWriter]] = field(
        default_factory=set
    )

    # Number of active client handlers currently being processed.
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

    This intentionally uses a short-lived blocking socket in an executor
    rather than blocking the asyncio event loop.
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


async def start_child(state: RuntimeState) -> Child:
    """
    Spawn and wait for the child to become healthy.

    The lifecycle lock must be held by the caller.
    """

    args = state.args

    if state.lifecycle != ChildState.STOPPED:
        raise RuntimeError(
            f"cannot start child from state {state.lifecycle.value}"
        )

    state.lifecycle = ChildState.STARTING

    log.info(
        "starting child: %s",
        " ".join(args.child_command),
    )

    started_at = time.monotonic()

    try:
        process = await asyncio.create_subprocess_exec(
            *args.child_command,
        )

        child = Child(
            process=process,
            started_at=started_at,
        )

        state.child = child

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
                child.ready_at = time.monotonic()
                state.lifecycle = ChildState.READY

                log.info(
                    "child pid=%d ready in %.1fs",
                    process.pid,
                    child.ready_at - started_at,
                )

                return child

            await asyncio.sleep(1)

        raise asyncio.CancelledError

    except BaseException:
        # We own this child if it was successfully spawned.
        if state.child is not None:
            process = state.child.process

            if process.returncode is None:
                await terminate_process(
                    process,
                    terminate_timeout=args.shutdown_timeout,
                    kill_timeout=args.kill_timeout,
                )

        state.child = None
        state.lifecycle = ChildState.STOPPED
        raise


async def ensure_child(state: RuntimeState) -> Child:
    """
    Ensure exactly one ready child exists.

    All callers may enter concurrently, but only one startup can happen.
    """

    async with state.lifecycle_lock:
        if state.stopping:
            raise RuntimeError("proxy is shutting down")

        if (
            state.lifecycle == ChildState.READY
            and state.child is not None
            and state.child.process.returncode is None
        ):
            return state.child

        if state.lifecycle != ChildState.STOPPED:
            # Another lifecycle transition should not normally be visible
            # while holding the lock, but treat it as an invariant violation.
            raise RuntimeError(
                f"unexpected child state: {state.lifecycle.value}"
            )

        return await start_child(state)


async def unload_child(
    state: RuntimeState,
    *,
    reason: str,
) -> None:
    """
    Stop the child if it is still the same ready child.

    This method owns the lifecycle transition and therefore cannot race with
    ensure_child().
    """

    async with state.lifecycle_lock:
        if state.lifecycle != ChildState.READY:
            return

        child = state.child

        if child is None:
            state.lifecycle = ChildState.STOPPED
            return

        # Re-check all conditions while holding the lifecycle lock.
        if state.in_flight:
            return
        if state.active_handlers:
            return
        # The request log is authoritative for server-side request state, but
        # the proxy also knows something the log cannot reliably express:
        # there is an active client <-> child streaming connection.
        #
        # Never unload while a relay exists. This covers long model "thinking"
        # periods where neither side is transferring bytes.
        if state.connections:
            return
        idle = time.monotonic() - state.last_client_activity

        if idle < state.args.idle_seconds:
            return

        log.info(
            "unloading child pid=%d reason=%s idle=%.1fs",
            child.process.pid,
            reason,
            idle,
        )

        state.lifecycle = ChildState.STOPPING

        # Stop accepting new relay work against this child.
        close_connections(state)

        await terminate_process(
            child.process,
            terminate_timeout=state.args.shutdown_timeout,
            kill_timeout=state.args.kill_timeout,
        )

        rc = child.process.returncode

        state.child = None
        state.lifecycle = ChildState.STOPPED
        state.instance_id = None
        state.in_flight.clear()

        log.info(
            "child unloaded rc=%s",
            rc,
        )


# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------


async def read_headers(
    reader: asyncio.StreamReader,
    *,
    limit: int = MAX_HEADER_BYTES,
) -> Optional[bytes]:
    """
    Read through the end of HTTP headers.

    We intentionally do not attempt to implement a complete HTTP parser here.
    The proxy is a constrained one-request-per-connection streaming proxy.
    """

    buffer = bytearray()

    while b"\r\n\r\n" not in buffer:
        chunk = await reader.read(8192)

        if not chunk:
            return bytes(buffer) if buffer else None

        buffer.extend(chunk)

        if len(buffer) > limit:
            raise ValueError("request headers too large")

    return bytes(buffer)


def parse_request_line(headers: bytes) -> tuple[str, str, str]:
    first_line = headers.split(b"\r\n", 1)[0]

    try:
        method, target, version = (
            first_line.decode("latin-1").split()
        )
    except ValueError:
        raise ValueError("malformed HTTP request line")

    return method, target, version


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
        ).encode("utf-8")
    )

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


# ---------------------------------------------------------------------------
# Relay
# ---------------------------------------------------------------------------


async def relay(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    child_reader: asyncio.StreamReader,
    child_writer: asyncio.StreamWriter,
    initial_request: bytes,
    state: RuntimeState,
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
        state.last_client_activity = time.monotonic()

        # read_headers() may have consumed bytes belonging to the request
        # body. Those bytes are included in initial_request by the caller.
        child_writer.write(initial_request)
        await child_writer.drain()

        async def client_to_child() -> None:
            try:
                while True:
                    data = await client_reader.read(READ_CHUNK)

                    if not data:
                        # The client has finished sending its request.
                        #
                        # Do NOT tear down the child->client direction.
                        # Half-close the child's write side if supported.
                        transport = child_writer.transport

                        if transport is not None:
                            with contextlib.suppress(Exception):
                                transport.write_eof()

                        return

                    state.last_client_activity = time.monotonic()

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
            # IMPORTANT:
            #
            # Do not use FIRST_COMPLETED here.
            #
            # The client upload can finish while the child continues
            # streaming the response.
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


# ---------------------------------------------------------------------------
# Client handler
# ---------------------------------------------------------------------------


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    state: RuntimeState,
) -> None:
    peer = writer.get_extra_info("peername")

    try:
        headers = await read_headers(reader)

        if not headers:
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

        # Cold health is local and must not start the model.
        if method == "GET" and target == "/health":
            if state.lifecycle != ChildState.READY:
                await handle_local_health(writer)
                return

        # Any non-health request is real client activity.
        state.last_client_activity = time.monotonic()
        state.active_handlers += 1

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

        except Exception as exc:
            log.exception("child startup failed")

            await send_response(
                writer,
                make_error_response(
                    503,
                    "Service Unavailable",
                    f"model server unavailable: {exc}",
                ),
            )
            return

        child = state.child

        if (
            child is None
            or state.lifecycle != ChildState.READY
            or child.process.returncode is not None
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
            headers,
            state,
        )

    except ValueError as exc:
        log.info(
            "bad request from %s: %s",
            peer,
            exc,
        )

        with contextlib.suppress(Exception):
            await send_response(
                writer,
                make_error_response(
                    400,
                    "Bad Request",
                    str(exc),
                ),
            )

    except asyncio.CancelledError:
        raise

    except Exception:
        log.exception(
            "connection error from %s",
            peer,
        )

    finally:
        if state.active_handlers > 0:
            state.active_handlers -= 1
        writer.close()

        with contextlib.suppress(Exception):
            await writer.wait_closed()


# ---------------------------------------------------------------------------
# Request log
# ---------------------------------------------------------------------------


def process_event(
    state: RuntimeState,
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
    state: RuntimeState,
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

                stat = os.stat(path)

                # File replaced.
                if inode != stat.st_ino:
                    fh.close()
                    fh = None
                    inode = None
                    buffer = b""
                    continue

                # File truncated.
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
# Watchdog
# ---------------------------------------------------------------------------


async def watchdog(
    state: RuntimeState,
) -> None:
    while not state.stopping:
        await asyncio.sleep(1)

        child = state.child

        if child is None:
            continue

        if child.process.returncode is not None:
            log.error(
                "child pid=%d exited rc=%s",
                child.process.pid,
                child.process.returncode,
            )

            async with state.lifecycle_lock:
                # Don't overwrite a newer child transition.
                if state.child is child:
                    state.child = None
                    state.lifecycle = ChildState.STOPPED
                    state.instance_id = None
                    state.in_flight.clear()

                    close_connections(state)

            continue

        if state.lifecycle != ChildState.READY:
            continue

        if state.in_flight:
            continue
        if state.active_handlers:
            continue
        # A live relay means the child is servicing a client, even if there
        # has been no socket activity for a long time.
        if state.connections:
            continue
        idle = time.monotonic() - state.last_client_activity

        if idle < state.args.idle_seconds:
            continue

        await unload_child(
            state,
            reason="idle",
        )


# ---------------------------------------------------------------------------
# Connection management
# ---------------------------------------------------------------------------


def close_connections(
    state: RuntimeState,
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
    state: RuntimeState,
    server: asyncio.AbstractServer,
    tailer_task: asyncio.Task,
    watchdog_task: asyncio.Task,
) -> None:
    log.info("shutting down")

    state.stopping = True

    # Stop accepting new clients.
    server.close()
    await server.wait_closed()

    # Close existing client connections.
    close_connections(state)

    # Give active handlers a brief opportunity to finish.
    deadline = time.monotonic() + state.args.drain_timeout

    while state.connections and time.monotonic() < deadline:
        await asyncio.sleep(0.1)

    # Stop the child regardless of current idle state.
    async with state.lifecycle_lock:
        child = state.child

        if child is not None:
            state.lifecycle = ChildState.STOPPING

            await terminate_process(
                child.process,
                terminate_timeout=state.args.shutdown_timeout,
                kill_timeout=state.args.kill_timeout,
            )

            state.child = None

        state.lifecycle = ChildState.STOPPED
        state.instance_id = None
        state.in_flight.clear()

    tailer_task.cancel()
    watchdog_task.cancel()

    await asyncio.gather(
        tailer_task,
        watchdog_task,
        return_exceptions=True,
    )

    log.info("shutdown complete")


# ---------------------------------------------------------------------------
# Main runtime
# ---------------------------------------------------------------------------


async def run(
    args: argparse.Namespace,
) -> None:
    state = RuntimeState(args)

    loop = asyncio.get_running_loop()

    stop_event = asyncio.Event()

    def request_shutdown() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(
            sig,
            request_shutdown,
        )

    host, port_text = args.listen.rsplit(":", 1)

    server = await asyncio.start_server(
        lambda reader, writer: asyncio.create_task(
            handle_client(reader, writer, state)
        ),
        host,
        int(port_text),
        limit=MAX_HEADER_BYTES,
    )

    log.info(
        "listening on %s:%s child_port=%d idle=%.1fs",
        host,
        port_text,
        args.child_port,
        args.idle_seconds,
    )

    tailer_task = asyncio.create_task(
        tail_request_log(state),
        name="request-log-tailer",
    )

    watchdog_task = asyncio.create_task(
        watchdog(state),
        name="child-watchdog",
    )

    try:
        await stop_event.wait()

    finally:
        await shutdown(
            state,
            server,
            tailer_task,
            watchdog_task,
        )


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
        "--listen",
        default="127.0.0.1:8080",
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
        default=DEFAULT_STARTUP_TIMEOUT,
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
        default=10,
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


def main() -> None:
    configure_logging()

    args = parse_args(
        os.sys.argv[1:]
    )

    try:
        asyncio.run(
            run(args)
        )
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()