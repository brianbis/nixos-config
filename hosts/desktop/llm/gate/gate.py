"""
The LLM gate: one boot-resident front door for every model in the fleet.

Every jailed agent (crush, opencode, aider, claude, dsh) talks to this one
port (the ledger's `gate`, served as llm.local); the engines' own loopback
ports are private plumbing the gate forwards to. One port, one process, one
routing table.

The routing table is DATA, rendered from the Nix catalog into table.json at
build time (see ../../catalog). Nothing here hardcodes a model id, a port, or
a systemd unit name.

What it does per request:

  1. Answers availability locally and cheaply: GET /v1/models lists what can
     be served right now (with what is actually resident), GET /gate/state
     reports the whole fleet against the current VRAM.
  2. Resolves the requested `model` against the table. Several engines can
     serve one served id; the highest `preference` wins.
  3. Loads on demand: if the requested model is not resident and its VRAM
     fits, it starts that model's systemd unit (`systemctl start --no-block`)
     and waits for the engine's own /health. The idle wrapper behind that
     unit does the loading; the gate only owns the decision.
  4. Redirects silently: if the requested model cannot be served — another
     model is resident and the card cannot fit this one — it serves the
     request from a live, capability-compatible model instead of no-opping,
     rewriting the body's `model` field. Agents that pin a model name keep
     working when the fleet swapped models.
  5. Falls back to a hosted row when no local engine can serve.

A local request is forwarded through its row's `relay` port — a Headroom
compression front when the row names one, otherwise the engine's own port.
The gate keeps an engine alive by touching that row's activity file
(heartbeating while a request is in flight), which is what lets the wrapper
unload and release the VRAM once the fleet stops asking.

Response headers carry X-LLM-Gate-Redirect when the served model differs from
the requested one, so a redirect is visible to a human without being
something an agent has to handle.

Exit codes: 0 clean stop (SIGTERM), 1 unexpected internal error.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass

MAX_HEAD_BYTES = 64 * 1024
READ_CHUNK = 64 * 1024
MAX_LINE_BYTES = 512  # a chunked-transfer size line is a handful of digits
HEAD_TIMEOUT = 60.0

# A client that connects and sends nothing must not pin the gate.
CLIENT_HEAD_TIMEOUT = 30.0

# How long a probe of an engine's /health blocks.
PROBE_TIMEOUT = 0.35
# A live probe result is reused for this long, so GET /v1/models does not
# open a socket per row.
PROBE_CACHE_SECONDS = 2.0
# nvidia-smi is slow (~0.3s); the free-VRAM reading is reused for this long.
VRAM_CACHE_SECONDS = 5.0
# How often the gate re-touches an activity file while a request is in flight.
HEARTBEAT_SECONDS = 10.0

SYSTEMCTL = "/run/systemd/systemctl"

log = logging.getLogger("llm-gate")

GATE_HEADER = b"X-LLM-Gate-Redirect"


@dataclass
class Row:
    """One engine in the fleet table (a row of table.json)."""

    id: str
    name: str
    family: str
    provider: str
    unit: str | None
    port: int
    relay: int
    hosted: bool
    on_demand: bool
    preference: int
    context: int
    max_tok: int
    vram_mib: int
    can_reason: bool
    can_attach: bool
    efforts: list[str]


@dataclass
class Policy:
    port: int
    activity_dir: str
    default_id: str
    card_free_mib: int
    ready_timeout_seconds: float
    live_grace_seconds: float


class Stream:
    """A StreamReader with a lookahead buffer, so head/body framing is one
    place and bytes already read are never lost."""

    def __init__(self, reader: asyncio.StreamReader) -> None:
        self.reader = reader
        self.buf = b""

    async def fill_until(self, sep: bytes, limit: int) -> None:
        while sep not in self.buf:
            if len(self.buf) > limit:
                raise ValueError("head too large")

            chunk = await self.reader.read(READ_CHUNK)

            if not chunk:
                raise ConnectionError("stream ended before the separator")

            self.buf += chunk

    async def take(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = await self.reader.read(READ_CHUNK)

            if not chunk:
                raise ConnectionError("stream ended early")

            self.buf += chunk

        out, self.buf = self.buf[:n], self.buf[n:]

        return out

    async def take_line(self) -> bytes:
        await self.fill_until(b"\r\n", MAX_LINE_BYTES)

        line, _, self.buf = self.buf.partition(b"\r\n")

        return line


async def read_request(stream: Stream) -> tuple[str, str, list[bytes], bytes]:
    """Return (method, target, header_lines, body) for one client request."""

    await stream.fill_until(b"\r\n\r\n", MAX_HEAD_BYTES)

    head, _, stream.buf = stream.buf.partition(b"\r\n\r\n")

    lines = head.split(b"\r\n")

    try:
        method, target, _version = lines[0].decode("latin-1").split()
    except ValueError:
        raise ValueError("malformed request line")

    body = b""
    chunked = False
    length: int | None = None

    for line in lines[1:]:
        name, _, value = line.partition(b":")
        name = name.strip().lower()
        value = value.strip()

        if name == b"content-length":
            length = int(value)
        elif name == b"transfer-encoding":
            chunked = b"chunked" in value.lower()

    if chunked:
        while True:
            size_line = await stream.take_line()

            try:
                size = int(size_line.split(b";")[0], 16)
            except ValueError:
                raise ValueError("malformed chunk size")

            if size == 0:
                # Trailers, then the blank line that ends the message.
                while (trailer := await stream.take_line()) != b"":
                    pass

                break

            body += await stream.take(size)

            await stream.take(2)

    elif length is not None:
        body = await stream.take(length) if length else b""

    return method, target, lines[1:], body


def request_needs(body: bytes) -> dict:
    """What the request actually needs from a model: an effort control and
    multimodal parts. Cheap and conservative — a row that cannot satisfy a
    need is never chosen for a redirect."""

    needs_attach = (
        b'"type":"image"' in body
        or b'"type": "image"' in body
        or b"image_url" in body
        or b'"type":"audio"' in body
        or b'"role":"tool"' in body
    )

    needs_reason = (
        b'"reasoning_effort"' in body
        or b'"thinking"' in body
        or b'"reasoning"' in body
    )

    return {"attach": needs_attach, "reason": needs_reason}


def compatible(row: Row, needs: dict) -> bool:
    if needs["attach"] and not row.can_attach:
        return False

    if needs["reason"] and not row.can_reason:
        return False

    return True


def rewrite_model(body: bytes, requested: str, served: str) -> bytes:
    """Swap the body's `model` field, keeping everything else verbatim.

    A targeted byte edit rather than a JSON round-trip: a request can carry a
    six-figure token context, and re-serializing it would churn the whole
    document (and its byte offsets) for a one-word change.
    """

    pattern = re.compile(rb'"model"\s*:\s*"' + re.escape(requested.encode()) + b'"')

    replaced, count = pattern.subn(b'"model": "' + served.encode() + b'"', body, count=1)

    if count == 0:
        # The field is absent or shaped differently: the upstream still gets
        # a valid request, it just keeps the name it was sent.
        return body

    return replaced


class Fleet:
    """The live view: which rows are resident, how much VRAM is free."""

    def __init__(self, rows: list[Row], policy: Policy) -> None:
        self.rows = rows
        self.policy = policy
        self.by_id: dict[str, list[Row]] = {}

        for row in rows:
            self.by_id.setdefault(row.id, []).append(row)

        for routes in self.by_id.values():
            routes.sort(key=lambda r: -r.preference)

        self.default_rows = self.by_id.get(policy.default_id, [])
        self.probe_cache: dict[int, tuple[float, bool]] = {}
        self.vram_cache: tuple[float, int | None] = (0.0, None)

    def live(self, row: Row) -> bool:
        """An engine is live when its own port answers /health.

        The engine's own port is private plumbing — nothing else probes it —
        so this is the authoritative "this model is resident" signal, and it
        stays correct when the unit died on its own idle window.
        """

        now = time.monotonic()
        cached = self.probe_cache.get(row.port)

        if cached and now - cached[0] < PROBE_CACHE_SECONDS:
            return cached[1]

        up = probe_health(row.port)

        self.probe_cache[row.port] = (now, up)

        return up

    def free_vram_mib(self) -> int | None:
        now = time.monotonic()

        if now - self.vram_cache[0] < VRAM_CACHE_SECONDS:
            return self.vram_cache[1]

        free = query_free_vram_mib()

        self.vram_cache = (now, free)

        return free

    def stamp(self, unit: str) -> None:
        touch_activity(self.policy.activity_dir, unit)

    def fits(self, row: Row) -> bool:
        """Can this card take this model on top of what is already resident?

        The reading is the GPU's own free memory, so it already accounts for
        every resident engine. No reading (no nvidia-smi) means no policy:
        serve rather than refuse.
        """

        if row.vram_mib <= 0:
            return True

        free = self.free_vram_mib()

        if free is None:
            return True

        return free >= row.vram_mib

    def candidates(self, requested: str) -> list[Row]:
        return self.by_id.get(requested) or self.default_rows

    async def pick(self, requested: str, needs: dict) -> Row | None:
        """The row that will serve this request — load it if needed."""

        for row in self.candidates(requested):
            if row.hosted or self.live(row):
                return row

        for row in self.candidates(requested):
            if row.on_demand and compatible(row, needs) and self.fits(row):
                if await self.start(row):
                    return row

        # Nothing the caller named can serve: pick a live model that can
        # carry the request instead of no-opping. Same family first, then
        # anything capability-compatible with the highest preference.
        live = [r for r in self.rows if not r.hosted and self.live(r)]
        usable = [r for r in live if compatible(r, needs)]

        if usable:
            same_family = [
                r for r in usable if r.family == self.candidates(requested)[0].family
            ]

            return max(
                same_family or usable,
                key=lambda r: (r.preference, -r.vram_mib),
            )

        # Nothing local is resident and nothing local fits: hand the request
        # to a hosted row that can carry it.
        hosted = [r for r in self.rows if r.hosted and compatible(r, needs)]

        if hosted:
            return max(hosted, key=lambda r: r.preference)

        return None

    async def start(self, row: Row) -> bool:
        """Queue the unit's load and wait for the engine to answer /health.

        `--no-block` is the whole point: the unit runs until its idle window
        expires, so a blocking start would hang the request forever.
        """

        if row.unit is None:
            return False

        self.stamp(row.unit)

        try:
            proc = subprocess_run(
                ["systemctl", "start", "--no-block", row.unit],
            )

            if proc.returncode != 0:
                log.error("systemctl start %s failed: %s", row.unit, proc.stderr.strip())
                return False

        except OSError:
            log.exception("could not run systemctl")
            return False

        deadline = time.monotonic() + self.policy.ready_timeout_seconds

        while time.monotonic() < deadline:
            if probe_health(row.port, timeout=1.0):
                log.info("engine %s ready on :%d", row.unit, row.port)
                return True

            self.stamp(row.unit)
            await asyncio.sleep(0.5)

        log.error("engine %s never became ready within %.0fs", row.unit, self.policy.ready_timeout_seconds)

        return False


def probe_health(port: int, timeout: float = PROBE_TIMEOUT) -> bool:
    """Ask an engine's own port whether it is up.

    Blocking on purpose: a dead port fails instantly (ECONNREFUSED) and a live
    one answers in about a millisecond, so the cost is a rounding error and
    there is no thread to hand the socket to."""

    def _probe() -> bool:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
                sock.sendall(
                    b"GET /health HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\n"
                    b"Connection: close\r\n"
                    b"\r\n"
                )
                data = sock.recv(4096)

            first = data.split(b"\r\n", 1)[0]
            parts = first.split(b" ")

            return len(parts) >= 2 and parts[1] == b"200"

        except OSError:
            return False

    return _probe()


def query_free_vram_mib() -> int | None:
    """Free VRAM in MiB from nvidia-smi, or None when there is no reading."""

    try:
        proc = subprocess_run(
            [
                "nvidia-smi",
                "--query-gpu=memory.free",
                "--format=csv,noheader,nounits",
            ],
        )

        if proc.returncode != 0:
            return None

        values = [
            int(line.strip())
            for line in proc.stdout.splitlines()
            if line.strip().isdigit()
        ]

        return min(values) if values else None

    except (OSError, subprocess.TimeoutExpired) as exc:
        # No nvidia-smi on this PATH (or a hung probe): no policy, so serve
        # rather than refuse. Debug level — this fires on every request in a
        # GPU-less environment and the journal should stay quiet.
        log.debug("no free-VRAM reading: %s", exc)
        return None
    except ValueError:
        log.exception("unparsable nvidia-smi output")
        return None


def subprocess_run(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def touch_activity(activity_dir: str, unit: str) -> None:
    """Stamp the unit's activity file: the fleet still wants this model."""

    path = f"{activity_dir}/{unit}"

    try:
        with open(path, "w") as handle:
            handle.write(str(int(time.time())))
    except OSError:
        log.warning("cannot stamp %s", path)


