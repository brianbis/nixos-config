#!/usr/bin/env python3
"""On-demand weight manager for ninfer-serve.

Always-on TCP proxy on the front port. The first real request spawns
ninfer-serve on the child port and waits for /health; all traffic is relayed.
After --idle-seconds with no in-flight requests (per the engine's
request-log JSONL) and no client traffic, SIGTERMs the child to free VRAM.
While cold, health checks are answered locally.

Usage: ninfer-proxy --listen H:PORT --child-port P --idle-seconds S
        --request-log FILE [--ready-timeout SEC] -- <child command...>
"""

import argparse
import asyncio
import json
import os
import signal
import socket
import subprocess
import sys
import time

HEALTH_BODY = b'{"status":"ok"}'


def log(msg):
    sys.stderr.write("[ninfer-proxy] %s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


class State:
    def __init__(self, args):
        self.args = args
        self.child = None
        self.child_ready = False
        self.instance_id = None
        self.in_flight = set()
        self.last_rx = time.monotonic()
        self.conns = set()
        self.child_lock = asyncio.Lock()
        self.stopping = False


def probe_health(port, timeout=2.0):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
            sock.sendall(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            data = sock.recv(4096)
        return data.startswith(b"HTTP/1.1 200")
    except OSError:
        return False


def close_conns(state):
    for writers in list(state.conns):
        for writer in writers:
            try:
                writer.close()
            except Exception:
                pass


def stop_child(child, timeout=30):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass


def kill_stale_children(args):
    try:
        binary = os.path.realpath(args.child_command[0])
    except OSError:
        binary = args.child_command[0]
    log_path = os.path.realpath(args.request_log)
    stale = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % entry, "rb") as fh:
                argv = [part.decode("utf-8", "replace") for part in fh.read().split(b"\0") if part]
        except OSError:
            continue
        if len(argv) < 2:
            continue
        try:
            argv0 = os.path.realpath(argv[0])
        except OSError:
            argv0 = argv[0]
        if argv0 == binary and log_path in argv:
            stale.append(int(entry))
    for pid in stale:
        log("killing stale child pid %d" % pid)
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + 15
    for pid in stale:
        while time.monotonic() < deadline:
            if not os.path.exists("/proc/%d" % pid):
                break
            time.sleep(0.2)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass


async def ensure_child(state):
    if state.child is not None and state.child.poll() is None and state.child_ready:
        return
    async with state.child_lock:
        if state.child is not None and state.child.poll() is None and state.child_ready:
            return
        if state.child is not None:
            log("child exited rc=%s; respawning" % state.child.returncode)
            state.child = None
            state.child_ready = False
            close_conns(state)
        args = state.args
        deadline = time.monotonic() + args.ready_timeout
        backoff = 2.0
        while time.monotonic() < deadline and not state.stopping:
            try:
                with open(args.request_log, "w"):
                    pass
            except OSError as exc:
                log("cannot open request log %s: %s" % (args.request_log, exc))
                await asyncio.sleep(5)
                continue
            log("spawning child: %s" % " ".join(args.child_command))
            started = time.monotonic()
            proc = subprocess.Popen(args.child_command)
            state.child = proc
            state.last_rx = time.monotonic()
            ready = False
            while time.monotonic() < deadline:
                rc = proc.poll()
                if rc is not None:
                    log("child exited during startup rc=%s" % rc)
                    break
                if probe_health(args.child_port):
                    ready = True
                    break
                await asyncio.sleep(2)
            if ready:
                state.child_ready = True
                state.last_rx = time.monotonic()
                log("child ready in %.1f s" % (time.monotonic() - started))
                return
            stop_child(proc, timeout=10)
            state.child = None
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)
        raise RuntimeError("child never became ready within %.0f s" % args.ready_timeout)


async def read_headers(reader, limit=65536):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = await reader.read(8192)
        if not chunk:
            return buf or None
        buf += chunk
        if len(buf) > limit:
            return None
    return buf


async def relay(c_reader, c_writer, h_reader, h_writer, buffered, state):
    pair = (c_writer, h_writer)
    state.conns.add(pair)
    try:
        if buffered:
            h_writer.write(buffered)
            await h_writer.drain()
        state.last_rx = time.monotonic()

        async def client_to_child():
            while True:
                data = await c_reader.read(65536)
                if not data:
                    return
                state.last_rx = time.monotonic()
                h_writer.write(data)
                await h_writer.drain()

        async def child_to_client():
            while True:
                data = await h_reader.read(65536)
                if not data:
                    return
                state.last_rx = time.monotonic()
                c_writer.write(data)
                await c_writer.drain()

        tasks = [asyncio.create_task(client_to_child()), asyncio.create_task(child_to_client())]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    finally:
        state.conns.discard(pair)
        for writer in pair:
            try:
                writer.close()
            except Exception:
                pass


