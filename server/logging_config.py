"""Structured logging for the standalone backend deployment."""

from __future__ import annotations

import json
import logging
import os
import re
from typing import Any

_BEARER = re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+")
_SENSITIVE_KEYS = {"api_key", "authorization", "device_token", "reply", "context", "logs", "token"}


def configure_logging(component: str) -> logging.Logger:
    level = os.environ.get("TAX_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(level=getattr(logging, level, logging.INFO), format="%(message)s")
    return logging.getLogger(component)


def log_event(logger: logging.Logger, event: str, *, level: int = logging.INFO, **fields: Any) -> None:
    safe = {"component": logger.name, "event": event}
    for key, value in fields.items():
        if key.lower() in _SENSITIVE_KEYS:
            safe[key] = "***"
        elif isinstance(value, str):
            safe[key] = _BEARER.sub("Bearer ***", value)
        else:
            safe[key] = value
    logger.log(level, json.dumps(safe, ensure_ascii=False, default=str, separators=(",", ":")))
