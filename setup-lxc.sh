#!/usr/bin/env bash
#
# setup-lxc.sh — Provision a Debian LXC on a Proxmox host and deploy Kindred.
#
# Run as root ON THE PROXMOX HOST:
#   ./setup-lxc.sh <git-repo-url>
#
# Public repo (HTTPS):
#   ./setup-lxc.sh https://github.com/you/kindred-friend-crm.git
#
# Private repo (SSH + GitHub Deploy Key, read-only):
#   ./setup-lxc.sh git@github.com:you/kindred-friend-crm.git
#     -> The script generates a keypair inside the container, prints the
#        public key, and waits while you add it under the repo's
#        Settings -> Deploy keys (read-only is enough).
#
#   or bring your own key (non-interactive):
#   DEPLOY_KEY=~/.ssh/kindred_deploy_key ./setup-lxc.sh git@github.com:you/kindred-friend-crm.git
#
# One-liner (the installer is mirrored to a public repo so the app repo
# can stay private):
#   curl -fsSL https://raw.githubusercontent.com/nerdbeere/kindred-friend-crm-install/main/setup-lxc.sh | bash
#
# What it does:
#   1. Creates an unprivileged Debian 12 LXC (DHCP, starts on boot)
#   2. Installs Node.js + build tools inside the container
#   3. Clones the repo, runs `npm ci` + `npm run build`
#   4. Installs a systemd service (enabled on boot) running `npm start`
#   5. Prints the secret ICS feed URL for Home Assistant
#
# Configuration via environment variables (all optional):
#   CT_ID         Container ID           (default: next free ID)
#   HOSTNAME      Container hostname     (default: kindred)
#   CORES         vCPUs                  (default: 1)
#   MEMORY        RAM in MB              (default: 1024)
#   SWAP          Swap in MB             (default: 512)
#   DISK          Root disk in GB        (default: 8)
#   STORAGE       Proxmox storage        (default: local-lvm)
#   BRIDGE        Network bridge         (default: vmbr0)
#   BRANCH        Git branch to deploy   (default: main)
#   APP_PORT      App port               (default: 3000)
#   NODE_MAJOR    Node.js major version  (default: 22)
#   DEPLOY_KEY    Path (on this host) to a private SSH key authorized
#                 as a deploy key for the repo (SSH URLs only)
#   ENABLE_BACKUP Set 1 to install restic + the sudoers rules + auth/env
#                 files right after provisioning. Defaults to 0
#                 (the first-run wizard handles it interactively).
#                 When 1 and you supply BACKUP_S3_* + AWS_* env vars,
#                 the wizard step 2 is pre-skipped.

set -euo pipefail

# Default repo to deploy. Override by passing a URL as $1 or setting GIT_REPO.
DEFAULT_GIT_REPO="git@github.com:nerdbeere/kindred-friend-crm.git"
GIT_REPO="${1:-${GIT_REPO:-$DEFAULT_GIT_REPO}}"
CT_ID="${CT_ID:-}"
HOSTNAME="${HOSTNAME:-kindred}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-1024}"
SWAP="${SWAP:-512}"
DISK="${DISK:-8}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
BRANCH="${BRANCH:-main}"
APP_PORT="${APP_PORT:-3000}"
NODE_MAJOR="${NODE_MAJOR:-22}"
DEPLOY_KEY="${DEPLOY_KEY:-}"
ENABLE_BACKUP="${ENABLE_BACKUP:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run this script as root on the Proxmox host."
command -v pct >/dev/null || die "pct not found — this script must run on a Proxmox host."
[ -n "$GIT_REPO" ] || die "Usage: $0 <git-repo-url>   (or set GIT_REPO)"

USE_SSH=0
case "$GIT_REPO" in
  git@*|ssh://*) USE_SSH=1 ;;
esac

if [ -n "$DEPLOY_KEY" ]; then
  [ "$USE_SSH" -eq 1 ] || die "DEPLOY_KEY is only meaningful with an SSH repo URL (git@...)."
  [ -f "$DEPLOY_KEY" ] || die "DEPLOY_KEY file not found: $DEPLOY_KEY"
fi

if [ -z "$CT_ID" ]; then
  CT_ID="$(pvesh get /cluster/nextid)"
fi
log "Using container ID: $CT_ID"
! pct status "$CT_ID" >/dev/null 2>&1 || die "Container $CT_ID already exists."

# --- Template ----------------------------------------------------------------
log "Locating Debian 12 LXC template..."
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '$2 ~ /^debian-12-standard/ {print $2}' | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "Could not find a debian-12-standard template via pveam."

if ! pveam list local | awk '{print $1}' | grep -q "vztmpl/$TEMPLATE"; then
  log "Downloading template $TEMPLATE..."
  pveam download local "$TEMPLATE" >/dev/null
fi
log "Template: $TEMPLATE"

# --- Create & start container -------------------------------------------------
log "Creating LXC $CT_ID ($HOSTNAME)..."
pct create "$CT_ID" "local:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1

log "Waiting for container network..."
for i in $(seq 1 30); do
  if pct exec "$CT_ID" -- getent hosts deb.nodesource.com >/dev/null 2>&1; then
    break
  fi
  [ "$i" -lt 30 ] || die "Container has no network/DNS after 60s."
  sleep 2