async def handle_client(reader, writer, state):
    try:
        headers = await read_headers(reader)
        if not headers:
            return
        request_line = headers.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        parts = request_line.split()
        is_health = len(parts) >= 2 and parts[0] == "GET" and parts[1] == "/health"
        child_live = state.child is not None and state.child.poll() is None and state.child_ready
        if is_health and not child_live:
            body = HEALTH_BODY
            writer.write(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: %d\r\n" % len(body) +
                b"Connection: close\r\n\r\n" + body
            )
            await writer.drain()
            log("answered /health locally (model cold)")
            return
        await ensure_child(state)
        c_reader, c_writer = await asyncio.open_connection("127.0.0.1", state.args.child_port)
        await relay(reader, writer, c_reader, c_writer, headers, state)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log("connection error: %r" % (exc,))
    finally:
        try:
            writer.close()
        except Exception:
            pass


def process_event(state, record):
    event = record.get("event")
    instance_id = record.get("server_instance_id")
    request_id = record.get("request_id")
    if event == "server_start":
        state.instance_id = instance_id
        state.in_flight.clear()
    elif event == "request_start" and instance_id == state.instance_id and request_id is not None:
        state.in_flight.add((instance_id, request_id))
    elif event in ("request_done", "request_error", "request_rejected"):
        if instance_id == state.instance_id and request_id is not None:
            state.in_flight.discard((instance_id, request_id))


async def tailer(state):
    log_path = state.args.request_log
    fh = None
    buffer = b""
    while not state.stopping:
        try:
            if fh is None:
                fh = open(log_path, "rb")
            if fh.tell() > os.fstat(fh.fileno()).st_size:
                fh.seek(0)
                buffer = b""
            chunk = fh.read()
            if chunk:
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    line = line.strip()
                    if line:
                        try:
                            process_event(state, json.loads(line))
                        except (ValueError, AttributeError):
                            pass
            else:
                await asyncio.sleep(0.2)
        except FileNotFoundError:
            await asyncio.sleep(0.5)
        except OSError:
            if fh is not None:
                try:
                    fh.close()
                except OSError:
                    pass
            fh = None
            buffer = b""
            await asyncio.sleep(0.5)
    if fh is not None:
        fh.close()


async def watchdog(state):
    while not state.stopping:
        await asyncio.sleep(1)
        child = state.child
        if child is None:
            continue
        rc = child.poll()
        if rc is not None:
            log("child exited rc=%s; model unloaded" % rc)
            state.child = None
            state.child_ready = False
            state.in_flight.clear()
            close_conns(state)
            continue
        if state.in_flight:
            continue
        if not state.child_ready:
            continue
        idle = time.monotonic() - state.last_rx
        if idle >= state.args.idle_seconds:
            log("idle for %.0f s with no in-flight requests; unloading model" % idle)
            state.child = None
            state.child_ready = False
            state.in_flight.clear()
            close_conns(state)
            stop_child(child)
            log("child stopped rc=%s" % child.returncode)


async def run(args):
    state = State(args)
    kill_stale_children(args)
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    host, port_text = args.listen.rsplit(":", 1)
    server = await asyncio.start_server(
        lambda r, w: asyncio.create_task(handle_client(r, w, state)),
        host,
        int(port_text),
    )
    log("listening on %s:%s; child port %d; idle unload after %s s" % (host, port_text, args.child_port, args.idle_seconds))
    tailer_task = asyncio.create_task(tailer(state))
    watchdog_task = asyncio.create_task(watchdog(state))
    try:
        async with server:
            await stop.wait()
    finally:
        log("shutting down")
        state.stopping = True
        close_conns(state)
        if state.child and state.child.poll() is None:
            loop.run_in_executor(None, stop_child, state.child)
        tailer_task.cancel()
        watchdog_task.cancel()
        await asyncio.gather(tailer_task, watchdog_task, return_exceptions=True)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1:8080")
    parser.add_argument("--child-port", type=int, default=8081)
    parser.add_argument("--idle-seconds", type=float, default=30.0)
    parser.add_argument("--request-log", required=True)
    parser.add_argument("--ready-timeout", type=float, default=1800.0)
    parser.add_argument("child_command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.child_command and args.child_command[0] == "--":
        args.child_command = args.child_command[1:]
    if not args.child_command:
        parser.error("missing child command after --")
    return args


def main():
    args = parse_args(sys.argv[1:])
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