def load_table(path: str) -> tuple[list[Row], Policy]:
    with open(path) as handle:
        doc = json.load(handle)

    rows = [
        Row(
            id=r["id"],
            name=r["name"],
            family=r["family"],
            provider=r["provider"],
            unit=r["unit"],
            port=r["port"],
            relay=r["relay"],
            hosted=r["hosted"],
            on_demand=r["onDemand"],
            preference=r["preference"],
            context=r["context"],
            max_tok=r["maxTok"],
            vram_mib=r["vramMib"],
            can_reason=r["canReason"],
            can_attach=r["canAttach"],
            efforts=r["efforts"],
        )
        for r in doc["rows"]
    ]

    gate = doc["gate"]
    default = gate["default"]

    policy = Policy(
        port=gate["port"],
        activity_dir=gate["activityDir"],
        default_id=default["id"],
        card_free_mib=gate.get("cardFreeMib", 0),
        ready_timeout_seconds=gate.get("readyTimeoutSeconds", 120.0),
        live_grace_seconds=gate.get("liveGraceSeconds", 90.0),
    )

    return rows, policy


def availability_body(fleet: Fleet) -> bytes:
    """GET /v1/models: what can be served, and what is resident now."""

    data = []

    for row in fleet.rows:
        entry = {
            "id": row.id,
            "object": "model",
            "created": 0,
            "owned_by": row.provider,
            "gate": {
                "engines": [r.provider for r in fleet.by_id[row.id]],
                "resident": any(fleet.live(r) for r in fleet.by_id[row.id]),
                "onDemand": row.on_demand,
                "vramMib": row.vram_mib,
                "context": row.context,
                "family": row.family,
                "canReason": row.can_reason,
                "attachments": row.can_attach,
                "reasoningEfforts": row.efforts,
            },
        }

        if entry not in data:
            data.append(entry)

    return json.dumps(
        {"object": "list", "data": data},
    ).encode()


