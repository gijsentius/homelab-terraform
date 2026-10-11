#!/usr/bin/env bash
# Create FRITZ!Box DHCP reservations (MAC → IP) from a plain text file.
#
# Uses fritz_lease.py from https://github.com/jvejmelka/fritzbox-static-lease
# (CC0). TR-064 can't set static leases, so that script uses the FRITZ!Box's
# undocumented internal API — tested upstream on FRITZ!OS 8.25 only.
#
# The FRITZ!Box can only pin devices it has already seen, so boot the VMs once
# before running this. Afterwards, reboot them so they pick up the new IPs.
#
# Usage:
#   cp scripts/fritzbox-reservations.txt.example scripts/fritzbox-reservations.txt
#   export FRITZ_USER=terraform        # FRITZ!Box user with 'FRITZ!Box Einstellungen'
#   export FRITZ_PASSWORD=...          # or leave unset to be prompted
#   ./scripts/fritzbox-reserve-ips.sh [reservations-file]

set -euo pipefail

# Pinned upstream commit + checksum: third-party code with admin access to your
# router, so never run whatever is on main. To upgrade, review the new
# fritz_lease.py and update both values.
FRITZ_LEASE_COMMIT="5a616d4ea486f351f6bdd8b507f772cfe8406bcd"
FRITZ_LEASE_SHA256="d7f6e7676970cfd2ebbc73ede4d405d95126eec0507cfa98e9361160087b1621"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reservations="${1:-${script_dir}/fritzbox-reservations.txt}"
cache_dir="${script_dir}/../.fritzbox-static-lease"
fritz_lease="${cache_dir}/fritz_lease.py"

[[ -f "$reservations" ]] || { echo "error: $reservations not found" >&2; exit 1; }
[[ -n "${FRITZ_USER:-}" ]] || { echo "error: set FRITZ_USER" >&2; exit 1; }

# Prompt once here instead of fritz_lease.py prompting for every device
if [[ -z "${FRITZ_PASSWORD:-}" ]]; then
  read -rsp "FRITZ!Box password for ${FRITZ_USER}: " FRITZ_PASSWORD
  echo
  export FRITZ_PASSWORD
fi

# Fetch fritz_lease.py once, plus a private venv for its 'requests' dependency
# (Homebrew/system Python refuses global pip installs).
mkdir -p "$cache_dir"
if ! echo "${FRITZ_LEASE_SHA256}  ${fritz_lease}" | sha256sum --check --status 2>/dev/null; then
  curl -fsSL -o "$fritz_lease" \
    "https://raw.githubusercontent.com/jvejmelka/fritzbox-static-lease/${FRITZ_LEASE_COMMIT}/fritz_lease.py"
  echo "${FRITZ_LEASE_SHA256}  ${fritz_lease}" | sha256sum --check --status \
    || { rm -f "$fritz_lease"; echo "error: fritz_lease.py checksum mismatch" >&2; exit 1; }
fi
if [[ ! -x "${cache_dir}/venv/bin/python" ]]; then
  python3 -m venv "${cache_dir}/venv"
  "${cache_dir}/venv/bin/pip" install --quiet 'requests>=2.28'
fi

failed=0
while read -r mac ip _; do
  [[ -z "$mac" || "$mac" == \#* ]] && continue
  echo "==> ${mac} → ${ip}"

  # --ip is a global option, so it goes before the subcommand
  if ! "${cache_dir}/venv/bin/python" "$fritz_lease" --ip "$ip" pin "$mac"; then
    failed=1
    continue
  fi

  # fritz_lease.py only verifies the static flag, so check the IP ourselves.
  # 'find' prints: <flag>  <ip> <mac> <uid> <name>
  read -r flag current_ip _ < <("${cache_dir}/venv/bin/python" "$fritz_lease" find "$mac")
  if [[ "$flag" != "1" || "$current_ip" != "$ip" ]]; then
    echo "    MISMATCH: box has static=${flag} ip=${current_ip} (may still show the" >&2
    echo "    current lease — reboot the VM and re-run this script to re-check)" >&2
    failed=1
  fi
done < "$reservations"

if [[ $failed -ne 0 ]]; then
  echo "Some reservations failed — set them in the FRITZ!Box UI instead." >&2
  exit 2
fi
echo "Done. Reboot the VMs so they request a lease on their reserved IPs."
