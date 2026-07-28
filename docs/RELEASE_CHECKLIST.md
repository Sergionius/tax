# Test release checklist

- [ ] Working tree and intended commit SHA reviewed
- [ ] `scripts/preflight.sh` passed
- [ ] CI passed on all supported Python versions
- [ ] Version/build number updated when required
- [ ] Changes since the previous tag reviewed and release notes edited
- [ ] Target explicitly confirmed as test, not production
- [ ] No `.env`, `.p8`, API key, device token or user content in artifacts/logs
- [ ] Backend health verified after deployment, if backend changed
- [ ] One create-task → reply → delivered smoke flow completed
- [ ] Release report records SHA, version, destination and result

See `ios/QUALITY_AUTOMATION_PLAN.md` for the iOS/APNs test-device checklist.
