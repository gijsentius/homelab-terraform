#!/usr/bin/env bash
# Run tofu with the secrets from secrets.enc.yaml (sops + age) in its environment.
# Decrypted values only exist in the tofu process's environment, never on disk.
#
# Usage: ./scripts/tofu.sh <tofu args>, e.g. ./scripts/tofu.sh apply
set -euo pipefail

cd "$(dirname "$0")/.."

# The github provider and the mono repo clone need this; reuse the gh CLI session
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"

exec sops exec-env secrets.enc.yaml "tofu $(printf '%q ' "$@")"
