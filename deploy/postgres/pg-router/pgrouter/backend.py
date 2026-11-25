"""The database side of the router (asyncpg), as the replication user.

The user needs no superuser rights: deploy/postgres/init-replication.sh grants it exactly what is used here
(pg_monitor, pg_promote, ALTER SYSTEM on primary_conninfo / primary_slot_name, pg_reload_conf).
"""
from __future__ import annotations

import asyncpg

from .cluster import CheckResult, parse_lsn
from .config import NodeAddress

STANDBY_SQL = """
SELECT COALESCE(pg_last_wal_replay_lsn(), pg_last_wal_receive_lsn())::text AS lsn,
       (SELECT sender_host FROM pg_stat_wal_receiver LIMIT 1) AS sender_host
"""

# The timeline is the first 8 hex digits of the current WAL file name (pg_control_checkpoint() would need
# more rights and is only updated at the next checkpoint after a promotion).
PRIMARY_SQL = """
SELECT pg_current_wal_lsn()::text AS lsn, pg_walfile_name(pg_current_wal_lsn()) AS walfile
"""


def conninfo_value(value: str) -> str:
    """A libpq connection string value: quoted, with \\ and ' escaped."""
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def primary_conninfo(primary: NodeAddress, user: str, password: str, application_name: str) -> str:
    return " ".join([
        f"host={conninfo_value(primary.host)}",
        f"port={primary.port}",
        f"user={conninfo_value(user)}",
        f"password={conninfo_value(password)}",
        f"application_name={conninfo_value(application_name)}",
    ])


class PgBackend:
    def __init__(self, user: str, password: str, timeout_s: float, database: str = "postgres") -> None:
        self.user = user
        self.password = password
        self.timeout_s = timeout_s
        self.database = database

    async def _connect(self, node: NodeAddress) -> asyncpg.Connection:
        return await asyncpg.connect(host=node.host, port=node.port, user=self.user, password=self.password,
                                     database=self.database, timeout=self.timeout_s)

    async def check(self, node: NodeAddress) -> CheckResult:
        conn = await self._connect(node)
        try:
            in_recovery = await conn.fetchval("SELECT pg_is_in_recovery()", timeout=self.timeout_s)
            if in_recovery:
                row = await conn.fetchrow(STANDBY_SQL, timeout=self.timeout_s)
                return CheckResult(in_recovery=True, lsn=parse_lsn(row["lsn"]), sender_host=row["sender_host"])
            row = await conn.fetchrow(PRIMARY_SQL, timeout=self.timeout_s)
            return CheckResult(in_recovery=False, lsn=parse_lsn(row["lsn"]), timeline=int(row["walfile"][:8], 16))
        finally:
            await conn.close(timeout=self.timeout_s)

    async def promote(self, node: NodeAddress) -> None:
        conn = await self._connect(node)
        try:
            # wait=true: returns once the node accepts writes (or false after 60 s)
            promoted = await conn.fetchval("SELECT pg_promote(true, 60)", timeout=70)
            if not promoted:
                raise RuntimeError("pg_promote() returned false")
        finally:
            await conn.close(timeout=self.timeout_s)

    async def ensure_slot(self, primary: NodeAddress, slot: str) -> None:
        """Replication slots are not copied to the standbys, so the new primary needs one per standby."""
        conn = await self._connect(primary)
        try:
            await conn.execute(
                "SELECT pg_create_physical_replication_slot($1) "
                "WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)",
                slot, timeout=self.timeout_s)
        finally:
            await conn.close(timeout=self.timeout_s)

    async def repoint(self, standby: NodeAddress, primary: NodeAddress, slot: str) -> None:
        conn = await self._connect(standby)
        try:
            info = primary_conninfo(primary, self.user, self.password, standby.name)
            # ALTER SYSTEM takes no parameters, hence the literals; it cannot run in a transaction.
            await conn.execute(f"ALTER SYSTEM SET primary_conninfo = {sql_literal(info)}", timeout=self.timeout_s)
            await conn.execute(f"ALTER SYSTEM SET primary_slot_name = {sql_literal(slot)}", timeout=self.timeout_s)
            await conn.execute("SELECT pg_reload_conf()", timeout=self.timeout_s)
        finally:
            await conn.close(timeout=self.timeout_s)
