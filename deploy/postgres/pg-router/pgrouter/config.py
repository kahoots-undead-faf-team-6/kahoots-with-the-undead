"""Settings from the environment (deploy/postgres/README.md lists them)."""
from __future__ import annotations

import os
import socket
from dataclasses import dataclass


@dataclass(frozen=True)
class NodeAddress:
    name: str  # the container name, e.g. resource-db-1
    host: str
    port: int


def parse_nodes(raw: str) -> list[NodeAddress]:
    """"resource-db-1:5432,resource-db-2:5432" -> addresses, in order (the first is the initial primary)."""
    nodes: list[NodeAddress] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        host, _, port = part.partition(":")
        if not host:
            raise ValueError(f"PG_NODES: empty host in {part!r}")
        nodes.append(NodeAddress(name=host, host=host, port=int(port or 5432)))
    if len(nodes) < 2:
        raise ValueError("PG_NODES needs at least 2 nodes (a primary and a standby)")
    if len({n.name for n in nodes}) != len(nodes):
        raise ValueError("PG_NODES has the same node twice")
    return nodes


def _int(name: str, default: int, minimum: int = 1) -> int:
    value = int(os.environ.get(name) or default)
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}")
    return value


@dataclass(frozen=True)
class Settings:
    nodes: list[NodeAddress]
    repl_user: str
    repl_password: str
    failover_checks: int
    check_interval_ms: int
    check_timeout_ms: int
    connect_wait_ms: int
    write_port: int
    read_port: int
    http_port: int
    router_name: str
    log_level: str
    log_dir: str | None

    @staticmethod
    def from_env() -> "Settings":
        password = os.environ.get("PG_REPL_PASSWORD", "")
        if not password:
            raise ValueError("PG_REPL_PASSWORD is required")
        return Settings(
            nodes=parse_nodes(os.environ.get("PG_NODES", "")),
            repl_user=os.environ.get("PG_REPL_USER") or "replicator",
            repl_password=password,
            failover_checks=_int("PG_FAILOVER_CHECKS", 3),
            check_interval_ms=_int("PG_CHECK_INTERVAL_MS", 2000, 100),
            check_timeout_ms=_int("PG_CHECK_TIMEOUT_MS", 1500, 100),
            connect_wait_ms=_int("PG_CONNECT_WAIT_MS", 10000, 0),
            write_port=_int("WRITE_PORT", 5432),
            read_port=_int("READ_PORT", 5433),
            http_port=_int("HTTP_PORT", 8008),
            router_name=os.environ.get("ROUTER_NAME") or socket.gethostname(),
            log_level=(os.environ.get("LOG_LEVEL") or "info").upper(),
            log_dir=os.environ.get("LOG_DIR") or None,
        )
