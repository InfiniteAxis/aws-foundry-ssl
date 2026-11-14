#!/bin/bash
# Foundry VTT with its OWN pinned, checksum-verified Node (independent of the system/app Node).
set -euo pipefail
source /root/asgard/variables.sh

FQDN="${FOUNDRY_SUBDOMAIN}.${DOMAIN_NAME}"
NV="${FOUNDRY_NODE_VERSION}"
NODE_DIR=/opt/foundry-node

id foundry >/dev/null 2>&1 || useradd -m -s /sbin/nologin foundry

# --- pinned Node tarball + SHA256 verification ---
install -d "${NODE_DIR}"
TARBALL="node-v${NV}-linux-arm64.tar.xz"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://nodejs.org/dist/v${NV}/${TARBALL}" -o "${TMP}/${TARBALL}"
if [ -n "${FOUNDRY_NODE_SHA256:-}" ]; then
  EXPECT="${FOUNDRY_NODE_SHA256}"
else
  curl -fsSL "https://nodejs.org/dist/v${NV}/SHASUMS256.txt" -o "${TMP}/SHASUMS256.txt"
  EXPECT="$(grep " ${TARBALL}\$" "${TMP}/SHASUMS256.txt" | awk '{print $1}')"
fi
[ -n "$EXPECT" ] || { echo "no checksum found for ${TARBALL}"; exit 1; }
echo "${EXPECT}  ${TMP}/${TARBALL}" | sha256sum -c -
tar -xJf "${TMP}/${TARBALL}" -C "${NODE_DIR}"
ln -sfn "${NODE_DIR}/node-v${NV}-linux-arm64" "${NODE_DIR}/current"
"${NODE_DIR}/current/bin/node" --version

# --- Foundry application installer ---
# Foundry's download links live only ~5 minutes, which is shorter than this build. So the link is OPTIONAL
# at build time: if it is missing or has expired, install later with a fresh link:
#   sudo asgard-install-foundry '<fresh Linux/Node download URL>'
cat > /usr/local/sbin/asgard-install-foundry <<'EOF'
#!/bin/bash
set -euo pipefail
URL="${1:?usage: asgard-install-foundry '<fresh Foundry Linux/Node download URL>'}"
INSTALL=/home/foundry/foundry-install
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
curl -fsSL "$URL" -o "$TMPD/foundry.zip"
systemctl stop foundry 2>/dev/null || true
rm -rf "$INSTALL"; install -d -o foundry -g foundry "$INSTALL"
unzip -q "$TMPD/foundry.zip" -d "$INSTALL"
chown -R foundry:foundry "$INSTALL"
systemctl enable --now foundry
echo "Foundry installed and started."
EOF
chmod 755 /usr/local/sbin/asgard-install-foundry

# --- data dir and config (no secrets in the config; S3 uses the instance role) ---
install -d -o foundry -g foundry -m 750 /foundrydata /foundrydata/Config /foundrydata/Data /foundrydata/Logs
chmod 700 /foundrydata/Config

cat > /foundrydata/Config/options.json <<EOF
{
  "port": 30000,
  "upnp": false,
  "fullscreen": false,
  "hostname": "${FQDN}",
  "routePrefix": null,
  "sslCert": null,
  "sslKey": null,
  "awsConfig": "/foundrydata/Config/aws-s3.json",
  "dataPath": "/foundrydata",
  "proxyPort": 443,
  "proxySSL": true,
  "minifyStaticFiles": true,
  "updateChannel": "release",
  "language": "en.core",
  "telemetry": false
}
EOF
# No keys on purpose: Foundry then uses the AWS SDK default credential chain (the instance role).
# UNTESTED: if Foundry refuses to start the S3 integration, see RUNBOOK "S3 auth fallback".
cat > /foundrydata/Config/aws-s3.json <<EOF
{ "region": "${AWS_REGION}", "buckets": ["${S3_BUCKET}"] }
EOF
chown -R foundry:foundry /foundrydata
find /foundrydata -type d -exec chmod 750 {} +
find /foundrydata -type f -exec chmod 640 {} +
find /foundrydata/Config -type f -exec chmod 600 {} +
chmod 700 /foundrydata/Config

cat > /etc/systemd/system/foundry.service <<EOF
[Unit]
Description=Foundry VTT
After=network-online.target
Wants=network-online.target

[Service]
User=foundry
Group=foundry
UMask=0027
ExecStart=${NODE_DIR}/current/bin/node /home/foundry/foundry-install/main.js --dataPath=/foundrydata
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectControlGroups=true
LimitNOFILE=65536
SyslogIdentifier=foundry

[Install]
WantedBy=multi-user.target
EOF

# --- health check: restart Foundry if the API stops answering ---
cat > /usr/local/sbin/foundry-healthcheck <<'EOF'
#!/bin/bash
[ -f /home/foundry/foundry-install/main.js ] || exit 0   # not installed yet
for i in 1 2; do
  curl -fsS --max-time 10 http://127.0.0.1:30000/api/status >/dev/null && exit 0
  sleep 15
done
logger -t foundry-healthcheck "Foundry unresponsive, restarting"
systemctl restart foundry
EOF
chmod 755 /usr/local/sbin/foundry-healthcheck
cat > /etc/systemd/system/foundry-healthcheck.service <<'EOF'
[Unit]
Description=Foundry health check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/foundry-healthcheck
EOF
cat > /etc/systemd/system/foundry-healthcheck.timer <<'EOF'
[Unit]
Description=Foundry health check every 10 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable foundry.service
systemctl enable --now foundry-healthcheck.timer
if [ -n "${FOUNDRY_DOWNLOAD_LINK:-}" ]; then
  /usr/local/sbin/asgard-install-foundry "${FOUNDRY_DOWNLOAD_LINK}" \
    || echo "WARNING: Foundry download failed (link expired?). Install later: sudo asgard-install-foundry '<fresh link>'"
else
  echo "No Foundry link given. When ready run: sudo asgard-install-foundry '<fresh link>'"
fi
