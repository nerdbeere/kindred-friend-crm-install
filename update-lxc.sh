#!/usr/bin/env bash
#
# update-lxc.sh — Update the Kindred app inside an existing LXC container.
#
# Run as root ON THE PROXMOX HOST:
#   ./update-lxc.sh <CT_ID>
#
# Thin wrapper around scripts/update.sh running inside the container. The
# in-CT script also repairs auth + backup sudoers prerequisites, so this is
# the supported repair command for partial/older provisions.

set -euo pipefail

CT_ID="${1:-${CT_ID:-}}"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: Run as root on the Proxmox host." >&2; exit 1; }
[ -n "$CT_ID" ] || { echo "Usage: $0 <CT_ID>" >&2; exit 1; }
pct status "$CT_ID" >/dev/null 2>&1 || { echo "ERROR: Container $CT_ID not found." >&2; exit 1; }

pct exec "$CT_ID" -- bash /opt/kindred/scripts/update.sh
