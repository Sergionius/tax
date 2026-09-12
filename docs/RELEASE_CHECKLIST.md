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
