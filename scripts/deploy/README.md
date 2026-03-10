# Deployment Scripts

This directory is reserved for remote deployment workflows.

Primary target:
- `macmini`

Expected responsibilities:
- copy build artifacts with `scp`
- install or replace test builds remotely
- trigger helper registration or launch
- collect logs and diagnostics over `ssh`