def state_body(fleet: Fleet) -> bytes:
    """GET /gate/state: the whole fleet against the current VRAM."""

    free = fleet.free_vram_mib()

    return json.dumps(
        {
            "freeVramMib": free,
            "cardFreeMib": fleet.policy.card_free_mib,
            "default": fleet.policy.default_id,
            "rows": [
                {
                    "id": row.id,
                    "provider": row.provider,
                    "unit": row.unit,
                    "port": row.port,
                    "relay": row.relay,
                    "hosted": row.hosted,
                    "onDemand": row.on_demand,
                    "vramMib": row.vram_mib,
                    "live": not row.hosted and fleet.live(row),
                    "loadable": row.on_demand
                    and (free is None or free >= row.vram_mib),
                }
                for row in fleet.rows
            ],
        },
    ).encode()


def make_response(status: int, reason: str, body: bytes) -> bytes:
    """One local response, framed once: the gate never streams its own bodies."""

    return (
        f"HTTP/1.1 {status} {reason}\r\n".encode()
        + b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + b"Connection: close\r\n"
        + b"\r\n"
        + body
    )


async def send_local(
    writer: asyncio.StreamWriter,
    body: bytes,
    status: int = 200,
    reason: str = "OK",
) -> None:
    writer.write(make_response(status, reason, body))
    await writer.drain()


