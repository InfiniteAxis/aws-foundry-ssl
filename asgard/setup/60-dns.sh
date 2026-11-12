#!/bin/bash
# DNS helper. Installed always, but ENABLED only when ManageDns=true (never during the trial run).
# It only touches the Foundry record; apex/www/bot are switched by hand at cutover (see RUNBOOK).
set -euo pipefail
source /root/asgard/variables.sh
FQDN="${FOUNDRY_SUBDOMAIN}.${DOMAIN_NAME}"

cat > /usr/local/sbin/asgard-dns-upsert <<EOF
#!/bin/bash
# usage: asgard-dns-upsert <name> [ip]   (defaults to this stack's Elastic IP)
set -euo pipefail
NAME="\${1:?record name}"; IP="\${2:-${EIP_ADDRESS}}"
aws route53 change-resource-record-sets --hosted-zone-id '${HOSTED_ZONE_ID}' --change-batch "{
  \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"\$NAME\",\"Type\":\"A\",\"TTL\":120,
  \"ResourceRecords\":[{\"Value\":\"\$IP\"}]}}]}"
EOF
chmod 755 /usr/local/sbin/asgard-dns-upsert

cat > /etc/systemd/system/asgard-dns.service <<EOF
[Unit]
Description=Keep ${FQDN} pointed at this box
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/asgard-dns-upsert ${FQDN}
EOF
cat > /etc/systemd/system/asgard-dns.timer <<'EOF'
[Unit]
Description=Re-assert Foundry DNS daily
[Timer]
OnBootSec=1min
OnUnitActiveSec=24h
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
if [ "${MANAGE_DNS}" = "true" ]; then
  systemctl enable --now asgard-dns.timer
else
  echo "ManageDns=false: DNS timer installed but NOT enabled. Enable at cutover: systemctl enable --now asgard-dns.timer"
fi
