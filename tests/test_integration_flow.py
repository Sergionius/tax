from pathlib import Path
from urllib.parse import urlsplit

from fastapi.testclient import TestClient

from server import main
from tax.agent import TaxAgent

AUTH = {"Authorization": "Bearer test-key"}


def test_backend_reply_is_delivered_once_and_acknowledged(monkeypatch, tmp_path: Path):
    monkeypatch.setattr(main, "DB_PATH", str(tmp_path / "server.db"))
    monkeypatch.setattr(main, "API_KEY", "test-key")

    async def fake_apns(*_args):
        return None

    monkeypatch.setattr(main, "send_apns", fake_apns)
    delivered = []

    with TestClient(main.app) as client:
        created = client.post(
            "/push",
            headers=AUTH,
            json={
                "title": "done",
                "body": "reply requested",
                "source": "pi-extension",
                "agent": "pi",
                "app": "tax",
                "orca_terminal_handle": "session-123",
            },
        ).json()
        task_id = created["task_id"]
        assert client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "continue"}).status_code == 200

        def request(method, url, **kwargs):
            path = urlsplit(url).path
            return client.request(
                method,
                path,
                headers=kwargs.get("headers"),
                params=kwargs.get("params"),
                json=kwargs.get("json"),
            )

        monkeypatch.setattr("tax.agent.requests.get", lambda url, **kwargs: request("GET", url, **kwargs))
        monkeypatch.setattr("tax.agent.requests.post", lambda url, **kwargs: request("POST", url, **kwargs))

        agent = TaxAgent("https://tax.example", "test-key", tmp_path / "agent")
        monkeypatch.setattr(
            agent,
            "inject_reply",
            lambda reply, row: delivered.append((reply, row["orca_terminal_handle"]))
            or row["orca_terminal_handle"],
        )
        monkeypatch.setattr(agent, "watch", agent._watch_task)

        assert agent.poll_backend_replies() == 1
        assert agent.poll_backend_replies() == 0
        assert delivered == [("continue", "session-123")]
        assert agent.store.get(task_id)["status"] == "delivered"
        assert client.get("/replies", headers=AUTH).json()["tasks"] == []
        agent.stop()
