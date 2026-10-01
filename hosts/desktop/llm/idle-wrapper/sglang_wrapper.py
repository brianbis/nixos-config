#!/usr/bin/env python3
"""
Lifecycle wrapper for a native child-process model server (sglang).

The child-process lifecycle is the NInfer one — spawn the child, poll /health
until it answers, terminate it after the idle window — so this backend reuses
ninfer_wrapper.py's ensure/stop and only carries its own defaults and CLI.
Nothing here tracks in-flight requests: the gate heartbeats the activity file
while a request is in flight, which keeps the model loaded for the whole
generation, and unloading it is what releases the VRAM.
"""

from __future__ import annotations

import argparse

from idle_wrapper import Backend, main
from ninfer_wrapper import (
    DEFAULT_IDLE_SECONDS,
    DEFAULT_KILL_TIMEOUT,
    DEFAULT_READY_TIMEOUT,
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


BACKEND = Backend(
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
    add_args=add_args,
    validate=validate,
)


if __name__ == "__main__":
    raise SystemExit(main(BACKEND))
