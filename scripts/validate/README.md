# Validation Scripts

This directory is reserved for verification tools and test harnesses.

Examples:
- CUPS queue inspection
- Bonjour advertisement checks
- AirPrint endpoint validation
- end-to-end smoke tests against the `macmini` host
Validation scripts for local and remote checks.

- `run-local-cli.sh` runs the development CLI against the current machine.
- `run-cli-on-macmini.sh` executes the deployed CLI on the remote `macmini` host.
- `check-macmini-printer.sh` captures a quick raw printer snapshot over SSH.
