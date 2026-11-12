#!/bin/bash
# nginx (nginx.org mainline) + certbot in a venv with the Route 53 DNS-01 plugin.
# DNS-01 means certificates can be issued BEFORE DNS cutover, so cutover has no TLS gap.
set -euo pipefail
source /root/asgard/variables.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
FQDN="${FOUNDRY_SUBDOMAIN}.${DOMAIN_NAME}"

# --- nginx.org mainline repo; priority 9 beats the amazonlinux repo (priority 99) ---
cat > /etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/amzn/2023/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
priority=9
EOF
dnf install -y nginx
rpm -q --qf '%{VENDOR} %{VERSION}\n' nginx   # expect nginx.org, not Amazon

install -d -m 755 /var/log/nginx/foundry /var/www/"${DOMAIN_NAME}"
chown nginx:nginx /var/log/nginx/foundry /var/www/"${DOMAIN_NAME}"

# --- certbot venv ---
python3.11 -m venv /opt/certbot
/opt/certbot/bin/pip install --quiet --upgrade pip
/opt/certbot/bin/pip install --quiet certbot certbot-dns-route53
ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot

# --- cert issuing helper (also used at cutover to switch staging -> production) ---
cat > /usr/local/sbin/asgard-issue-certs <<EOF
#!/bin/bash
# usage: asgard-issue-certs --staging | --production
set -euo pipefail
MODE="\${1:---staging}"
EXTRA=()
if [ "\$MODE" = "--staging" ]; then EXTRA+=(--staging); else EXTRA+=(--force-renewal); fi
issue() {  # name, domains...
  local name="\$1"; shift
  local d=(); for x in "\$@"; do d+=(-d "\$x"); done
  /opt/certbot/bin/certbot certonly --dns-route53 --non-interactive --agree-tos -m '${LE_EMAIL}' \\
    --cert-name "\$name" "\${d[@]}" "\${EXTRA[@]}" \\
    --deploy-hook 'systemctl reload nginx || true'
}
issue '${FQDN}' '${FQDN}'
issue '${DOMAIN_NAME}' '${DOMAIN_NAME}' 'www.${DOMAIN_NAME}'
issue 'bot.${DOMAIN_NAME}' 'bot.${DOMAIN_NAME}'
EOF
chmod 755 /usr/local/sbin/asgard-issue-certs
if [ "${LE_STAGING}" = "true" ]; then
  /usr/local/sbin/asgard-issue-certs --staging
else
  /usr/local/sbin/asgard-issue-certs --production
fi

# --- nginx config ---
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.dist || true
install -m 644 "${HERE}/config/nginx/nginx.conf" /etc/nginx/nginx.conf
install -m 644 "${HERE}/config/nginx/ssl-common.inc" /etc/nginx/ssl-common.inc
rm -f /etc/nginx/conf.d/default.conf
install -m 644 "${HERE}/config/nginx/00-default.conf" /etc/nginx/conf.d/00-default.conf
for t in foundry website kotw; do
  sed -e "s/@FOUNDRY_FQDN@/${FQDN}/g" -e "s/@DOMAIN@/${DOMAIN_NAME}/g" \
    "${HERE}/config/nginx/${t}.conf.tmpl" > "/etc/nginx/conf.d/${t}.conf"
done
nginx -t

# --- logrotate for the Foundry vhost logs (the stock rule only globs /var/log/nginx/*.log) ---
cat > /etc/logrotate.d/nginx-foundry <<'EOF'
/var/log/nginx/foundry/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 nginx adm
    sharedscripts
    postrotate
        [ -f /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)"
    endscript
}
EOF

# --- renewal + certbot upgrade timers ---
cat > /etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Certbot renew
[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Certbot renew twice daily
[Timer]
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=1800
Persistent=true
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/certbot-upgrade.service <<'EOF'
[Unit]
Description=Upgrade certbot venv
[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/pip install --quiet --upgrade certbot certbot-dns-route53
EOF
cat > /etc/systemd/system/certbot-upgrade.timer <<'EOF'
[Unit]
Description=Upgrade certbot weekly
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now nginx certbot-renew.timer certbot-upgrade.timer
