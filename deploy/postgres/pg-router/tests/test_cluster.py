import asyncio
import io
import json

import pytest

from pgrouter.cluster import CheckResult, Cluster, parse_lsn, slot_name
from pgrouter.config import NodeAddress, parse_nodes
from pgrouter.log import Logger

N1, N2, N3 = (NodeAddress(f"db-{i}", f"db-{i}", 5432) for i in (1, 2, 3))


class FakeBackend:
    """Each node is a dict: None = unreachable, else in_recovery / lsn / timeline / sender."""

    def __init__(self):
        self.nodes = {
            "db-1": {"rec": False, "lsn": 1000, "tli": 1, "sender": None},
            "db-2": {"rec": True, "lsn": 1000, "tli": None, "sender": "db-1"},
            "db-3": {"rec": True, "lsn": 1000, "tli": None, "sender": "db-1"},
        }
        self.calls = []
        self.fail_promote = False

    async def check(self, node):
        n = self.nodes[node.name]
        if n is None:
            raise ConnectionRefusedError("connection refused")
        return CheckResult(in_recovery=n["rec"], lsn=n["lsn"], timeline=n["tli"], sender_host=n["sender"])

    async def promote(self, node):
        self.calls.append(("promote", node.name))
        if self.fail_promote:
            raise RuntimeError("boom")
        n = self.nodes[node.name]
        n.update(rec=False, tli=2, sender=None)

    async def ensure_slot(self, primary, slot):
        self.calls.append(("slot", primary.name, slot))

    async def repoint(self, standby, primary, slot):
        self.calls.append(("repoint", standby.name, primary.name, slot))
        self.nodes[standby.name]["sender"] = primary.host


def make(backend=None, checks=3):
    out = io.StringIO()
    backend = backend or FakeBackend()
    changes = []
    cluster = Cluster(nodes=[N1, N2, N3], backend=backend, log=Logger(stream=out), failover_checks=checks,
                      on_primary_change=lambda old, new: changes.append((old, new)))
    return cluster, backend, out, changes


def run(coro):
    return asyncio.run(coro)


async def ticks(cluster, n):
    for _ in range(n):
        await cluster.tick()


def logs(out):
    return [json.loads(line) for line in out.getvalue().splitlines()]


def test_finds_the_primary_and_the_standbys():
    cluster, backend, _, changes = make()
    run(cluster.tick())
    assert cluster.primary == "db-1"
    assert [cluster.role(s) for s in cluster.states.values()] == ["primary", "standby", "standby"]
    assert changes == [(None, "db-1")]
    assert backend.calls == []  # standbys already stream from db-1: nothing re-pointed


def test_lag_is_primary_lsn_minus_replay_lsn():
    cluster, backend, _, _ = make()
    backend.nodes["db-1"]["lsn"] = 5000
    backend.nodes["db-2"]["lsn"] = 4000
    run(cluster.tick())
    status = {n["name"]: n for n in cluster.status()["nodes"]}
    assert status["db-1"]["lagBytes"] == 0
    assert status["db-2"]["lagBytes"] == 1000
    assert status["db-3"]["lagBytes"] == 4000


def test_no_failover_before_n_failed_checks():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    backend.nodes["db-1"] = None
    run(ticks(cluster, 2))
    assert cluster.primary == "db-1"
    assert ("promote", "db-2") not in backend.calls and ("promote", "db-3") not in backend.calls


def test_a_check_that_recovers_resets_the_counter():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    saved = backend.nodes["db-1"]
    backend.nodes["db-1"] = None
    run(ticks(cluster, 2))
    backend.nodes["db-1"] = saved
    run(cluster.tick())
    backend.nodes["db-1"] = None
    run(ticks(cluster, 2))
    assert cluster.primary == "db-1" and cluster.failovers_total == 0


def test_failover_promotes_the_standby_with_the_smallest_lag_and_repoints_the_other():
    cluster, backend, out, changes = make()
    run(cluster.tick())
    backend.nodes["db-2"]["lsn"] = 900
    backend.nodes["db-3"]["lsn"] = 950  # db-3 replayed more: smallest lag
    backend.nodes["db-1"] = None
    run(ticks(cluster, 3))
    assert cluster.primary == "db-3"
    assert cluster.failovers_total == 1
    assert ("promote", "db-3") in backend.calls
    assert ("slot", "db-3", "db_2") in backend.calls
    assert ("repoint", "db-2", "db-3", "db_2") in backend.calls
    assert changes[-1] == ("db-1", "db-3")
    assert any(line["msg"] == "failover done" for line in logs(out))


def test_on_a_tie_the_first_node_in_pg_nodes_wins():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    backend.nodes["db-1"] = None
    run(ticks(cluster, 3))
    assert cluster.primary == "db-2"


def test_the_old_primary_coming_back_is_fenced_and_gets_no_connections():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    old = backend.nodes["db-1"]
    backend.nodes["db-1"] = None
    run(ticks(cluster, 3))
    backend.nodes["db-1"] = old  # comes back writable, on the old timeline
    run(cluster.tick())
    assert cluster.primary == "db-2"
    assert cluster.role(cluster.states["db-1"]) == "fenced"
    assert cluster.write_target().name == "db-2"
    assert all(cluster.read_target().name != "db-1" for _ in range(6))


