"""JSON log lines like every other service: stdout, and LOG_DIR/<router>.log when it is writable."""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

LEVELS = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}


class Logger:
    def __init__(self, service: str = "pg-router", instance_id: str = "pg-router", level: str = "INFO",
                 log_dir: str | None = None, stream=None) -> None:
        self.service = service
        self.instance_id = instance_id
        self.min_level = LEVELS.get(level.upper(), 20)
        self.stream = stream or sys.stdout
        self.file = None
        if log_dir:
            try:
                os.makedirs(log_dir, exist_ok=True)
                self.file = open(os.path.join(log_dir, f"{instance_id}.log"), "a", encoding="utf-8")
            except OSError as exc:  # logging to a file is optional: never stop the router for it
                self._write("WARN", "log file not writable, logging to stdout only", {"logDir": log_dir, "err": str(exc)})

    def _write(self, level: str, msg: str, fields: dict) -> None:
        if LEVELS[level] < self.min_level:
            return
        line = {"time": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                "level": level, "service": self.service, "instanceId": self.instance_id, "msg": msg}
        line.update({k: v for k, v in fields.items() if v is not None})
        text = json.dumps(line, default=str)
        print(text, file=self.stream, flush=True)
        if self.file:
            try:
                self.file.write(text + "\n")
                self.file.flush()
            except OSError:
                pass

    def debug(self, msg: str, **fields) -> None:
        self._write("DEBUG", msg, fields)

    def info(self, msg: str, **fields) -> None:
        self._write("INFO", msg, fields)

    def warn(self, msg: str, **fields) -> None:
        self._write("WARN", msg, fields)

    def error(self, msg: str, **fields) -> None:
        self._write("ERROR", msg, fields)
