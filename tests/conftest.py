"""Keep tests independent of the operator's TAX configuration."""

import os

import pytest


@pytest.fixture(autouse=True)
def isolated_tax_configuration(monkeypatch, tmp_path):
    from tax import cli

    for name in tuple(os.environ):
        if name.startswith("TAX_"):
            monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(cli, "CONFIG_PATH", tmp_path / "tax-config.json")
