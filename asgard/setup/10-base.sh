#!/bin/bash
# Base OS: updates, packages, users, sshd hardening, swap, journald, CloudWatch agent.
set -euo pipefail
source /root/asgard/variables.sh
HERE="$(cd "$(dirname "$0")" && pwd)"

dnf upgrade -y
dnf install -y git jq tar xz unzip rsync logrotate python3.11 python3.11-pip \
  amazon-cloudwatch-agent dnf-automatic kpatch-dnf

# --- kernel livepatch + unattended SECURITY updates (no automatic reboot) ---
dnf kernel-livepatch -y auto || true
systemctl enable --now kpatch.service || true
sed -i 's/^upgrade_type.*/upgrade_type = security/; s/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer

# --- hostname ---
hostnamectl set-hostname "${HOST_NAME}"

# --- users ---
id axis >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel axis
echo 'axis ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/10-axis
chmod 440 /etc/sudoers.d/10-axis
visudo -cf /etc/sudoers.d/10-axis
install -d -m 700 -o axis -g axis /home/axis/.ssh
if [ -n "${ADMIN_SSH_PUBKEY:-}" ]; then
  echo "${ADMIN_SSH_PUBKEY}" > /home/axis/.ssh/authorized_keys
  chown axis:axis /home/axis/.ssh/authorized_keys; chmod 600 /home/axis/.ssh/authorized_keys
fi

# Read-only diagnostics account for Claude Code (adm + systemd-journal, no sudo).
id claude-ops >/dev/null 2>&1 || useradd -m -s /bin/bash -G adm,systemd-journal claude-ops
install -d -m 700 -o claude-ops -g claude-ops /home/claude-ops/.ssh
if PUB=$(aws ssm get-parameter --region "${AWS_REGION}" --name /asgard/claude-ops-pubkey --query Parameter.Value --output text 2>/dev/null); then
  echo "$PUB" > /home/claude-ops/.ssh/authorized_keys
  chown claude-ops:claude-ops /home/claude-ops/.ssh/authorized_keys; chmod 600 /home/claude-ops/.ssh/authorized_keys
fi

# --- sshd hardening (SSM Session Manager remains the fallback if this ever locks you out) ---
cat > /etc/ssh/sshd_config.d/10-asgard.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers axis claude-ops
EOF
sshd -t && systemctl reload sshd

# --- swap (no swap on the old box; 2 GB file) ---
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- journald cap ---
install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=300M\n' > /etc/systemd/journald.conf.d/10-size.conf
systemctl restart systemd-journald

# --- CloudWatch agent ---
install -m 644 "${HERE}/config/cloudwatch-agent.json" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