async def relay_to(
    client_writer: asyncio.StreamWriter,
    port: int,
    request: tuple[str, str, list[bytes], bytes],
    redirect: tuple[str, str] | None,
) -> None:
    """Forward one request to `port` and stream the reply back verbatim.

    The request is normalized to Content-Length (the client's chunked framing,
    if any, was already decoded by read_request) and forced to Connection:
    close, so the upstream closes its side after the reply and the copy below
    settles when the request is done rather than waiting for a keep-alive
    socket to expire. The reply is copied byte-for-byte — SSE included.
    """

    method, target, header_lines, body = request
    redirect_from, redirect_to = redirect if redirect else (None, None)

    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
    except OSError as exc:
        log.error("cannot reach :%d: %s", port, exc)
        await send_local(
            client_writer,
            json.dumps({"error": "upstream unreachable"}).encode(),
            502,
            "Bad Gateway",
        )
        return

    try:
        kept: list[bytes] = []

        for line in header_lines:
            name, _, _ = line.partition(b":")

            if name.strip().lower() not in (b"connection", b"content-length"):
                kept.append(line)

        kept.append(f"Content-Length: {len(body)}".encode())
        kept.append(b"Connection: close")

        head = (
            f"{method} {target} HTTP/1.1\r\n".encode()
            + b"\r\n".join(kept)
            + b"\r\n\r\n"
        )

        writer.write(head + body)
        await writer.drain()

        stream = Stream(reader)

        await stream.fill_until(b"\r\n\r\n", MAX_HEAD_BYTES)

        resp_head, _, stream.buf = stream.buf.partition(b"\r\n\r\n")

        status_line, _, resp_headers = resp_head.partition(b"\r\n")

        extra = b""

        if redirect_from and redirect_to and redirect_from != redirect_to:
            extra = f"{GATE_HEADER.decode()}: {redirect_from} -> {redirect_to}\r\n".encode()

        client_writer.write(
            status_line
            + b"\r\n"
            + extra
            + resp_headers
            + b"\r\n\r\n"
        )
        await client_writer.drain()

        length: int | None = None
        chunked = False

        for line in resp_headers.split(b"\r\n"):
            name, _, value = line.partition(b":")
            name = name.strip().lower()

            if name == b"content-length":
                length = int(value.strip())
            elif name == b"transfer-encoding":
                chunked = b"chunked" in value.strip().lower()

        if chunked:
            while True:
                size_line = await stream.take_line()

                client_writer.write(size_line + b"\r\n")

                try:
                    size = int(size_line.split(b";")[0], 16)
                except ValueError:
                    return

                if size == 0:
                    while (trailer := await stream.take_line()) != b"":
                        client_writer.write(trailer + b"\r\n")

                    client_writer.write(b"\r\n")
                    await client_writer.drain()
                    return

                while size:
                    n = min(size, READ_CHUNK)
                    client_writer.write(await stream.take(n))
                    size -= n

                # The CRLF after a chunk's payload is part of the wire format:
                # consume it, then re-emit our own. Skipping the read makes the
                # next size_line the empty terminator and truncates the stream.
                await stream.take(2)

                client_writer.write(b"\r\n")
                await client_writer.drain()

        elif length is not None:
            remaining = length

            while remaining:
                n = min(remaining, READ_CHUNK)
                client_writer.write(await stream.take(n))
                remaining -= n

            await client_writer.drain()

        else:
            # No framing: the upstream ends the message by closing.
            while True:
                chunk = await stream.reader.read(READ_CHUNK)

                if not chunk:
                    break

                client_writer.write(chunk)

            await client_writer.drain()

    finally:
        with contextlib.suppress(Exception):
            writer.close()


