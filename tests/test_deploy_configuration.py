"""Deployment configuration tests.

These tests exercise the shared shell configuration loader, the deployment
entry points and the rendered templates. They use temporary directories and
fake executables only: no SSH, sudo, systemd, Docker or network access is
involved.
"""

from __future__ import annotations

import pathlib
import re
import subprocess

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPLOY_CONFIG = REPO_ROOT / "scripts" / "deploy-config.sh"
DEPLOY_BACKEND = REPO_ROOT / "scripts" / "deploy-backend.sh"
DEPLOY = REPO_ROOT / "deploy.sh"
REINSTALL = REPO_ROOT / "reinstall-backend.sh"

CONTRACT = {
    "TAX_DEPLOY_HOST": "deploy@tax.example.com",
    "TAX_DEPLOY_USER": "deploy",
    "TAX_DEPLOY_GROUP": "deploy",
    "TAX_DEPLOY_PROJECT_DIR": "/home/deploy/tax",
    "TAX_DEPLOY_DOMAIN": "tax.example.com",
    "TAX_DEPLOY_PORT": "8000",
    "TAX_DEPLOY_DB_PATH": "/home/deploy/tax/data/tax.db",
    "TAX_DEPLOY_APNS_KEY_PATH": "/home/deploy/tax/keys/AuthKey.p8",
    "TAX_DEPLOY_ENV_FILE": "/home/deploy/tax/server/.env",
}

FAKE_SSH = r"""#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_SSH_LOG"
exit 0
"""

