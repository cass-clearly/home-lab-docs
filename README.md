# Home Lab Docs

Sanitized documentation and safe configuration examples for Chris's home lab/media stack.

## Included
- `docs/home-lab-runbook.md` - living runbook for architecture, storage, operations, recovery, and troubleshooting
- `compose/` - sanitized Docker Compose files
- `scripts/check-nas-health.example.sh` - example NAS health-check script with alert target redacted

## Maintenance rule
Whenever the home lab changes:
- update this repo
- update the runbook
- add troubleshooting/recovery notes for anything that broke or behaved unexpectedly
- push the changes so the repo stays usable as a handoff guide

## Not included
- real secrets
- API keys
- live app databases
- private tracker credentials
- real `.env` files
- LUKS keyfiles or recovery secrets

## Safety rule
Treat this repo as documentation and safe examples only. Keep live secrets in a secret manager, not in Git.
