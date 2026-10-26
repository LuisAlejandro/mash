#!/usr/bin/env bash
# Create the Mash APT repository on the host that also serves Dockershelf's.
#
#   sudo ./bootstrap-letsmash-repo.sh
#
# Idempotent. Every path it writes is under REPO_ROOT (/var/www/letsmash), the
# letsmash-apt nginx site, or the letsmash-repo account. It never touches
# /var/www/debian, the dockershelf-apt site, the Dockershelf signing key or
# dockershelf-import-incoming: that repository is live and belongs to other
# publishers.
#
# Environment:
#   APT_HOSTNAME      apt.letsma.sh (default)
#   REPO_ROOT         /var/www/letsmash (default)
#   REPO_USER         letsmash-repo (default)
#   SIGNWITH_KEY_ID   existing key id; generated when unset

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APT_HOSTNAME="${APT_HOSTNAME:-apt.letsma.sh}"
REPO_ROOT="${REPO_ROOT:-/var/www/letsmash}"
REPO_USER="${REPO_USER:-letsmash-repo}"
INCOMING="${REPO_ROOT}/incoming"
IMPORT_DEST="/usr/local/bin/letsmash-import-incoming"
NGINX_SITE="/etc/nginx/sites-available/letsmash-apt"
NGINX_LINK="/etc/nginx/sites-enabled/letsmash-apt"
SSH_ALLOWLIST="/etc/ssh/sshd_config.d/letsmash-apt.conf"
PUBKEY_EXPORT="${REPO_ROOT}/letsmash-apt-signing.pub"
GPG_HOME="${REPO_ROOT}/.gnupg"

# The one path this script must never write. Refuse rather than trust that no
# variable was overridden into it.
case "$REPO_ROOT" in
/var/www/debian | /var/www/debian/*)
  echo "REPO_ROOT points at the Dockershelf repository; refusing." >&2
  exit 1
  ;;
esac

if [[ "${SKIP_APT_INSTALL:-0}" != 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends reprepro nginx gnupg rsync >/dev/null
fi

# --- user ----------------------------------------------------------------
if ! id "$REPO_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$REPO_USER"
fi

# --- SSH allowlist -------------------------------------------------------
# The host uses AllowUsers in a separate Dockershelf-owned include. Add Mash in
# our own include instead of editing theirs; sshd accumulates AllowUsers entries
# from the included files. Refuse if this host does not load sshd_config.d.
if ! grep -Eq '^[[:space:]]*Include[[:space:]].*/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  echo "sshd_config does not include /etc/ssh/sshd_config.d/*.conf; refusing to alter its access policy" >&2
  exit 1
fi
ssh_tmp="$(mktemp)"
cat >"$ssh_tmp" <<'SSH'
# Mash APT publisher. Separate from the Dockershelf deploy account/config.
AllowUsers letsmash-repo
SSH
if [[ ! -f "$SSH_ALLOWLIST" ]] || ! cmp -s "$ssh_tmp" "$SSH_ALLOWLIST"; then
  install -m 644 "$ssh_tmp" "$SSH_ALLOWLIST"
fi
rm -f "$ssh_tmp"
sshd -t
systemctl reload ssh

# --- repository tree -----------------------------------------------------
mkdir -p "${REPO_ROOT}/conf" "$INCOMING"
chown -R "${REPO_USER}:${REPO_USER}" "$REPO_ROOT"
chmod 750 "${REPO_ROOT}/conf" "$INCOMING"
chmod 750 "${REPO_ROOT}/db" 2>/dev/null || true
chmod 700 "$GPG_HOME" 2>/dev/null || true

install -m 755 "${SCRIPT_DIR}/import-incoming.sh" "$IMPORT_DEST"