FAKE_GIT = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
exit 0
"""


def write_config(tmp_path: pathlib.Path, omit: str | None = None, **overrides: str) -> pathlib.Path:
    values = {key: value for key, value in CONTRACT.items() if key != omit}
    values.update(overrides)
    config = tmp_path / "deploy.env"
    config.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
    return config


def child_environment(
    tmp_path: pathlib.Path,
    config: pathlib.Path | str | None,
    fake_bin: pathlib.Path | None = None,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(home),
    }
    if fake_bin is not None:
        env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    if config is not None:
        env["TAX_DEPLOY_CONFIG"] = str(config)
    if extra:
        env.update(extra)
    return env


def run_repo_script(
    script: pathlib.Path,
    tmp_path: pathlib.Path,
    config: pathlib.Path | str | None,
    fake_bin: pathlib.Path | None = None,
    extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        env=child_environment(tmp_path, config, fake_bin, extra),
        timeout=60,
    )


def run_loader(
    tmp_path: pathlib.Path,
    *args: str,
    config: pathlib.Path | str | None = None,
    extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        ["bash", str(DEPLOY_CONFIG), *args],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        env=child_environment(tmp_path, config, extra=extra),
        timeout=60,
    )
    return proc


def make_fake_bin(tmp_path: pathlib.Path, name: str, body: str) -> pathlib.Path:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(exist_ok=True)
    executable = fake_bin / name
    executable.write_text(body)
    executable.chmod(0o755)
    return fake_bin


# --- Configuration loader -----------------------------------------------------


def test_check_accepts_complete_config(tmp_path):
    proc = run_loader(tmp_path, "check", config=write_config(tmp_path))
    assert proc.returncode == 0, proc.stderr
    assert "valid" in proc.stdout
    assert CONTRACT["TAX_DEPLOY_DOMAIN"] in proc.stdout
    assert CONTRACT["TAX_DEPLOY_PORT"] in proc.stdout


def test_environment_overrides_config_file(tmp_path):
    config = write_config(tmp_path)
    target = tmp_path / "render"
    target.mkdir()
    proc = run_loader(
        tmp_path,
        "render",
        str(target),
        config=config,
        extra={"TAX_DEPLOY_PORT": "8123"},
    )
    assert proc.returncode == 0, proc.stderr
    assert "reverse_proxy 127.0.0.1:8123" in (target / "Caddyfile").read_text()
    assert "--port 8123" in (target / "tax.service").read_text()


def test_missing_tax_deploy_config_file_fails(tmp_path):
    proc = run_loader(tmp_path, "check", config=str(tmp_path / "absent.env"))
    assert proc.returncode != 0
    assert "TAX_DEPLOY_CONFIG" in proc.stderr


def test_missing_configuration_without_file_or_environment_fails(tmp_path):
    proc = run_loader(tmp_path, "check", config=None)
    assert proc.returncode != 0
    assert "TAX_DEPLOY_HOST" in proc.stderr


@pytest.mark.parametrize("missing", sorted(CONTRACT))
def test_missing_required_value_fails(tmp_path, missing):
    config = write_config(tmp_path, omit=missing)
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert missing in proc.stderr


@pytest.mark.parametrize("bad_port", ["", "0", "65536", "99999", "not-a-port", "80 80", "-1", "1.5"])
def test_invalid_port_rejected(tmp_path, bad_port):
    config = write_config(tmp_path, TAX_DEPLOY_PORT=bad_port)
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert "TAX_DEPLOY_PORT" in proc.stderr


@pytest.mark.parametrize(
    "bad_domain",
    ["", "tax.example.com/admin", "tax example.com", "*.example.com", "tax_example.com", "-tax.example.com", "tax..example.com", "http://tax.example.com"],
)
def test_invalid_domain_rejected(tmp_path, bad_domain):
    config = write_config(tmp_path, TAX_DEPLOY_DOMAIN=bad_domain)
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert "TAX_DEPLOY_DOMAIN" in proc.stderr


@pytest.mark.parametrize(
    "bad_name",
    ["", "deploy user", "Deploy", "0deploy", "-deploy", "deploy;id", "deploy$(id)", "a" * 33],
)
@pytest.mark.parametrize("field", ["TAX_DEPLOY_USER", "TAX_DEPLOY_GROUP"])
def test_invalid_service_identity_rejected(tmp_path, field, bad_name):
    config = write_config(tmp_path, **{field: bad_name})
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert field in proc.stderr


@pytest.mark.parametrize(
    "bad_host",
    ["", "tax.example.com", "deploy tax.example.com", "deploy@tax example.com", "deploy@;rm -rf /"],
)
def test_invalid_host_rejected(tmp_path, bad_host):
    config = write_config(tmp_path, TAX_DEPLOY_HOST=bad_host)
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert "TAX_DEPLOY_HOST" in proc.stderr


@pytest.mark.parametrize(
    "field",
    ["TAX_DEPLOY_PROJECT_DIR", "TAX_DEPLOY_DB_PATH", "TAX_DEPLOY_APNS_KEY_PATH", "TAX_DEPLOY_ENV_FILE"],
)
def test_relative_paths_rejected(tmp_path, field):
    config = write_config(tmp_path, **{field: "home/deploy/tax"})
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert field in proc.stderr


def test_path_metacharacters_rejected(tmp_path):
    config = write_config(tmp_path, TAX_DEPLOY_DB_PATH="/home/deploy/data/tax$(reboot).db")
    proc = run_loader(tmp_path, "check", config=config)
    assert proc.returncode != 0
    assert "TAX_DEPLOY_DB_PATH" in proc.stderr


# --- Template rendering -------------------------------------------------------


def test_render_writes_values_without_placeholders(tmp_path):
    config = write_config(tmp_path)
    target = tmp_path / "render"
    target.mkdir()
    proc = run_loader(tmp_path, "render", str(target), config=config)
    assert proc.returncode == 0, proc.stderr

    unit = (target / "tax.service").read_text()
    assert "User=deploy" in unit
    assert "Group=deploy" in unit
    assert "WorkingDirectory=/home/deploy/tax/server" in unit
    assert "Environment=\"TAX_DB_PATH=/home/deploy/tax/data/tax.db\"" in unit
    assert "Environment=\"TAX_APNS_KEY_PATH=/home/deploy/tax/keys/AuthKey.p8\"" in unit
    assert "EnvironmentFile=-/home/deploy/tax/server/.env" in unit
    assert (
        "ExecStart=/home/deploy/tax/server/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000" in unit
    )
    assert "@TAX_DEPLOY_" not in unit

    caddy = (target / "Caddyfile").read_text()
    assert "tax.example.com {" in caddy
    assert "reverse_proxy 127.0.0.1:8000" in caddy
    assert "@TAX_DEPLOY_" not in caddy


def test_rendered_artifacts_use_one_loopback_port(tmp_path):
    config = write_config(tmp_path, TAX_DEPLOY_PORT="8210")
    target = tmp_path / "render"
    target.mkdir()
    proc = run_loader(tmp_path, "render", str(target), config=config)
    assert proc.returncode == 0, proc.stderr
    caddy_ports = re.findall(r"reverse_proxy 127\.0\.0\.1:(\d+)", (target / "Caddyfile").read_text())
    unit_ports = re.findall(r"--port (\d+)", (target / "tax.service").read_text())
    assert caddy_ports == ["8210"]
    assert unit_ports == ["8210"]


def test_render_requires_existing_target_directory(tmp_path):
    proc = run_loader(tmp_path, "render", str(tmp_path / "absent"), config=write_config(tmp_path))
    assert proc.returncode != 0


def test_render_rejects_unrendered_placeholders(tmp_path):
    config = write_config(tmp_path)
    templates = tmp_path / "templates"
    templates.mkdir()
    (templates / "tax.service").write_text(
        "User=@TAX_DEPLOY_USER@\nExecStart=@TAX_DEPLOY_VENV_DIR@/bin/uvicorn --port @TAX_DEPLOY_PORT@\n"
    )
    (templates / "Caddyfile").write_text(
        "@TAX_DEPLOY_DOMAIN@ {\n    reverse_proxy 127.0.0.1:@TAX_DEPLOY_PORT@\n}\n# @TAX_DEPLOY_MYSTERY@\n"
    )
    target = tmp_path / "out"
    target.mkdir()
    proc = run_loader(
        tmp_path,
        "render",
        str(target),
        config=config,
        extra={"TAX_DEPLOY_TEMPLATE_DIR": str(templates)},
    )
    assert proc.returncode != 0
    assert "TAX_DEPLOY_MYSTERY" in proc.stderr


def test_repository_templates_are_neutral():
    """The tracked templates must contain parameters, not owner values."""
    unit = (REPO_ROOT / "server" / "tax.service").read_text()
    caddy = (REPO_ROOT / "Caddyfile").read_text()
    assert "User=@TAX_DEPLOY_USER@" in unit
    assert "Group=@TAX_DEPLOY_GROUP@" in unit
    assert "--port @TAX_DEPLOY_PORT@" in unit
    assert "@TAX_DEPLOY_DOMAIN@ {" in caddy
    assert "reverse_proxy 127.0.0.1:@TAX_DEPLOY_PORT@" in caddy
    for text in (unit, caddy):
        # The only allowed literal address is the loopback bind address.
        for address in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text):
            assert address == "127.0.0.1"
        # No hardcoded home directories; everything user-specific is parameterized.
        assert not re.search(r"/home/[A-Za-z0-9._-]+/", text)


def test_repository_port_examples_are_consistent():
    """Example port, Compose default, unit and Caddy must agree on 8000."""
    example = (REPO_ROOT / "deploy.env.example").read_text()
    assert re.search(r"^TAX_DEPLOY_PORT=8000$", example, re.M)
    compose = (REPO_ROOT / "server" / "docker-compose.yml").read_text()
    assert "127.0.0.1:${TAX_DEPLOY_PORT:-8000}:8000" in compose
    assert ":8000" in compose  # container port stays 8000


def test_dockerfile_includes_all_backend_modules_with_hash_checking():
    dockerfile = (REPO_ROOT / "server" / "Dockerfile").read_text()
    for module in ("main.py", "relay.py", "storage.py", "apns.py", "logging_config.py"):
        assert module in dockerfile
    assert "--require-hashes" in dockerfile


# --- Safe shell quoting -------------------------------------------------------


def test_sh_quote_keeps_safe_values_unquoted_and_escapes_quotes():
    proc = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" && tax_deploy_sh_quote "$2" && printf "\n" && tax_deploy_sh_quote "$3" && printf "\n"',
            "test",
            str(DEPLOY_CONFIG),
            "/home/deploy/tax",
            "a'b",
        ],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    safe, quoted = proc.stdout.splitlines()
    assert safe == "/home/deploy/tax"
    assert quoted == "'a'\\''b'"


def test_sh_quote_single_quotes_values_with_spaces():
    proc = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" && tax_deploy_sh_quote "$2" && printf "\n"',
            "test",
            str(DEPLOY_CONFIG),
            "/home/deploy/my tax",
        ],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
        timeout=60,
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "'/home/deploy/my tax'"


# --- Deployment entry points --------------------------------------------------


def test_deploy_backend_uses_configured_ssh_destination(tmp_path):
    log = tmp_path / "ssh.log"
    fake_bin = make_fake_bin(tmp_path, "ssh", FAKE_SSH)
    config = write_config(tmp_path)
    proc = run_repo_script(
        DEPLOY_BACKEND,
        tmp_path,
        config,
        fake_bin=fake_bin,
        extra={"FAKE_SSH_LOG": str(log)},
    )
    assert proc.returncode == 0, proc.stderr
    args = log.read_text().splitlines()
    assert args[0] == "-t"
    assert args[1] == CONTRACT["TAX_DEPLOY_HOST"]
    remote = args[2]
    assert CONTRACT["TAX_DEPLOY_PROJECT_DIR"] in remote
    assert remote.endswith("./reinstall-backend.sh")


def test_deploy_backend_fails_before_ssh_without_configuration(tmp_path):
    log = tmp_path / "ssh.log"
    fake_bin = make_fake_bin(tmp_path, "ssh", FAKE_SSH)
    proc = run_repo_script(
        DEPLOY_BACKEND,
        tmp_path,
        config=None,
        fake_bin=fake_bin,
        extra={"FAKE_SSH_LOG": str(log)},
    )
    assert proc.returncode != 0
    assert not log.exists()


@pytest.mark.parametrize("break_with", ["missing", "invalid_port"])
def test_deploy_fails_before_git_with_invalid_configuration(tmp_path, break_with):
    log = tmp_path / "git.log"
    fake_bin = make_fake_bin(tmp_path, "git", FAKE_GIT)
    if break_with == "missing":
        config = None
    else:
        config = write_config(tmp_path, TAX_DEPLOY_PORT="70000")
    proc = run_repo_script(
        DEPLOY,
        tmp_path,
        config,
        fake_bin=fake_bin,
        extra={"FAKE_GIT_LOG": str(log)},
    )
    assert proc.returncode != 0
    assert not log.exists()


def test_reinstall_updates_checkout_and_deploys(tmp_path):
    git_log = tmp_path / "git.log"
    fake_bin = make_fake_bin(tmp_path, "git", FAKE_GIT)
    # Fake privilege boundary; never invoke the real sudo in tests.
    sudo = fake_bin / "sudo"
    sudo.write_text('#!/usr/bin/env bash\nexec "$@"\n')
    sudo.chmod(0o755)

    project = tmp_path / "project"
    project.mkdir()
    deploy_marker = tmp_path / "deploy.log"
    fake_deploy = project / "deploy.sh"
    fake_deploy.write_text("#!/usr/bin/env bash\nprintf 'deploy\\n' >> \"$DEPLOY_MARKER\"\n")
    fake_deploy.chmod(0o755)

    config = write_config(tmp_path, TAX_DEPLOY_PROJECT_DIR=str(project))
    proc = run_repo_script(
        REINSTALL,
        tmp_path,
        config,
        fake_bin=fake_bin,
        extra={"FAKE_GIT_LOG": str(git_log), "DEPLOY_MARKER": str(deploy_marker)},
    )
    assert proc.returncode == 0, proc.stderr
    git_calls = git_log.read_text()
    assert "status --porcelain" in git_calls
    assert "pull --ff-only origin main" in git_calls
    assert deploy_marker.read_text() == "deploy\n"
