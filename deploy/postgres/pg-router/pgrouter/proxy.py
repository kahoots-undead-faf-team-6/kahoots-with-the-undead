"""The TCP side: clients connect to the router as if it were PostgreSQL, bytes are copied both ways.

Port WRITE_PORT (5432) goes to the current primary, READ_PORT (5433) to a standby (round robin).
The router never parses the PostgreSQL protocol, so TLS, auth and COPY pass through unchanged.
"""
from __future__ import annotations

import asyncio

from .cluster import Cluster
from .config import NodeAddress
from .log import Logger

CHUNK = 64 * 1024


async def _pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await src.read(CHUNK)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        _close(dst)


def _close(writer: asyncio.StreamWriter) -> None:
    try:
        writer.close()
    except Exception:
        pass


class Proxy:
    def __init__(self, cluster: Cluster, log: Logger, connect_wait_s: float, connect_timeout_s: float = 3.0) -> None:
        self.cluster = cluster
        self.log = log
        self.connect_wait_s = connect_wait_s
        self.connect_timeout_s = connect_timeout_s
        # node name -> open (client, upstream) pairs, closed when that node stops being the primary
        self.connections: dict[str, set[tuple[asyncio.StreamWriter, asyncio.StreamWriter]]] = {}
        self.counts = {"write": 0, "read": 0}

    async def _target(self, mode: str) -> NodeAddress | None:
        """During a failover there is no primary for a few seconds: new clients wait instead of failing."""
        pick = self.cluster.write_target if mode == "write" else self.cluster.read_target
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.connect_wait_s
        while True:
            target = pick()
            if target is not None or loop.time() >= deadline:
                return target
            await asyncio.sleep(0.1)

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, mode: str) -> None:
        target = await self._target(mode)
        if target is None:
            self.log.warn("no node to send the connection to, closing it", port=mode)
            _close(writer)
            return
        try:
            up_reader, up_writer = await asyncio.wait_for(
                asyncio.open_connection(target.host, target.port), self.connect_timeout_s)
        except (OSError, asyncio.TimeoutError) as exc:
            self.log.warn("could not reach the node", node=target.name, port=mode, err=str(exc) or type(exc).__name__)
            _close(writer)
            return
        pair = (writer, up_writer)
        self.connections.setdefault(target.name, set()).add(pair)
        self.counts[mode] += 1
        try:
            await asyncio.gather(_pipe(reader, up_writer), _pipe(up_reader, writer))
        finally:
            self.connections.get(target.name, set()).discard(pair)
            self.counts[mode] -= 1

    def close_node(self, name: str) -> int:
        """Closes every connection to a node (the old primary after a failover). Returns how many."""
        pairs = self.connections.pop(name, set())
        for client, upstream in pairs:
            _close(client)
            _close(upstream)
        return len(pairs)

    async def on_primary_change(self, old: str | None, new: str) -> None:
        if old is not None:
            closed = self.close_node(old)
            self.log.info("closed the connections to the old primary", node=old, connections=closed)