async def handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    fleet: Fleet,
) -> None:
    """One client connection: read one request, route it, reply, close."""

    try:
        method, target, header_lines, body = await asyncio.wait_for(
            read_request(Stream(reader)),
            timeout=CLIENT_HEAD_TIMEOUT,
        )

    except (TimeoutError, ConnectionError, ValueError) as exc:
        log.info("no usable request: %s", exc)
        return

    if method == "GET" and target == "/health":
        await send_local(writer, b'{"status":"ok"}')
        return

    if method == "GET" and target in ("/v1/models", "/v1/models/"):
        await send_local(writer, availability_body(fleet))
        return

    if method == "GET" and target == "/gate/state":
        await send_local(writer, state_body(fleet))
        return

    if method == "POST" and target == "/unload":
        await handle_unload(writer, fleet, body)
        return

    requested = requested_model(body)

    row = await fleet.pick(requested, request_needs(body))

    if row is None:
        await send_local(
            writer,
            json.dumps(
                {
                    "error": "no model in the fleet can serve this request",
                    "requested": requested,
                }
            ).encode(),
            503,
            "Service Unavailable",
        )
        return

    served = row.id
    redirect_from = requested if (requested and requested != served) else None

    out_body = rewrite_model(body, requested, served) if redirect_from else body

    log.info(
        "%s %s -> %s (%s:%d)%s",
        method,
        target,
        served,
        row.provider,
        row.relay,
        f" redirect from {redirect_from}" if redirect_from else "",
    )

    if row.unit is not None:
        fleet.stamp(row.unit)

    await relay_to(
        writer,
        row.relay,
        (method, target, header_lines, out_body),
        (redirect_from, served) if redirect_from else None,
    )


