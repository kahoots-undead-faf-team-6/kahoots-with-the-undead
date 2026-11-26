"""python -m pgrouter: starts the write port, the read port, the HTTP API and the check loop."""
from __future__ import annotations

import asyncio
import signal

from . import VERSION
from .backend import PgBackend
from .cluster import Cluster
from .config import Settings
from .http import HttpApi
from .log import Logger
from .proxy import Proxy


async def run(settings: Settings) -> None:
    log = Logger(instance_id=settings.router_name, level=settings.log_level, log_dir=settings.log_dir)
    timeout_s = settings.check_timeout_ms / 1000
    backend = PgBackend(settings.repl_user, settings.repl_password, timeout_s)
    cluster = Cluster(nodes=settings.nodes, backend=backend, log=log, failover_checks=settings.failover_checks,
                      check_timeout_s=timeout_s * 2)
    proxy = Proxy(cluster, log, connect_wait_s=settings.connect_wait_ms / 1000)
    cluster.on_primary_change = proxy.on_primary_change
    api = HttpApi(cluster, proxy, settings.router_name)

    servers = [
        await asyncio.start_server(lambda r, w: proxy.handle(r, w, "write"), "0.0.0.0", settings.write_port),
        await asyncio.start_server(lambda r, w: proxy.handle(r, w, "read"), "0.0.0.0", settings.read_port),
        await asyncio.start_server(api.handle, "0.0.0.0", settings.http_port),
    ]
    log.info("pg-router started", version=VERSION, nodes=[n.name for n in settings.nodes],
             writePort=settings.write_port, readPort=settings.read_port, httpPort=settings.http_port,
             failoverChecks=settings.failover_checks, checkIntervalMs=settings.check_interval_ms)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)  # PID 1 in a container ignores SIGTERM without a handler
        except (NotImplementedError, RuntimeError):
            pass

    interval = settings.check_interval_ms / 1000
    while not stop.is_set():
        started = loop.time()
        try:
            await cluster.tick()
        except Exception as exc:  # a bug in one round must not stop the router
            log.error("check round failed", err=repr(exc))
        try:
            await asyncio.wait_for(stop.wait(), max(0.0, interval - (loop.time() - started)))
        except asyncio.TimeoutError:
            pass

    log.info("pg-router stopping")
    for server in servers:
        server.close()


def main() -> None:
    asyncio.run(run(Settings.from_env()))


if __name__ == "__main__":
    main()
