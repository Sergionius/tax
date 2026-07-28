"""APNs transport isolated from FastAPI and storage."""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass

import httpx
import jwt

try:
    from server.logging_config import log_event
except ModuleNotFoundError:  # Standalone deployment.
    from logging_config import log_event


@dataclass(frozen=True)
class APNSConfig:
    key_id: str
    team_id: str
    bundle_id: str
    key_path: str
    use_sandbox: bool = False


async def send(
    config: APNSConfig,
    logger: logging.Logger,
    device_token: str,
    title: str,
    body: str,
    task_id: str,
    app_name: str = "",
    source: str = "",
    agent: str = "",
) -> None:
    log_event(logger, "apns_send_started", task_id=task_id, token_configured=bool(device_token))
    if not device_token or not config.key_path or not os.path.exists(config.key_path):
        log_event(logger, "apns_skipped", level=logging.WARNING, task_id=task_id, reason="not_configured")
        return

    try:
        with open(config.key_path, encoding="utf-8") as key_file:
            key = key_file.read()
        issued_at = int(time.time())
        auth_token = jwt.encode(
            {"iss": config.team_id, "iat": issued_at, "exp": issued_at + 3600},
            key,
            algorithm="ES256",
            headers={"kid": config.key_id},
        )
    except (OSError, ValueError, jwt.PyJWTError) as error:
        log_event(logger, "apns_configuration_error", level=logging.ERROR, task_id=task_id, error=str(error))
        return
    host = "api.development.push.apple.com" if config.use_sandbox else "api.push.apple.com"
    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
            "category": "TASK",
        },
        "task_id": task_id,
        "app": app_name,
        "source": source,
        "agent": agent,
    }

    try:
        async with httpx.AsyncClient(http2=True) as client:
            response = await client.post(
                f"https://{host}/3/device/{device_token}",
                json=payload,
                headers={
                    "apns-topic": config.bundle_id,
                    "authorization": f"bearer {auth_token}",
                    "apns-priority": "10",
                    "apns-push-type": "alert",
                },
            )
    except httpx.HTTPError as error:
        log_event(logger, "apns_network_error", level=logging.ERROR, task_id=task_id, error=str(error))
        return

    apns_id = response.headers.get("apns-id", "")
    if 200 <= response.status_code < 300:
        log_event(logger, "apns_sent", task_id=task_id, status_code=response.status_code, apns_id=apns_id)
        return
    try:
        reason = response.json().get("reason", "unknown")
    except (ValueError, AttributeError):
        reason = "unknown"
    log_event(
        logger,
        "apns_failed",
        level=logging.WARNING,
        task_id=task_id,
        status_code=response.status_code,
        reason=reason,
        apns_id=apns_id,
    )
