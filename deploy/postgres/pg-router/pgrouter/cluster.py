"""Who is the primary: health checks, failover, fencing and re-pointing the standbys.

The decisions live here and the database work in a Backend (pgrouter.backend.PgBackend in production,
a fake in the tests), so every rule below is unit tested without PostgreSQL.

Rules (deploy/postgres/README.md):
- every PG_CHECK_INTERVAL_MS each node is checked (connect + pg_is_in_recovery());
- the primary failing PG_FAILOVER_CHECKS checks in a row -> the reachable standby with the highest replayed
  LSN (the smallest lag) is promoted, the other standbys are re-pointed to it, the old connections closed;
- a node that is not in recovery but is not the primary (the old primary coming back) is fenced: it never
  gets connections until it is re-cloned as a standby;
- when the router starts, the primary is the node that is not in recovery (on the highest timeline if,
  after a failover, the old primary is also up).
"""
from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Awaitable, Callable, Protocol

from .config import NodeAddress
from .log import Logger


@dataclass(frozen=True)
class CheckResult:
    in_recovery: bool
    lsn: int | None  # current WAL LSN on a primary, last replayed LSN on a standby
    timeline: int | None = None  # primaries only
    sender_host: str | None = None  # standbys only: the host their WAL receiver streams from


class Backend(Protocol):
    async def check(self, node: NodeAddress) -> CheckResult: ...
    async def promote(self, node: NodeAddress) -> None: ...
    async def ensure_slot(self, primary: NodeAddress, slot: str) -> None: ...
    async def repoint(self, standby: NodeAddress, primary: NodeAddress, slot: str) -> None: ...


def slot_name(node_name: str) -> str:
    """resource-db-2 -> resource_db_2 (deploy/postgres/standby-entrypoint.sh uses the same rule)."""
    return re.sub(r"[^a-z0-9_]", "_", node_name.lower())


def parse_lsn(text: str | None) -> int | None:
    """'16/B374D848' -> an integer, so lags are a subtraction."""
    if not text:
        return None
    hi, _, lo = text.partition("/")
    return (int(hi, 16) << 32) | int(lo, 16)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclass
class NodeState:
    addr: NodeAddress
    order: int
    up: bool = False
    in_recovery: bool | None = None
    lsn: int | None = None
    timeline: int | None = None
    sender_host: str | None = None
    failures: int = 0  # checks failed in a row
    last_error: str | None = None
    last_check_at: str | None = None
    fenced: bool = False
    repointed_to: str | None = None
    lag_bytes: int | None = None

    @property
    def name(self) -> str:
        return self.addr.name

    @property
    def is_standby(self) -> bool:
        return self.up and self.in_recovery is True and not self.fenced


