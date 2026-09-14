"""Exercise deployment ordering with fake privileged tools; never deploy."""

import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("reject_env", [False, True])
def test_root_deployment_never_uses_git_and_checks_before_changes(tmp_path, reject_env):
    project = tmp_path / "project"
    project.mkdir()
    tools = tmp_path / "bin"
    tools.mkdir()
    log = tmp_path / "calls.log"
    # All external privilege/system/network boundaries are fake. EUID is
    # substituted only in this disposable copy to exercise the root path.
    script = (ROOT / "deploy.sh").read_text().replace('"$EUID"', '"0"')
    (project / "deploy.sh").write_text(script)
    (project / "scripts").mkdir()
    config = project / "scripts/deploy-config.sh"
    config.write_text('''tax_deploy_config_load() { return 0; }
tax_deploy_render_templates() { printf 'unit' > "$1/tax.service"; }
''')
    fake = '''#!/usr/bin/env bash
set -e
name="${0##*/}"
printf '%s %s\\n' "$name" "$*" >> "$CALLS"
case "$name" in
 runuser) shift 3; exec "$@" ;;
 python3)
   if [[ "${2:-}" == env && "${REJECT_ENV:-}" == 1 ]]; then exit 1; fi
   if [[ "${1:-}" == -m ]]; then mkdir -p "$3/bin"; cp "$0" "$3/bin/python"; fi ;;
 caddy) [[ "${1:-}" == adapt ]] && printf '{}' || true ;;
 systemctl) [[ "${1:-}" == show ]] && echo not-found || true ;;
 git|sudo) exit 99 ;;
esac
'''
    for name in ("runuser", "python3", "python", "caddy", "systemctl", "install", "git", "sudo"):
        path = tools / name
        path.write_text(fake)
        path.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith("TAX_")}
    env.update({
        "PATH": f"{tools}:{os.environ['PATH']}", "CALLS": str(log),
        "REJECT_ENV": "1" if reject_env else "0",
        "TAX_DEPLOY_USER": "deploy", "TAX_DEPLOY_GROUP": "deploy",
        "TAX_DEPLOY_PROJECT_DIR": str(project), "TAX_DEPLOY_SERVER_DIR": str(project),
        "TAX_DEPLOY_DATA_DIR": str(tmp_path / "data"), "TAX_DEPLOY_DB_PATH": str(tmp_path / "data/tax.db"),
        "TAX_DEPLOY_ENV_FILE": str(tmp_path / "custom.env"), "TAX_DEPLOY_APNS_KEY_PATH": str(tmp_path / "key.p8"),
        "TAX_DEPLOY_DOMAIN": "tax.example.com", "TAX_DEPLOY_PORT": "8123",
        "TAX_DEPLOY_VENV_DIR": str(tmp_path / "venv"),
    })
    proc = subprocess.run(["bash", str(project / "deploy.sh")], env=env, capture_output=True, text=True)
    calls = log.read_text().splitlines()
    assert not any(line.startswith(("git ", "sudo ")) for line in calls)
    assert str(tmp_path / "custom.env") in calls[0]
    if reject_env:
        assert proc.returncode != 0
        assert not any(line.startswith(("install ", "systemctl ")) for line in calls)
    else:
        assert proc.returncode == 0, proc.stderr
        assert any("--require-hashes" in line for line in calls)
        assert any(line == "systemctl restart tax.service" for line in calls)
        assert not any(line == "systemctl stop tax.service" for line in calls)
        assert any(str(tmp_path / "data/backups") in line for line in calls)
