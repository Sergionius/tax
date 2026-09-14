# Security Policy

For what TAX encrypts, what the backend and Apple can see, and what is stored, see [`docs/PRIVACY.md`](docs/PRIVACY.md).

## Supported versions

Only the current `0.4.x` line receives security fixes. Older releases are not supported.

## Reporting a vulnerability

When available, report vulnerabilities privately through GitHub Security Advisories ("Report a vulnerability" on the repository's Security tab). If that option is absent, ask the maintainer to enable private reporting without disclosing any vulnerability details. Private reporting must be enabled and verified before public distribution.

Do **not** open a public issue for vulnerability reports, and do not post suspected vulnerabilities, exploit details, credentials, pairing codes, API keys, or personal server addresses in public issues, discussions, or pull requests.

## What to include

- TAX version (`pipx list` for a pipx installation, or the version in `pyproject.toml`) and affected component (Python CLI, FastAPI backend, Mac host, Pi/OMP extension, or iOS app).
- A minimal description of the issue and, if possible, reproduction steps.
- The impact you believe the issue has.

Please do not include real credentials, pairing codes, API keys, device tokens, or private server URLs in a report.

## Response

Reports are triaged privately. You will receive an acknowledgement, and a fix or mitigation will be coordinated with you before any public disclosure.
