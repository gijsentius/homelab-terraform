#!/usr/bin/env bash
# Run tofu for one site, with the secrets from secrets.enc.yaml (sops + age) in
# its environment. Decrypted values only exist in the tofu process's
# environment, never on disk.
#
# Usage: [SITE=<site>] ./scripts/tofu.sh <tofu args>
#   ./scripts/tofu.sh apply               # site-a (default)
#   SITE=site-b ./scripts/tofu.sh apply
#
# Per site:
#   workspace   default for site-a (its state predates multi-site support),
#               <site> for every other site
#   <site>.tfvars             non-secret values (node IPs, Proxmox endpoint, ...)
#   secrets.<site>.enc.yaml   optional; overrides keys from secrets.enc.yaml,
#                             e.g. that site's TF_VAR_proxmox_api_token
set -euo pipefail

cd "$(dirname "$0")/.."

SITE="${SITE:-site-a}"
if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "SITE must be lowercase letters, digits and dashes, got: $SITE" >&2
  exit 1
fi

# tofu auto-loads terraform.tfvars for every run, so one site's values would
# leak into another site's plan.
if [[ -f terraform.tfvars ]]; then
  echo "terraform.tfvars is loaded for every site; rename it to site-a.tfvars." >&2
  exit 1
fi

var_file="$SITE.tfvars"
if [[ "${1:-}" != "init" && ! -f "$var_file" ]]; then
  echo "Missing $var_file (copy terraform.tfvars.example)." >&2
  exit 1
fi

# Only the commands that take variables get -var-file; tofu rejects it on the
# others (output, state, ...).
for cmd in plan apply destroy import refresh console; do
  export "TF_CLI_ARGS_$cmd=-var-file=$var_file"
done

if [[ "${1:-}" != "init" ]]; then
  if [[ "$SITE" == "site-a" ]]; then workspace=default; else workspace="$SITE"; fi
  tofu workspace select -or-create "$workspace" >/dev/null
fi

# The github provider and the mono repo clone need this; reuse the gh CLI session
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"

cmd="tofu $(printf '%q ' "$@")"
site_secrets="secrets.$SITE.enc.yaml"
if [[ -f "$site_secrets" ]]; then
  # Inner exec-env runs second, so its keys win over the shared file's.
  cmd="sops exec-env $site_secrets $(printf '%q' "$cmd")"
fi

exec sops exec-env secrets.enc.yaml "$cmd"