def requested_model(body: bytes) -> str:
    try:
        doc = json.loads(body)
    except (json.JSONDecodeError, ValueError):
        return ""

    model = doc.get("model")

    return model if isinstance(model, str) else ""


async def handle_unload(
    writer: asyncio.StreamWriter,
    fleet: Fleet,
    body: bytes,
) -> None:
    """POST /unload {"model": "<id>"}: release that model's VRAM now."""

    target = requested_model(body)

    stopped = []

    for row in fleet.rows:
        if row.unit is None:
            continue

        if row.id != target or not fleet.live(row):
            continue

        proc = subprocess_run(["systemctl", "stop", row.unit])

        if proc.returncode != 0:
            log.error("systemctl stop %s failed: %s", row.unit, proc.stderr.strip())
            continue

        stopped.append(row.unit)

    await send_local(
        writer,
        json.dumps({"stopped": stopped}).encode(),
    )


async def accept_loop(fleet: Fleet, listen: socket.socket) -> None:
    """Serve connections on the gate's own listening socket."""

    loop = asyncio.get_running_loop()

    while True:
        try:
            conn, _addr = await loop.sock_accept(listen)
        except (BlockingIOError, InterruptedError):
            await asyncio.sleep(0.05)
            continue
        except OSError:
            return

        asyncio.create_task(
            serve_connection(conn, fleet),
            name="gate-connection",
        )


async def serve_connection(conn: socket.socket, fleet: Fleet) -> None:
    loop = asyncio.get_running_loop()

    reader = asyncio.StreamReader(limit=MAX_HEAD_BYTES)
    protocol = asyncio.StreamReaderProtocol(reader)

    try:
        transport, _ = await loop.create_connection(lambda: protocol, sock=conn)
    except OSError:
        with contextlib.suppress(Exception):
            conn.close()
        return

    writer = asyncio.StreamWriter(transport, protocol, reader, loop)

    try:
        await handle_client(reader, writer, fleet)
    except asyncio.CancelledError:
        raise
    except Exception:
        log.exception("request failed")
    finally:
        writer.close()

        with contextlib.suppress(Exception):
            await writer.wait_closed()

        with contextlib.suppress(Exception):
            conn.close()


async def run(port: int, fleet: Fleet) -> int:
    """Bind the one public port and serve until SIGTERM."""

    listen = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listen.setblocking(False)
    listen.bind(("127.0.0.1", port))

    # The port must exist before this process reports itself healthy, so a
    # supervisor's /health probe cannot race the bind.
    listen.listen(1)

    log.info("gate listening on 127.0.0.1:%d (%d rows)", port, len(fleet.rows))

    stop_event = asyncio.Event()

    loop = asyncio.get_running_loop()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    accept_task = asyncio.create_task(accept_loop(fleet, listen), name="accept-loop")

    try:
        await stop_event.wait()
    finally:
        accept_task.cancel()

        with contextlib.suppress(asyncio.CancelledError):
            await accept_task

        listen.close()

    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument("--table", required=True, help="rendered routing table (JSON)")
    parser.add_argument("--port", type=int, help="override the gate port")

    args = parser.parse_args(argv)

    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter("[llm-gate] %(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"),
    )
    log.addHandler(handler)
    log.setLevel(logging.INFO)

    try:
        rows, policy = load_table(args.table)
    except (OSError, KeyError, ValueError):
        log.exception("cannot load the routing table")
        return 1

    fleet = Fleet(rows, policy)

    port = args.port or policy.port

    if port <= 0:
        log.error("no gate port")
        return 1

    try:
        return asyncio.run(run(port, fleet))
    except KeyboardInterrupt:
        return 0
    except Exception:
        log.exception("internal error")
        return 1

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
