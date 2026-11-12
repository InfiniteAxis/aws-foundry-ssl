#!/bin/bash
# App host layer: system Node (NodeSource, major pinned), PM2 under axis, deploy key, bootstrap helper.
set -euo pipefail
source /root/asgard/variables.sh
NODE_MAJOR="${NODE_APPS_MAJOR:-24}"

# --- NodeSource repo, written by hand with signature checking on (no curl|bash) ---
cat > /etc/yum.repos.d/nodesource-nodejs.repo <<EOF
[nodesource-nodejs]
name=Node.js ${NODE_MAJOR}.x
baseurl=https://rpm.nodesource.com/pub_${NODE_MAJOR}.x/nodistro/nodejs/\$basearch
gpgcheck=1
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
enabled=1
module_hotfixes=1
EOF
dnf install -y nodejs
node --version
npm install -g pm2

# --- PM2 as a systemd service for axis (generic: no Node path baked in) ---
cat > /etc/systemd/system/pm2-axis.service <<'EOF'
[Unit]
Description=PM2 process manager for axis
After=network.target

[Service]
Type=forking
User=axis
LimitNOFILE=infinity
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=PM2_HOME=/home/axis/.pm2
PIDFile=/home/axis/.pm2/pm2.pid
Restart=on-failure
ExecStart=/usr/bin/pm2 resurrect
ExecReload=/usr/bin/pm2 reload all
ExecStop=/usr/bin/pm2 kill

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pm2-axis.service   # starts at next boot; `pm2 save` after the first deploy (see RUNBOOK)

# --- fresh deploy key for THIS host (never reuse the old box's key) ---
SSHD=/home/axis/.ssh
if [ ! -f "${SSHD}/id_ed25519_gitlab" ]; then
  sudo -u axis ssh-keygen -q -t ed25519 -N '' -C "deploy@${HOST_NAME}" -f "${SSHD}/id_ed25519_gitlab"
fi
cat > "${SSHD}/config" <<'EOF'
Host gitlab.com
  IdentityFile ~/.ssh/id_ed25519_gitlab
  IdentitiesOnly yes
  StrictHostKeyChecking yes
EOF
ssh-keyscan -t ed25519 gitlab.com > "${SSHD}/known_hosts" 2>/dev/null
chown axis:axis "${SSHD}/config" "${SSHD}/known_hosts"; chmod 600 "${SSHD}/config" "${SSHD}/known_hosts"
echo "---- GitLab host key (compare with docs.gitlab.com 'SSH known_hosts entries') ----"
ssh-keygen -lf "${SSHD}/known_hosts"
echo "---- Add this PUBLIC key as a read-only deploy key on kotw, website, famblygameproject ----"
cat "${SSHD}/id_ed25519_gitlab.pub"

# --- bootstrap helper: run by hand AFTER the deploy key is registered ---
cat > /usr/local/sbin/asgard-bootstrap-apps <<EOF
#!/bin/bash
# Clones the three repos and pulls kotw's .env.local from SSM (SecureString /asgard/kotw/env-local).
set -euo pipefail
sudo -u axis bash -c '
  set -e
  mkdir -p ~/sites
  [ -d ~/kotw ] || git clone git@gitlab.com:valhalla-software/kotw.git ~/kotw
  [ -d ~/sites/website ] || git clone git@gitlab.com:valhalla-software/website.git ~/sites/website
  [ -d ~/famblygameproject ] || git clone git@gitlab.com:valhalla-software/famblygameproject.git ~/famblygameproject
'
if aws ssm get-parameter --region '${AWS_REGION}' --name /asgard/kotw/env-local --with-decryption \\
     --query Parameter.Value --output text > /tmp/kotw.env 2>/dev/null; then
  install -m 600 -o axis -g axis /tmp/kotw.env /home/axis/kotw/.env.local
  shred -u /tmp/kotw.env
else
  echo "No /asgard/kotw/env-local parameter: create /home/axis/kotw/.env.local by hand." >&2
fi
echo "Next: run the GitLab pipelines (or npm ci / build / pm2 startOrReload by hand), then: sudo -u axis pm2 save"
EOF
chmod 755 /usr/local/sbin/asgard-bootstrap-apps