@dataclass
class Cluster:
    nodes: list[NodeAddress]
    backend: Backend
    log: Logger
    failover_checks: int = 3
    check_timeout_s: float = 1.5
    on_primary_change: Callable[[str | None, str], Awaitable[None] | None] | None = None
    primary: str | None = None
    failovers_total: int = 0
    states: dict[str, NodeState] = field(default_factory=dict)
    _no_primary_checks: int = 0
    _primary_bad_checks: int = 0  # the primary failed (unreachable or read-only) this many checks in a row
    _read_rr: int = 0

    def __post_init__(self) -> None:
        self.states = {n.name: NodeState(addr=n, order=i) for i, n in enumerate(self.nodes)}

    # ---------- one round of checks ----------

    async def tick(self) -> None:
        results = await asyncio.gather(*(self._check(s) for s in self.states.values()))
        for state, result in zip(self.states.values(), results):
            self._record(state, result)

        if self.primary is None:
            await self._without_primary()
        else:
            await self._watch_primary()

        self._fence_and_unfence()
        await self._repoint_standbys()
        self._update_lags()

    async def _check(self, state: NodeState) -> CheckResult | Exception:
        try:
            return await asyncio.wait_for(self.backend.check(state.addr), self.check_timeout_s)
        except asyncio.TimeoutError:
            return TimeoutError(f"no answer within {self.check_timeout_s:g}s")
        except Exception as exc:  # any failure is a failed check
            return exc

    def _record(self, state: NodeState, result: CheckResult | Exception) -> None:
        state.last_check_at = _now()
        if isinstance(result, Exception):
            if state.up or state.failures == 0:
                self.log.warn("node check failed", node=state.name, err=str(result) or type(result).__name__)
            state.up = False
            state.failures += 1
            state.last_error = str(result) or type(result).__name__
            state.sender_host = None
            return
        if not state.up and state.failures:
            self.log.info("node is reachable again", node=state.name, inRecovery=result.in_recovery)
        state.up = True
        state.failures = 0
        state.last_error = None
        state.in_recovery = result.in_recovery
        state.lsn = result.lsn
        state.timeline = result.timeline
        state.sender_host = result.sender_host

    # ---------- choosing the primary ----------

    async def _without_primary(self) -> None:
        writable = [s for s in self.states.values() if s.up and s.in_recovery is False]
        if writable:
            best = max(writable, key=lambda s: (s.timeline or 0, s.lsn or 0, -s.order))
            self.primary = best.name
            self._no_primary_checks = 0
            self.log.info("primary found", node=best.name, timeline=best.timeline)
            await self._notify(None, best.name)
            return
        # No writable node. Only promote when standbys are up: at the first start the standbys are
        # still waiting for the primary to clone it, so this cannot promote an empty node.
        if any(s.is_standby for s in self.states.values()):
            self._no_primary_checks += 1
            if self._no_primary_checks >= self.failover_checks:
                await self._failover(None)

    async def _watch_primary(self) -> None:
        state = self.states[self.primary]
        if state.up and state.in_recovery is False:
            self._primary_bad_checks = 0
            return
        if state.up:  # reachable but read-only: it cannot take writes, so it counts as a failed check
            state.last_error = "the primary is in recovery (read-only)"
        self._primary_bad_checks += 1
        if self._primary_bad_checks >= self.failover_checks:
            self.log.error("primary is down", node=state.name, failedChecks=self._primary_bad_checks,
                           err=state.last_error)
            await self._failover(state.name)

    async def _failover(self, old: str | None) -> None:
        candidates = [s for s in self.states.values() if s.is_standby and s.name != old]
        if not candidates:
            if self.primary is not None or self._no_primary_checks == self.failover_checks:
                self.log.error("no standby to promote, waiting for a node to come back", oldPrimary=old)
            self.primary = None
            self._primary_bad_checks = 0
            return
        # Smallest lag = highest replayed LSN; on a tie, the first in PG_NODES.
        best = max(candidates, key=lambda s: (s.lsn or 0, -s.order))
        self.log.warn("failover: promoting standby", oldPrimary=old, newPrimary=best.name,
                      replayLsn=best.lsn)
        try:
            await self.backend.promote(best.addr)
        except Exception as exc:
            self.log.error("promotion failed, retrying at the next check", node=best.name, err=str(exc))
            return
        self.primary = best.name
        self.failovers_total += 1
        self._no_primary_checks = 0
        self._primary_bad_checks = 0
        best.in_recovery = False
        best.repointed_to = None
        best.sender_host = None
        self.log.warn("failover done", oldPrimary=old, newPrimary=best.name, failovers=self.failovers_total)
        await self._notify(old, best.name)
        for other in candidates:
            if other is not best:
                await self._repoint(other, best)

    async def _notify(self, old: str | None, new: str) -> None:
        if self.on_primary_change:
            result = self.on_primary_change(old, new)
            if asyncio.iscoroutine(result):
                await result

    # ---------- fencing and standbys ----------

    def _fence_and_unfence(self) -> None:
        for state in self.states.values():
            if state.name == self.primary or not state.up:
                continue
            if state.in_recovery is False and not state.fenced:
                state.fenced = True
                self.log.error("node is writable but not the primary: fenced, it gets no connections "
                               "until it is re-cloned as a standby (deploy/postgres/README.md)",
                               node=state.name, primary=self.primary)
            elif state.in_recovery is True and state.fenced:
                state.fenced = False
                self.log.info("fenced node came back as a standby", node=state.name)

    async def _repoint_standbys(self) -> None:
        if self.primary is None:
            return
        primary = self.states[self.primary]
        if not (primary.up and primary.in_recovery is False):
            return  # never point standbys at a primary that is not answering (a failover may follow)
        for state in self.states.values():
            if (state.is_standby and state.name != self.primary
                    and state.sender_host != primary.addr.host and state.repointed_to != primary.name):
                await self._repoint(state, primary)

    async def _repoint(self, standby: NodeState, primary: NodeState) -> None:
        slot = slot_name(standby.name)
        try:
            await self.backend.ensure_slot(primary.addr, slot)
            await self.backend.repoint(standby.addr, primary.addr, slot)
        except Exception as exc:
            self.log.error("could not re-point standby, retrying at the next check", node=standby.name,
                           primary=primary.name, err=str(exc))
            return
        standby.repointed_to = primary.name
        self.log.info("standby re-pointed to the primary", node=standby.name, primary=primary.name, slot=slot)

    def _update_lags(self) -> None:
        primary_lsn = self.states[self.primary].lsn if self.primary else None
        for state in self.states.values():
            if state.name == self.primary:
                state.lag_bytes = 0
            elif state.is_standby and primary_lsn is not None and state.lsn is not None:
                state.lag_bytes = max(0, primary_lsn - state.lsn)
            else:
                state.lag_bytes = None

    # ---------- what the proxy and the HTTP API use ----------

    def write_target(self) -> NodeAddress | None:
        return self.states[self.primary].addr if self.primary else None

    def read_target(self) -> NodeAddress | None:
        """Round robin over the healthy standbys; the primary when there is none (reads still work)."""
        standbys = [s for s in self.states.values() if s.is_standby and s.name != self.primary]
        if not standbys:
            return self.write_target()
        self._read_rr = (self._read_rr + 1) % len(standbys)
        return standbys[self._read_rr].addr

    def role(self, state: NodeState) -> str:
        if state.name == self.primary:
            return "primary"
        if state.fenced:
            return "fenced"
        if state.up and state.in_recovery:
            return "standby"
        return "unknown"

    def status(self) -> dict:
        return {
            "primary": self.primary,
            "failovers": self.failovers_total,
            "nodes": [
                {
                    "name": s.name,
                    "host": s.addr.host,
                    "port": s.addr.port,
                    "role": self.role(s),
                    "state": "up" if s.up else "down",
                    "inRecovery": s.in_recovery,
                    "lagBytes": s.lag_bytes,
                    "streamingFrom": s.sender_host,
                    "failedChecks": s.failures,
                    "lastError": s.last_error,
                    "lastCheckAt": s.last_check_at,
                }
                for s in self.states.values()
            ],
        }
