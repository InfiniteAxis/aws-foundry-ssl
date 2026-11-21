#!/bin/bash
# GitLab Runner install + least-privilege deploy plumbing. Registration is NOT done here:
# it happens at cutover (see RUNBOOK) so two boxes never compete for the same `production` jobs.
set -euo pipefail
source /root/asgard/variables.sh

# --- repo with the pinned package-signing key (fingerprint verified, not trusted blindly) ---
EXPECTED_FPR="931DA69CFA3AFEBBC97DAA8C6C57C29C6BA75A4E"   # runner package key, expires 2027-02-26 -> re-check then
# The documented package-signing key lives at its own URL (the generic .../gpgkey file holds other keys).
KEYFILE=/etc/pki/rpm-gpg/RPM-GPG-KEY-gitlab-runner
TMPK="$(mktemp)"
curl -fsSL https://packages.gitlab.com/runner/gitlab-runner/gpgkey/runner-gitlab-runner-49F16C5CC3A0F81F.pub.gpg -o "${TMPK}"
GOT="$(gpg --show-keys --with-colons "${TMPK}" | awk -F: '$1=="fpr"{print $10}' | tr '\n' ' ')"
echo "key fingerprints offered: ${GOT}"
echo "${GOT}" | grep -q "${EXPECTED_FPR}" || { echo "GitLab runner key mismatch: aborting"; exit 1; }
install -m 644 "${TMPK}" "${KEYFILE}"
rm -f "${TMPK}"
rpm --import "${KEYFILE}"
# Packages are verified (gpgcheck=1) against the pinned local key. Repo-metadata signing (repo_gpgcheck) is
# off on purpose: its key is not pinned here, and the package signature is what protects what gets installed.
cat > /etc/yum.repos.d/gitlab-runner.repo <<'EOF'
[gitlab-runner]
name=gitlab-runner
baseurl=https://packages.gitlab.com/runner/gitlab-runner/amazon/2023/$basearch
repo_gpgcheck=0
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-gitlab-runner
EOF
dnf install -y gitlab-runner
systemctl disable --now gitlab-runner.service || true   # stays off until registration at cutover

# --- unprivileged runner for lint/test jobs ---
id gitlab-lint >/dev/null 2>&1 || useradd -m -s /bin/bash gitlab-lint
install -d -m 700 -o gitlab-lint -g gitlab-lint /home/gitlab-lint/builds

# --- narrow sudo for the production runner (replaces the old NOPASSWD: ALL) ---
cat > /usr/local/sbin/deploy-website <<'EOF'
#!/bin/bash
# Publishes a built Angular site. Root-owned; the only thing gitlab-runner may sudo.
# usage: deploy-website   (source is fixed: /home/axis/sites/website/dist/website/browser)
set -euo pipefail
SRC=/home/axis/sites/website/dist/website/browser
DEST=@WEBROOT@
[ -f "${SRC}/index.html" ] || { echo "no build at ${SRC}"; exit 1; }
rsync -a --delete "${SRC}/" "${DEST}/"
chown -R nginx:nginx "${DEST}"
find "${DEST}" -type d -exec chmod 755 {} +
find "${DEST}" -type f -exec chmod 644 {} +
EOF
sed -i "s#@WEBROOT@#/var/www/${DOMAIN_NAME}#" /usr/local/sbin/deploy-website
chown root:root /usr/local/sbin/deploy-website; chmod 755 /usr/local/sbin/deploy-website

cat > /etc/sudoers.d/20-gitlab-runner <<'EOF'
# production runner: may publish the website and act as axis (deploys run PM2/npm as axis). Nothing else.
gitlab-runner ALL=(root) NOPASSWD: /usr/local/sbin/deploy-website
gitlab-runner ALL=(axis) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/20-gitlab-runner
visudo -cf /etc/sudoers.d/20-gitlab-runner

# --- registration helper, run at cutover ---
cat > /usr/local/sbin/asgard-register-runners <<'EOF'
#!/bin/bash
# usage: asgard-register-runners <production-token> <lint-token>
# Tokens are glrt-... runner authentication tokens created in GitLab (production: Protected; lint: tag lint).
set -euo pipefail
PROD="${1:?production token}"; LINT="${2:?lint token}"
gitlab-runner register --non-interactive --url https://gitlab.com --token "$PROD" \
  --executor shell --name "$(hostname)-production"
systemctl enable --now gitlab-runner

# The lint runner is a SECOND service under its own unprivileged user and config (no sudo rights at all).
install -d -o gitlab-lint -g gitlab-lint -m 750 /etc/gitlab-runner-lint
gitlab-runner register --non-interactive --url https://gitlab.com --token "$LINT" \
  --executor shell --name "$(hostname)-lint" --config /etc/gitlab-runner-lint/config.toml
chown gitlab-lint:gitlab-lint /etc/gitlab-runner-lint/config.toml
gitlab-runner install --user gitlab-lint --working-directory /home/gitlab-lint/builds \
  --config /etc/gitlab-runner-lint/config.toml --service gitlab-runner-lint
systemctl enable --now gitlab-runner-lint
systemctl is-active gitlab-runner gitlab-runner-lint; sudo -l -U gitlab-lint | tail -3
EOF
chmod 755 /usr/local/sbin/asgard-register-runners
