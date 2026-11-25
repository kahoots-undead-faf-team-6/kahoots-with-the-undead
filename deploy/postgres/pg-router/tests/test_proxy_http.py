import asyncio
import io
import json

import pytest

from pgrouter.backend import conninfo_value, primary_conninfo, sql_literal
from pgrouter.cluster import Cluster
from pgrouter.config import NodeAddress, Settings
from pgrouter.http import HttpApi, metrics_text
from pgrouter.log import Logger
from pgrouter.proxy import Proxy

from test_cluster import FakeBackend, N1, N2, N3


def run(coro):
    return asyncio.run(coro)


async def echo_server():
    """Stands in for a PostgreSQL node: echoes what it gets, prefixed with b'>'."""
    async def handle(reader, writer):
        while data := await reader.read(1024):
            writer.write(b">" + data)
            await writer.drain()
        writer.close()
    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    return server, server.sockets[0].getsockname()[1]


def test_proxy_copies_bytes_to_the_primary_and_closes_them_on_failover():
    async def scenario():
        node_server, node_port = await echo_server()
        node = NodeAddress("db-1", "127.0.0.1", node_port)
        cluster = Cluster(nodes=[node, N2], backend=FakeBackend(), log=Logger(stream=io.StringIO()))
        cluster.primary = "db-1"
        proxy = Proxy(cluster, Logger(stream=io.StringIO()), connect_wait_s=0.2)
        server = await asyncio.start_server(lambda r, w: proxy.handle(r, w, "write"), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"hello")
        await writer.drain()
        assert await reader.read(100) == b">hello"
        assert proxy.counts["write"] == 1

        await proxy.on_primary_change("db-1", "db-2")
        assert await asyncio.wait_for(reader.read(100), 2) == b""  # connection closed
        writer.close()
        server.close()
        node_server.close()

    run(scenario())


def test_proxy_closes_the_client_when_there_is_no_primary():
    async def scenario():
        cluster = Cluster(nodes=[N1, N2], backend=FakeBackend(), log=Logger(stream=io.StringIO()))
        proxy = Proxy(cluster, Logger(stream=io.StringIO()), connect_wait_s=0.1)
        server = await asyncio.start_server(lambda r, w: proxy.handle(r, w, "write"), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        assert await asyncio.wait_for(reader.read(100), 2) == b""
        writer.close()
        server.close()

    run(scenario())


def test_proxy_closes_the_client_when_the_node_refuses():
    async def scenario():
        dead = NodeAddress("db-1", "127.0.0.1", 1)
        cluster = Cluster(nodes=[dead, N2], backend=FakeBackend(), log=Logger(stream=io.StringIO()))
        cluster.primary = "db-1"
        proxy = Proxy(cluster, Logger(stream=io.StringIO()), connect_wait_s=0.1, connect_timeout_s=0.5)
        server = await asyncio.start_server(lambda r, w: proxy.handle(r, w, "write"), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        assert await asyncio.wait_for(reader.read(100), 3) == b""
        writer.close()
        server.close()

    run(scenario())


def make_api():
    cluster = Cluster(nodes=[N1, N2, N3], backend=FakeBackend(), log=Logger(stream=io.StringIO()))
    run(cluster.tick())
    proxy = Proxy(cluster, Logger(stream=io.StringIO()), connect_wait_s=0)
    return HttpApi(cluster, proxy, "resource-db"), cluster, proxy


def test_status_lists_role_state_and_lag_of_every_node():
    api, _, _ = make_api()
    status, ctype, body = api.respond("GET", "/status")
    data = json.loads(body)
    assert status == 200 and ctype == "application/json"
    assert data["router"] == "resource-db" and data["primary"] == "db-1"
    assert [(n["name"], n["role"], n["state"], n["lagBytes"]) for n in data["nodes"]] == [
        ("db-1", "primary", "up", 0), ("db-2", "standby", "up", 0), ("db-3", "standby", "up", 0)]


def test_metrics_and_health():
    api, cluster, proxy = make_api()
    text = metrics_text(cluster, proxy, "resource-db")
    assert 'pg_node_up{router="resource-db",node="db-2"} 1' in text
    assert 'pg_replication_lag_bytes{router="resource-db",node="db-3"} 0' in text
    assert 'pg_failovers_total{router="resource-db"} 0' in text
    assert 'pg_node_is_primary{router="resource-db",node="db-1"} 1' in text
    assert api.respond("GET", "/health")[0] == 200
    cluster.primary = None
    assert api.respond("GET", "/health")[0] == 503
    assert api.respond("GET", "/nope")[0] == 404
    assert api.respond("POST", "/status")[0] == 405


def test_http_server_end_to_end():
    api, _, _ = make_api()

    async def scenario():
        server = await asyncio.start_server(api.handle, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"GET /status HTTP/1.1\r\nHost: x\r\n\r\n")
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), 2)
        head, _, body = raw.partition(b"\r\n\r\n")
        assert head.startswith(b"HTTP/1.1 200 OK")
        assert json.loads(body)["primary"] == "db-1"
        server.close()

    run(scenario())


def test_conninfo_and_sql_quoting():
    assert conninfo_value("a'b\\c") == "'a\\'b\\\\c'"
    assert sql_literal("it's") == "'it''s'"
    info = primary_conninfo(NodeAddress("db-2", "db-2", 5432), "replicator", "p'w", "db-3")
    assert info == "host='db-2' port=5432 user='replicator' password='p\\'w' application_name='db-3'"


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("PG_NODES", "resource-db-1:5432,resource-db-2:5432,resource-db-3:5432")
    monkeypatch.setenv("PG_REPL_PASSWORD", "secret")
    monkeypatch.setenv("ROUTER_NAME", "resource-db")
    s = Settings.from_env()
    assert (s.failover_checks, s.check_interval_ms, s.write_port, s.read_port, s.http_port) == (3, 2000, 5432, 5433, 8008)
    assert s.repl_user == "replicator" and s.router_name == "resource-db"
    monkeypatch.setenv("PG_REPL_PASSWORD", "")
    with pytest.raises(ValueError):
        Settings.from_env()
    monkeypatch.setenv("PG_REPL_PASSWORD", "x")
    monkeypatch.setenv("PG_FAILOVER_CHECKS", "0")
    with pytest.raises(ValueError):
        Settings.from_env()


def test_logger_writes_json_and_respects_the_level(tmp_path):
    out = io.StringIO()
    log = Logger(instance_id="resource-db", level="WARN", log_dir=str(tmp_path), stream=out)
    log.info("hidden")
    log.warn("shown", node="db-1", empty=None)
    lines = [json.loads(line) for line in out.getvalue().splitlines()]
    assert [line["msg"] for line in lines] == ["shown"]
    assert lines[0]["node"] == "db-1" and "empty" not in lines[0]
    assert (tmp_path / "resource-db.log").read_text().count("shown") == 1
