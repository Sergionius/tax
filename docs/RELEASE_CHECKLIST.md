# Test release checklist

- [ ] Working tree and intended commit SHA reviewed
- [ ] `scripts/preflight.sh` passed
- [ ] CI passed on all supported Python versions
- [ ] Version/build number updated when required
- [ ] Changes since the previous tag reviewed and release notes edited
- [ ] Target explicitly confirmed as test, not production
- [ ] No `.env`, `.p8`, API key, device token or user content in artifacts/logs
- [ ] Backend health verified after deployment, if backend changed
- [ ] `tax push-doctor` reported `APNs result: sent` on a physical device
- [ ] Release report records SHA, version, destination and result

See `ios/APNS_SMOKE_CHECKLIST.md` for the physical-device APNs checklist.

## Public source publication gate

- [ ] Python 3.11–3.13 CI passes without operator environment/configuration
- [ ] Node tests include both Pi and Oh My Pi adapters
- [ ] Local iOS unit/UI tests and Release simulator build pass
- [ ] Fresh installation instructions verified without private local files
- [ ] Root/service-user deployment flow verified on a disposable Linux host
- [ ] Generated backend requirements match `uv.lock`; no independent transitive bump
- [ ] Private vulnerability reporting enabled and its report link verified
- [ ] Git history and GitHub PR refs/diffs, Actions logs/artifacts and releases audited
- [ ] Sensitive historical material removed or confirmed inaccessible, not merely unreferenced by main
- [ ] Mac/VPS transition after history replacement prepared, including private backups

The private repository deliberately keeps iOS Actions manual to conserve the billing budget. Do not trigger paid runners merely to satisfy this checklist: use local Xcode for validation.

History replacement and visibility changes require a separate operator-approved maintenance window. A root-commit force-push alone does not erase GitHub pull-request refs, cached views, artifacts, or other people's clones. Use GitHub's sensitive-data-removal procedure and Support where required. Never publish while relying only on a clean HEAD scan.

Before replacing history, preserve an offline private Git backup plus the ignored deployment/signing/pairing configuration and a consistent database backup. After replacement, ordinary `git pull --ff-only` cannot update existing Mac/VPS checkouts. Inspect local changes and the new root commit first, then explicitly migrate each checkout to the verified new history while preserving private files and service paths. Do not run an automatic hard reset or delete the old checkout; the editable pipx installation may reference its path. Test the migrated deployment path before resuming routine updates.
