# Home Lab Docs

Sanitized documentation and safe configuration examples for Chris's home lab/media stack.

## Included
- `docs/home-lab-runbook.md` - living runbook for architecture, storage, operations, and recovery
- `compose/` - sanitized Docker Compose files
- `scripts/check-nas-health.example.sh` - example NAS health-check script with alert target redacted

## Not included
- real secrets
- API keys
- live app databases
- private tracker credentials
- real `.env` files
- LUKS keyfiles or recovery secrets

## Safety rule
Treat this repo as documentation and safe examples only. Keep live secrets in a secret manager, not in Git.