# --- signing key ---------------------------------------------------------
# Generated inside the repository's own GNUPGHOME so the private half never
# leaves the host and is never shared with the Dockershelf key.
if [[ -z "${SIGNWITH_KEY_ID:-}" ]]; then
  mkdir -p "$GPG_HOME"
  chmod 700 "$GPG_HOME"
  chown -R "${REPO_USER}:${REPO_USER}" "$GPG_HOME"

  if ! sudo -u "$REPO_USER" env GNUPGHOME="$GPG_HOME" \
    gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -q '^sec'; then
    batch_file="${GPG_HOME}/keygen.batch"
    cat >"$batch_file" <<GPG
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Mash APT
Name-Email: apt@${APT_HOSTNAME}
Expire-Date: 5y
%no-protection
%commit
GPG
    chown "${REPO_USER}:${REPO_USER}" "$batch_file"
    sudo -u "$REPO_USER" env GNUPGHOME="$GPG_HOME" gpg --batch \
      --pinentry-mode loopback --generate-key "$batch_file"
    rm -f "$batch_file"
  fi
  SIGNWITH_KEY_ID="$(sudo -u "$REPO_USER" env GNUPGHOME="$GPG_HOME" \
    gpg --list-secret-keys --keyid-format long 2>/dev/null |
    awk '/^sec/ {print $2}' | cut -d/ -f2 | head -1)"
fi

if [[ -z "$SIGNWITH_KEY_ID" ]]; then
  echo "could not determine SIGNWITH_KEY_ID" >&2
  exit 1
fi

sed -e "s/SIGNWITH_KEY_ID/${SIGNWITH_KEY_ID}/g" \
  -e "s/^Description: .*/Description: Mash packages for Ubuntu 24.04 (noble)/" \
  "${SCRIPT_DIR}/reprepro-distributions" >"${REPO_ROOT}/conf/distributions"
chown "${REPO_USER}:${REPO_USER}" "${REPO_ROOT}/conf/distributions"

# --- nginx ---------------------------------------------------------------
# A site of its own. The Dockershelf site is certbot-managed and is never read
# or written here; the only shared action is `nginx -t` and a reload.
tls_present=0
if [[ -f "/etc/letsencrypt/live/${APT_HOSTNAME}/fullchain.pem" ]]; then
  tls_present=1
fi

tmp_site="$(mktemp)"
sed -e "s#@HOSTNAME@#${APT_HOSTNAME}#g" \
  -e "s#@REPO_ROOT@#${REPO_ROOT}#g" \
  "${SCRIPT_DIR}/nginx-letsmash.conf" >"$tmp_site"

if [[ "$tls_present" = 1 ]]; then
  cat >>"$tmp_site" <<NGINX

# Added by bootstrap-letsmash-repo.sh once certbot issued the certificate.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${APT_HOSTNAME};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${APT_HOSTNAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${APT_HOSTNAME}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location /dists/ {
        alias ${REPO_ROOT}/dists/;
        autoindex off;
        limit_except GET HEAD { deny all; }
    }
    location /pool/ {
        alias ${REPO_ROOT}/pool/;
        autoindex off;
        limit_except GET HEAD { deny all; }
    }
    location = /letsmash-apt-signing.pub {
        alias ${REPO_ROOT}/letsmash-apt-signing.pub;
        limit_except GET HEAD { deny all; }
    }
    location / {
        return 404;
    }
}
NGINX
fi

if [[ -f "$NGINX_SITE" ]] && cmp -s "$tmp_site" "$NGINX_SITE"; then
  rm -f "$tmp_site"
else
  mv "$tmp_site" "$NGINX_SITE"
  chmod 644 "$NGINX_SITE"
fi
ln -sfn "$NGINX_SITE" "$NGINX_LINK"
nginx -t
systemctl reload nginx

# --- public key ----------------------------------------------------------
sudo -u "$REPO_USER" env GNUPGHOME="$GPG_HOME" \
  gpg --armor --export "$SIGNWITH_KEY_ID" >"$PUBKEY_EXPORT"
chown "${REPO_USER}:${REPO_USER}" "$PUBKEY_EXPORT"
chmod 644 "$PUBKEY_EXPORT"

cat <<EOF

Mash APT repository bootstrap complete.

  Repository root:   ${REPO_ROOT}
  Incoming:          ${INCOMING}
  Import binary:     ${IMPORT_DEST}
  Deploy user:       ${REPO_USER}
  reprepro SignWith: ${SIGNWITH_KEY_ID}
  Public APT URL:    https://${APT_HOSTNAME}/
  Signing pubkey:    ${PUBKEY_EXPORT}

Next steps:
  1. Certificate, if not yet issued:
       sudo certbot certonly --nginx -d ${APT_HOSTNAME}
     then re-run this script to add the TLS server block.
  2. CI secret: put ${REPO_USER}'s publish public key in
     ~${REPO_USER}/.ssh/authorized_keys.
  3. Publish: make publish-apt VERSION=<version>
EOF
