"""GET /status, /metrics and /health on HTTP_PORT (8008). A tiny HTTP/1.1 server: no framework needed."""
from __future__ import annotations

import asyncio
import json

from . import VERSION
from .cluster import Cluster
from .proxy import Proxy


def _labels(**labels: str) -> str:
    inner = ",".join(f'{k}="{str(v).replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34))}"'
                     for k, v in labels.items())
    return "{" + inner + "}"


def metrics_text(cluster: Cluster, proxy: Proxy, router: str) -> str:
    lines = [
        "# HELP pg_node_up 1 when the node answered the last check.",
        "# TYPE pg_node_up gauge",
    ]
    for s in cluster.states.values():
        lines.append(f"pg_node_up{_labels(router=router, node=s.name)} {1 if s.up else 0}")
    lines += ["# HELP pg_node_is_primary 1 for the node the router sends writes to.",
              "# TYPE pg_node_is_primary gauge"]
    for s in cluster.states.values():
        lines.append(f"pg_node_is_primary{_labels(router=router, node=s.name)} {1 if s.name == cluster.primary else 0}")
    lines += ["# HELP pg_replication_lag_bytes WAL bytes the standby has not replayed yet (primary LSN - replay LSN).",
              "# TYPE pg_replication_lag_bytes gauge"]
    for s in cluster.states.values():
        if s.lag_bytes is not None and s.name != cluster.primary:
            lines.append(f"pg_replication_lag_bytes{_labels(router=router, node=s.name)} {s.lag_bytes}")
    lines += ["# HELP pg_failovers_total Standbys promoted by this router since it started.",
              "# TYPE pg_failovers_total counter",
              f"pg_failovers_total{_labels(router=router)} {cluster.failovers_total}",
              "# HELP pg_router_connections Client connections open through the router.",
              "# TYPE pg_router_connections gauge"]
    for port, count in proxy.counts.items():
        lines.append(f"pg_router_connections{_labels(router=router, port=port)} {count}")
    return "\n".join(lines) + "\n"


def status_body(cluster: Cluster, proxy: Proxy, router: str) -> dict:
    body = {"router": router, "version": VERSION}
    body.update(cluster.status())
    body["connections"] = dict(proxy.counts)
    return body


class HttpApi:
    def __init__(self, cluster: Cluster, proxy: Proxy, router: str) -> None:
        self.cluster = cluster
        self.proxy = proxy
        self.router = router

    def respond(self, method: str, path: str) -> tuple[int, str, bytes]:
        path = path.split("?", 1)[0].rstrip("/") or "/"
        if method not in ("GET", "HEAD"):
            return 405, "application/json", b'{"error":"METHOD_NOT_ALLOWED"}'
        if path == "/status":
            return 200, "application/json", json.dumps(status_body(self.cluster, self.proxy, self.router)).encode()
        if path == "/metrics":
            return 200, "text/plain; version=0.0.4", metrics_text(self.cluster, self.proxy, self.router).encode()
        if path == "/health":
            ok = self.cluster.primary is not None
            body = {"status": "ok" if ok else "no-primary", "primary": self.cluster.primary}
            return (200 if ok else 503), "application/json", json.dumps(body).encode()
        return 404, "application/json", b'{"error":"NOT_FOUND"}'

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            request_line = await asyncio.wait_for(reader.readline(), 5)
            while True:  # skip the headers
                line = await asyncio.wait_for(reader.readline(), 5)
                if line in (b"\r\n", b"\n", b""):
                    break
            parts = request_line.decode("latin-1").split()
            if len(parts) < 2:
                return
            status, ctype, body = self.respond(parts[0], parts[1])
            reason = {200: "OK", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"}[status]
            head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n"
                    "Connection: close\r\n\r\n").encode()
            writer.write(head + (b"" if parts[0] == "HEAD" else body))
            await writer.drain()
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            writer.close()