done

# --- Deploy key setup (private repos over SSH) --------------------------------
if [ "$USE_SSH" -eq 1 ]; then
  log "Setting up SSH deploy key inside the container..."
  if [ -n "$DEPLOY_KEY" ]; then
    pct push "$CT_ID" "$DEPLOY_KEY" /root/.kindred_deploy_key
  fi

  pct exec "$CT_ID" -- bash -s <<'KEY_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# git + openssh-client are needed here so the host-side deploy-key verification
# (git ls-remote) can run before the main provisioning step installs anything else.
apt-get install -y -qq openssh-client git

id kindred >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --create-home kindred
install -d -m 700 -o kindred -g kindred /home/kindred/.ssh

if [ -f /root/.kindred_deploy_key ]; then
  install -m 600 -o kindred -g kindred /root/.kindred_deploy_key /home/kindred/.ssh/id_ed25519
  rm -f /root/.kindred_deploy_key
elif [ ! -f /home/kindred/.ssh/id_ed25519 ]; then
  su -s /bin/bash kindred -c \
    "ssh-keygen -t ed25519 -N '' -q -f /home/kindred/.ssh/id_ed25519 -C kindred-lxc-deploy"
fi
chown kindred:kindred /home/kindred/.ssh/id_ed25519

# Route github.com SSH over port 443 (ssh.github.com). Outbound port 22 is
# blocked on a lot of LXC host networking; 443 is almost always open and
# GitHub officially supports it. accept-new auto-pins the host key on first
# connect (no ssh-keyscan needed).
cat > /home/kindred/.ssh/config <<'SSHCFG'
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
SSHCFG
chown kindred:kindred /home/kindred/.ssh/config
chmod 600 /home/kindred/.ssh/config
KEY_EOF

  if [ -z "$DEPLOY_KEY" ]; then
    PUBKEY="$(pct exec "$CT_ID" -- cat /home/kindred/.ssh/id_ed25519.pub)"

    # Derive the repo's deploy-keys page from git@github.com:owner/repo.git
    KEYS_URL=""
    case "$GIT_REPO" in
      git@github.com:*)
        REPO_PATH="${GIT_REPO#git@github.com:}"
        REPO_PATH="${REPO_PATH%.git}"
        KEYS_URL="https://github.com/${REPO_PATH}/settings/keys"
        ;;
    esac

    cat <<KEY_BANNER

==============================================================
 PRIVATE REPO — deploy key required

 Add this public key as a read-only Deploy Key on GitHub:${KEYS_URL:+
   ${KEYS_URL}}
   (Repo -> Settings -> Deploy keys -> Add deploy key)

 ${PUBKEY}
==============================================================
KEY_BANNER

    # Read from /dev/tty so the one-liner `curl ... | bash` still works.
    # Surface the real ssh error on the first failure so it's not a guessing game.
    shown_err=0
    until pct exec "$CT_ID" -- su -s /bin/bash kindred -c \
      "GIT_SSH_COMMAND='ssh -o BatchMode=yes' git ls-remote '$GIT_REPO' HEAD" \
      >/tmp/kindred-verify.err 2>&1; do
      if [ "$shown_err" -eq 0 ]; then
        shown_err=1
        echo
        echo "---- ssh/git error (first attempt) ----" >&2
        cat /tmp/kindred-verify.err >&2 || true
        echo "---------------------------------------" >&2
        echo "  - 'Permission denied (publickey)' => deploy key not added/accepted on GitHub yet" >&2
        echo "  - 'Connection refused/timed out'  => port 443 egress also blocked from the CT" >&2
        echo
      fi
      read -r -p "Key not authorized yet. Press Enter to retry (Ctrl-C to abort)... " </dev/tty || exit 1
    done
    log "Deploy key authorized."
  fi
fi

# --- Provision inside the container -------------------------------------------
log "Provisioning (Node.js $NODE_MAJOR, build, systemd service)..."
pct exec "$CT_ID" -- env \
  GIT_REPO="$GIT_REPO" \
  BRANCH="$BRANCH" \
  APP_PORT="$APP_PORT" \
  NODE_MAJOR="$NODE_MAJOR" \
  bash -s <<'CONTAINER_EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates build-essential python3 openssh-client sudo sqlite3

# Node.js via NodeSource
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
apt-get install -y -qq nodejs

# Unprivileged service user owns the checkout
id kindred >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --create-home kindred
install -d -o kindred -g kindred /opt/kindred
as_app_user() {
  su -s /bin/bash kindred -c "cd /opt/kindred && $*"
}

# Deploy the app
if [ -d /opt/kindred/.git ]; then
  as_app_user "git pull --ff-only"
else
  as_app_user "git clone --depth 1 --branch '$BRANCH' '$GIT_REPO' /opt/kindred"
fi
as_app_user "npm ci --no-audit --no-fund"
as_app_user "npm run build"