def test_a_fenced_node_recloned_as_standby_is_a_standby_again():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    old = backend.nodes["db-1"]
    backend.nodes["db-1"] = None
    run(ticks(cluster, 3))
    backend.nodes["db-1"] = old
    run(cluster.tick())
    backend.nodes["db-1"] = {"rec": True, "lsn": 1000, "tli": None, "sender": "db-2"}  # re-cloned
    run(cluster.tick())
    assert cluster.role(cluster.states["db-1"]) == "standby"


def test_router_restart_after_failover_picks_the_highest_timeline():
    backend = FakeBackend()
    backend.nodes["db-1"] = {"rec": False, "lsn": 1000, "tli": 1, "sender": None}  # old primary, came back
    backend.nodes["db-2"] = {"rec": False, "lsn": 900, "tli": 2, "sender": None}  # promoted
    cluster, _, _, _ = make(backend)
    run(cluster.tick())
    assert cluster.primary == "db-2"
    assert cluster.role(cluster.states["db-1"]) == "fenced"


def test_router_started_while_the_primary_is_down_promotes_after_n_checks():
    backend = FakeBackend()
    backend.nodes["db-1"] = None
    cluster, _, _, _ = make(backend)
    run(ticks(cluster, 2))
    assert cluster.primary is None
    run(cluster.tick())
    assert cluster.primary == "db-2"


def test_first_start_never_promotes_when_no_standby_is_up():
    backend = FakeBackend()
    backend.nodes = {"db-1": None, "db-2": None, "db-3": None}
    cluster, _, _, _ = make(backend)
    run(ticks(cluster, 10))
    assert cluster.primary is None and backend.calls == []


def test_failed_promotion_is_retried():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    backend.nodes["db-1"] = None
    backend.fail_promote = True
    run(ticks(cluster, 3))
    assert cluster.primary == "db-1" and cluster.failovers_total == 0
    backend.fail_promote = False
    run(cluster.tick())
    assert cluster.primary == "db-2" and cluster.failovers_total == 1


def test_no_standby_left_means_no_primary_until_a_node_returns():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    old = backend.nodes["db-1"]
    backend.nodes = {"db-1": None, "db-2": None, "db-3": None}
    run(ticks(cluster, 3))
    assert cluster.primary is None and cluster.write_target() is None
    backend.nodes["db-1"] = old
    run(cluster.tick())
    assert cluster.primary == "db-1" and cluster.failovers_total == 0


def test_primary_in_recovery_counts_as_failed():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    backend.nodes["db-1"]["rec"] = True
    run(ticks(cluster, 3))
    assert cluster.primary != "db-1"


def test_a_standby_down_during_the_failover_is_repointed_when_it_returns():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    db3 = backend.nodes["db-3"]
    backend.nodes["db-1"] = None
    backend.nodes["db-3"] = None
    run(ticks(cluster, 3))
    assert cluster.primary == "db-2"
    db3["sender"] = None  # its WAL receiver cannot reach db-1
    backend.nodes["db-3"] = db3
    run(cluster.tick())
    assert ("repoint", "db-3", "db-2", "db_3") in backend.calls
    calls = len(backend.calls)
    run(cluster.tick())
    assert len(backend.calls) == calls  # only once


def test_read_target_round_robins_standbys_and_falls_back_to_the_primary():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    seen = {cluster.read_target().name for _ in range(4)}
    assert seen == {"db-2", "db-3"}
    backend.nodes["db-2"] = None
    backend.nodes["db-3"] = None
    run(cluster.tick())
    assert cluster.read_target().name == "db-1"


def test_check_timeout_is_a_failed_check():
    class Slow(FakeBackend):
        async def check(self, node):
            if node.name == "db-1":
                await asyncio.sleep(1)
            return await super().check(node)

    cluster, _, _, _ = make(Slow())
    cluster.check_timeout_s = 0.05
    run(cluster.tick())
    assert cluster.states["db-1"].up is False
    assert "no answer" in cluster.states["db-1"].last_error


def test_helpers():
    assert slot_name("Resource-DB-2") == "resource_db_2"
    assert parse_lsn("16/B374D848") == (0x16 << 32) | 0xB374D848
    assert parse_lsn(None) is None
    assert [n.name for n in parse_nodes("a:5432, b ,c:6000")] == ["a", "b", "c"]
    assert parse_nodes("a,b")[1].port == 5432
    with pytest.raises(ValueError):
        parse_nodes("a")
    with pytest.raises(ValueError):
        parse_nodes("a,a")
    with pytest.raises(ValueError):
        parse_nodes(":1,b")


def test_standbys_are_never_repointed_to_a_primary_that_is_down():
    cluster, backend, _, _ = make()
    run(cluster.tick())
    backend.nodes["db-1"] = None
    backend.nodes["db-2"]["sender"] = None  # their WAL receivers lost the primary
    backend.nodes["db-3"]["sender"] = None
    run(ticks(cluster, 2))
    assert not [c for c in backend.calls if c[0] in ("slot", "repoint")]
