#!/bin/bash
# Asgard setup orchestrator (DRAFT, UNTESTED). Runs as root from cloud-init user data.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=/var/log/asgard-setup.log
install -m 600 /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1

# shellcheck disable=SC1091
source /root/asgard/variables.sh   # sourced BEFORE any `set -x` so secrets never reach the log

for step in 10-base 20-foundry 30-nginx-tls 40-apps 50-runner 60-dns; do
  echo "=== [$(date -u +%FT%TZ)] ${step} ==="
  bash "${HERE}/${step}.sh"
done

# The Foundry download link is a bearer URL: drop it once the install worked.
sed -i '/FOUNDRY_DOWNLOAD_LINK/d' /root/asgard/variables.sh
echo "=== [$(date -u +%FT%TZ)] setup complete ==="