cat > /etc/systemd/system/kindred.service <<UNIT_EOF
[Unit]
Description=Kindred Friend CRM
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kindred
WorkingDirectory=/opt/kindred
Environment=NODE_ENV=production
Environment=HOSTNAME=0.0.0.0
Environment=PORT=${APP_PORT}
# Load /etc/kindred/auth.env (AUTH_SECRET for cookie signing) if present.
EnvironmentFile=-/etc/kindred/auth.env
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now kindred

# Wait for the app to come up, then hit the homepage once so the
# feed token is generated in the database.
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then
    break
  fi
  [ "$i" -lt 30 ] || { echo "App did not start in time" >&2; exit 1; }
  sleep 2
done

# --- Admin auth + setup token + sudoers rule for the wizard/UI -------------
# Mint AUTH_SECRET (cookie signing key) and the one-time setup token the
# operator pastes into the first-run wizard. Also install the sudoers rule
# that lets the unprivileged kindred user invoke the privileged backup
# config helper via sudo (used by the wizard's step 2 and /api/admin/backup/enable).
bash /opt/kindred/scripts/setup-auth.sh >/dev/null 2>&1 || true

# Sudoers whitelist: lets the kindred Next.js process invoke the privileged
# backup-config helper. The helper validates its input file (path under
# /tmp, owned by kindred, JSON schema) before touching /etc/kindred/*.
# `sudo` is installed above; ensure /etc/sudoers.d exists just in case (it
# comes with the sudo package on Debian).
install -d -m 0750 -o root -g root /etc/sudoers.d
cat > /etc/sudoers.d/kindred-configure-backup <<'SUDOERS'
kindred ALL=(root) NOPASSWD: /usr/bin/node /opt/kindred/scripts/configure-backup-privileged.js
SUDOERS
chmod 0440 /etc/sudoers.d/kindred-configure-backup
chown root:root /etc/sudoers.d/kindred-configure-backup
visudo -cf /etc/sudoers.d/kindred-configure-backup >/dev/null

# Optional: pre-install restic + backup config so the wizard's step 2 is
# already done by the time the operator logs in.
if [ "${ENABLE_BACKUP:-0}" = "1" ] && [ -n "${BACKUP_S3_ENDPOINT:-}" ] && [ -n "${BACKUP_S3_BUCKET:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "===> ENABLE_BACKUP=1 + BACKUP_S3_* env vars set: pre-configuring backups ..."
  CFG_TMP=/tmp/.kindred-backup-preconfig.json
  cat > "$CFG_TMP" <<JSON
{
  "endpoint": "${BACKUP_S3_ENDPOINT}",
  "bucket":   "${BACKUP_S3_BUCKET}",
  "prefix":   "${BACKUP_S3_PREFIX:-kindred/$(hostname)}",
  "region":   "${BACKUP_S3_REGION:-}",
  "access_key_id":     "${AWS_ACCESS_KEY_ID}",
  "secret_access_key": "${AWS_SECRET_ACCESS_KEY}",
  "restic_password":   null
}
JSON
  chmod 0600 "$CFG_TMP"
  chown kindred:kindred "$CFG_TMP"
  /usr/bin/node /opt/kindred/scripts/configure-backup-privileged.js "$CFG_TMP" || echo "WARN: pre-config failed — wizard will handle on first login" >&2
  rm -f "$CFG_TMP"
fi

CONTAINER_EOF

# --- Read results & print the feed URL ----------------------------------------
KINDRED_IP="$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')"
KINDRED_TOKEN="$(pct exec "$CT_ID" -- su -s /bin/bash kindred -c 'node /opt/kindred/scripts/print-feed-token.js' | tr -d '[:space:]')"

FEED_URL="http://${KINDRED_IP}:${APP_PORT}/api/feed/${KINDRED_TOKEN}.ics"

# Read the one-time setup token that setup-auth.sh wrote into /etc/kindred/setup-token.
SETUP_TOKEN="$(pct exec "$CT_ID" -- cat /etc/kindred/setup-token 2>/dev/null | tr -d '[:space:]' || true)"

DEPLOY_NOTE=""
if [ "$USE_SSH" -eq 1 ]; then
  DEPLOY_NOTE="
   Deploy key: /home/kindred/.ssh/id_ed25519.pub (inside the CT)
               revoke on GitHub: repo -> Settings -> Deploy keys"
fi

cat <<SUMMARY

=============================================================
 Kindred is deployed and running.

   Web UI:     http://${KINDRED_IP}:${APP_PORT}
   Container:  CT $CT_ID ($HOSTNAME), starts on boot
   Service:    systemctl status kindred   (inside the CT)
   Update:     ./proxmox/update-lxc.sh $CT_ID   (from this host)${DEPLOY_NOTE}

 First-run setup — browse to the Web UI, you'll be redirected to /setup.
 Paste this one-time setup token when prompted:

   ${SETUP_TOKEN}

 (the token is also saved at /etc/kindred/setup-token inside the CT and
  is consumed the moment you complete the wizard)

 ICS feed URL — copy this into Home Assistant
 (Settings -> Devices & Services -> Add Integration
  -> "Remote Calendar" -> paste URL):

   ${FEED_URL}

   Anyone with this URL can read the feed. Keep it secret.
=============================================================
SUMMARY
