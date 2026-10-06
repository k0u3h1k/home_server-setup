#!/usr/bin/env bash
# bootstrap.sh — Interactive homelab setup for a fresh Linux distro install
# Usage: sudo ./bootstrap.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTUAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
USER_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"

# ── Colors & UI ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()     { echo -e "${CYAN}[bootstrap]${RESET} $*"; }
ok()      { echo -e "${GREEN}[ok]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET} $*"; }
err()     { echo -e "${RED}[err]${RESET} $*" >&2; }
heading() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}\n"; }

# ── State Tracking ──────────────────────────────────────────────────────────
INSTALLED_STEPS=()
STORAGE_MOUNT="/mnt/storage"
DOMAIN="lab.local"
TAILSCALE_FQDN=""
TAILSCALE_HOST=""
MARIADB_ROOT_PASS=""
MARIADB_NC_PASS=""
REDIS_PASS=""
NEXTCLOUD_ADMIN_USER=""
NEXTCLOUD_ADMIN_PASS=""
PLAYIT_SECRET=""

# ── Interactive Helpers ─────────────────────────────────────────────────────
# Prompt for yes/no question with default
ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local prompt_suffix="[Y/n]"
  [[ "$default" == "n" ]] && prompt_suffix="[y/N]"

  while true; do
    local answer=""
    if [[ -t 0 ]]; then
      read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} ${prompt_suffix} ")" answer
    elif [[ -e /dev/tty ]]; then
      read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} ${prompt_suffix} ")" answer </dev/tty
    else
      answer="$default"
    fi
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "Please answer yes (y) or no (n)." ;;
    esac
  done
}

# Prompt for text input with optional default
ask_input() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local val=""

  while true; do
    if [[ -n "$default" ]]; then
      if [[ -t 0 ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} [${default}]: ")" val
      elif [[ -e /dev/tty ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} [${default}]: ")" val </dev/tty
      else
        val="$default"
      fi
      val="${val:-$default}"
    else
      if [[ -t 0 ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt}: ")" val
      elif [[ -e /dev/tty ]]; then
        read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt}: ")" val </dev/tty
      fi
    fi
    if [[ -n "$val" ]]; then
      break
    fi
    echo -e "${RED}[err] Value cannot be blank.${RESET}" >&2
  done
  printf -v "$var_name" '%s' "$val"
}

# Prompt for masked password with confirmation
ask_password() {
  local prompt="$1"
  local var_name="$2"
  local p1=""
  local p2=""

  while true; do
    if [[ -t 0 ]]; then
      read -rsp "$(echo -e "${YELLOW}?${RESET} ${prompt}: ")" p1
    elif [[ -e /dev/tty ]]; then
      read -rsp "$(echo -e "${YELLOW}?${RESET} ${prompt}: ")" p1 </dev/tty
    else
      err "Non-interactive terminal cannot read password safely."
      return 1
    fi
    echo ""
    if [[ -z "$p1" ]]; then
      echo -e "${RED}[err] Password cannot be empty.${RESET}" >&2
      continue
    fi
    if [[ -t 0 ]]; then
      read -rsp "$(echo -e "${YELLOW}?${RESET} Confirm ${prompt}: ")" p2
    elif [[ -e /dev/tty ]]; then
      read -rsp "$(echo -e "${YELLOW}?${RESET} Confirm ${prompt}: ")" p2 </dev/tty
    fi
    echo ""
    if [[ "$p1" != "$p2" ]]; then
      echo -e "${RED}[err] Passwords do not match. Please try again.${RESET}" >&2
    else
      break
    fi
  done
  printf -v "$var_name" '%s' "$p1"
}

# Prompt for optional secret (plain visible paste or empty)
ask_secret_optional() {
  local prompt="$1"
  local var_name="$2"
  local val=""

  if [[ -t 0 ]]; then
    read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} (leave blank to skip): ")" val
  elif [[ -e /dev/tty ]]; then
    read -rp "$(echo -e "${YELLOW}?${RESET} ${prompt} (leave blank to skip): ")" val </dev/tty
  fi
  printf -v "$var_name" '%s' "$val"
}

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Must run as root (use sudo ./bootstrap.sh)."
  exit 1
fi

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

# ── Step 1: System Preparation ───────────────────────────────────────────────
system_prep() {
  heading "Step 1/11: System Preparation"
  if ! ask_yes_no "Install system packages (curl, git, ufw, etc.) and disable swap?"; then
    warn "Skipping system preparation."
    return
  fi

  local distro
  distro=$(detect_distro)
  log "Detected Linux distribution: $distro"

  case "$distro" in
    debian|ubuntu)
      apt-get update -qq
      apt-get install -y -qq curl git ufw htop iotop unzip ca-certificates gnupg lsb-release
      ;;
    fedora)
      dnf install -y curl git ufw htop iotop unzip ca-certificates
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm curl git ufw htop iotop unzip ca-certificates
      ;;
    *)
      warn "Unknown distro '$distro'. Please ensure curl, git, and ca-certificates are installed."
      ;;
  esac

  swapoff -a 2>/dev/null || true
  sed -i '/swap/d' /etc/fstab 2>/dev/null || true
  ok "System packages installed and swap disabled."
  INSTALLED_STEPS+=("System Preparation")
}

# ── Step 2: Storage Mount ────────────────────────────────────────────────────
setup_storage() {
  heading "Step 2/11: Storage Mount"
  if ! ask_yes_no "Configure persistent storage mount?"; then
    warn "Skipping storage configuration. (Default path /mnt/storage will be assumed for apps)"
    mkdir -p "$STORAGE_MOUNT"/{minecraft,music,navidrome,nextcloud,backups} 2>/dev/null || true
    return
  fi

  ask_input "Enter storage mount point" "$STORAGE_MOUNT" STORAGE_MOUNT

  if mountpoint -q "$STORAGE_MOUNT"; then
    ok "Storage already mounted at $STORAGE_MOUNT"
  else
    local storage_dev=""
    ask_input "Enter storage block device (or 'skip' to skip disk formatting/mount)" "/dev/sdb" storage_dev

    if [[ "$storage_dev" != "skip" ]]; then
      if [[ ! -b "$storage_dev" ]]; then
        warn "Storage device $storage_dev not found. Skipping disk mount."
      else
        mkdir -p "$STORAGE_MOUNT"
        local part=""
        if [[ -b "${storage_dev}1" ]]; then
          part="${storage_dev}1"
        elif [[ -b "${storage_dev}p1" ]]; then
          part="${storage_dev}p1"
        elif [[ -b "${storage_dev}2" ]]; then
          part="${storage_dev}2"
        elif [[ -b "${storage_dev}p2" ]]; then
          part="${storage_dev}p2"
        else
          warn "No existing partition found on $storage_dev."
          if ask_yes_no "Format $storage_dev as ext4 partition? WARNING: ERASES ALL DATA" "n"; then
            echo -e "n\np\n1\n\n\nw" | fdisk "$storage_dev"
            part="${storage_dev}1"
            mkfs.ext4 -F "$part"
          fi
        fi

        if [[ -n "$part" && -b "$part" ]]; then
          local fstype
          fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "ext4")
          mount "$part" "$STORAGE_MOUNT"

          if ! grep -q "$STORAGE_MOUNT" /etc/fstab; then
            local uuid
            uuid=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
            if [[ -n "$uuid" ]]; then
              echo "UUID=$uuid  $STORAGE_MOUNT  $fstype  defaults,nofail  0  2" >> /etc/fstab
            else
              echo "$part  $STORAGE_MOUNT  $fstype  defaults,nofail  0  2" >> /etc/fstab
            fi
          fi
          ok "Mounted $part to $STORAGE_MOUNT."
        fi
      fi
    fi
  fi

  mkdir -p "$STORAGE_MOUNT"/{minecraft,music,navidrome,nextcloud,backups}
  ok "Created storage directories under $STORAGE_MOUNT."
  INSTALLED_STEPS+=("Storage Mount ($STORAGE_MOUNT)")
}

# ── Step 3: Docker ───────────────────────────────────────────────────────────
setup_docker() {
  heading "Step 3/11: Docker Engine"
  if ! ask_yes_no "Install Docker engine and compose plugin?"; then
    warn "Skipping Docker installation."
    return
  fi

  if command -v docker &>/dev/null; then
    ok "Docker is already installed ($(docker --version))."
  else
    local distro
    distro=$(detect_distro)
    case "$distro" in
      debian|ubuntu)
        curl -fsSL https://get.docker.com | bash
        ;;
      fedora)
        dnf install -y docker docker-compose-plugin
        systemctl enable --now docker
        ;;
      arch|manjaro)
        pacman -Sy --noconfirm docker docker-compose-plugin
        systemctl enable --now docker
        ;;
      *)
        curl -fsSL https://get.docker.com | bash
        ;;
    esac
  fi

  if [[ -n "$ACTUAL_USER" && "$ACTUAL_USER" != "root" ]]; then
    usermod -aG docker "$ACTUAL_USER" 2>/dev/null || true
    ok "User '$ACTUAL_USER' added to docker group."
  fi
  ok "Docker engine ready."
  INSTALLED_STEPS+=("Docker Engine")
}

# ── Step 4: K3s ──────────────────────────────────────────────────────────────
setup_k3s() {
  heading "Step 4/11: K3s Kubernetes"
  if ! ask_yes_no "Install K3s lightweight Kubernetes cluster?"; then
    warn "Skipping K3s installation."
    return
  fi

  if command -v k3s &>/dev/null; then
    ok "K3s is already installed ($(k3s --version 2>/dev/null | head -n1))."
  else
    local k3s_channel=""
    ask_input "Enter K3s channel or version (press enter for default stable)" "stable" k3s_channel

    if [[ "$k3s_channel" =~ ^v[0-9] ]]; then
      curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$k3s_channel" sh -
    else
      curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="$k3s_channel" sh -
    fi
  fi

  # Configure kubeconfig for current user and root
  mkdir -p "$USER_HOME/.kube" /root/.kube
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
    cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    if [[ -n "$ACTUAL_USER" ]]; then
      chown -R "$ACTUAL_USER:$(id -gn "$ACTUAL_USER" 2>/dev/null || echo "$ACTUAL_USER")" "$USER_HOME/.kube" 2>/dev/null || true
    fi
    chmod 600 "$USER_HOME/.kube/config" /root/.kube/config
  fi
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

  log "Waiting for K3s node to report Ready state..."
  local ready=false
  for _ in $(seq 1 60); do
    if kubectl get nodes 2>/dev/null | grep -q Ready; then
      ready=true
      break
    fi
    sleep 2
  done

  if [[ "$ready" == "true" ]]; then
    ok "K3s node is Ready."
  else
    warn "K3s node not Ready after 120s. Verify with: kubectl get nodes"
  fi
  INSTALLED_STEPS+=("K3s Kubernetes")
}

# ── Step 5: Helm ─────────────────────────────────────────────────────────────
setup_helm() {
  heading "Step 5/11: Helm Package Manager"
  if ! ask_yes_no "Install Helm and add Bitnami/Nextcloud chart repositories?"; then
    warn "Skipping Helm installation."
    return
  fi

  if command -v helm &>/dev/null; then
    ok "Helm is already installed ($(helm version --short 2>/dev/null || echo 'installed'))."
  else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo add nextcloud https://nextcloud.github.io/helm/ 2>/dev/null || true
  helm repo update 2>/dev/null || true
  ok "Helm ready and repositories updated."
  INSTALLED_STEPS+=("Helm Package Manager")
}

# ── Step 6: Databases ────────────────────────────────────────────────────────
setup_databases() {
  heading "Step 6/11: Centralized Databases"
  if ! ask_yes_no "Deploy databases (MariaDB & Redis) in Kubernetes?"; then
    warn "Skipping database deployment."
    return
  fi

  kubectl create namespace databases 2>/dev/null || true

  # MariaDB
  if ask_yes_no "  Deploy MariaDB (required for Nextcloud)?" "y"; then
    if kubectl get statefulset -n databases mariadb &>/dev/null; then
      ok "MariaDB StatefulSet already exists in 'databases' namespace."
    else
      log "MariaDB Credentials Setup:"
      ask_password "MariaDB root password" MARIADB_ROOT_PASS
      ask_password "MariaDB Nextcloud user password" MARIADB_NC_PASS

      log "Deploying MariaDB via Helm..."
      helm upgrade --install mariadb bitnami/mariadb -n databases \
        --set auth.rootPassword="$MARIADB_ROOT_PASS" \
        --set auth.database=nextcloud \
        --set auth.username=nextcloud \
        --set auth.password="$MARIADB_NC_PASS" \
        --set primary.persistence.size=20Gi \
        --set primary.resources.requests.cpu=100m \
        --set primary.resources.requests.memory=256Mi \
        --set primary.resources.limits.cpu=1000m \
        --set primary.resources.limits.memory=1Gi \
        --set architecture=standalone \
        --wait --timeout 5m
      ok "MariaDB deployed successfully."
      INSTALLED_STEPS+=("MariaDB Database")
    fi
  fi

  # Redis
  if ask_yes_no "  Deploy Redis (cache / memory store)?" "y"; then
    if kubectl get statefulset -n databases redis-master &>/dev/null; then
      ok "Redis StatefulSet already exists in 'databases' namespace."
    else
      log "Redis Credentials Setup:"
      ask_password "Redis password" REDIS_PASS

      log "Deploying Redis via Helm..."
      helm upgrade --install redis bitnami/redis -n databases \
        --set auth.enabled=true \
        --set auth.password="$REDIS_PASS" \
        --set master.persistence.size=5Gi \
        --set master.resources.requests.cpu=50m \
        --set master.resources.requests.memory=128Mi \
        --set master.resources.limits.cpu=500m \
        --set master.resources.limits.memory=512Mi \
        --set replica.replicaCount=0 \
        --wait --timeout 5m
      ok "Redis deployed successfully."
      INSTALLED_STEPS+=("Redis Database")
    fi
  fi
}

# ── Step 7: Applications ─────────────────────────────────────────────────────
setup_apps() {
  heading "Step 7/11: Homelab Applications"
  if ! ask_yes_no "Deploy homelab applications (Navidrome, Nextcloud, Glance)?"; then
    warn "Skipping applications deployment."
    return
  fi

  # Prompt for domains/hostnames if not already asked
  if [[ -z "$TAILSCALE_FQDN" ]]; then
    ask_input "Tailscale FQDN (e.g. homeserver.tailb96c63.ts.net)" "homeserver.tailb96c63.ts.net" TAILSCALE_FQDN
    TAILSCALE_HOST="${TAILSCALE_FQDN%%.*}"
  fi
  if [[ -z "$DOMAIN" ]]; then
    ask_input "Local cluster domain suffix" "lab.local" DOMAIN
  fi

  # 1. Navidrome
  if ask_yes_no "  Deploy Navidrome (Music streaming server)?"; then
    if [[ -d "$REPO_DIR/apps/navidrome" ]]; then
      kubectl create namespace navidrome 2>/dev/null || true
      log "Deploying Navidrome via Helm..."
      helm upgrade --install navidrome "$REPO_DIR/apps/navidrome" \
        -n navidrome \
        --set storage.music.hostPath="$STORAGE_MOUNT/music" \
        --set storage.data.hostPath="$STORAGE_MOUNT/navidrome" \
        --wait --timeout 3m
      ok "Navidrome deployed successfully."
      INSTALLED_STEPS+=("Navidrome")
    else
      warn "Navidrome chart not found at $REPO_DIR/apps/navidrome."
    fi
  fi

  # 2. Nextcloud
  if ask_yes_no "  Deploy Nextcloud (Cloud storage & collaboration)?"; then
    kubectl create namespace nextcloud 2>/dev/null || true

    log "Nextcloud Administrator & Database Setup:"
    ask_input "Nextcloud admin username" "admin" NEXTCLOUD_ADMIN_USER
    ask_password "Nextcloud admin password" NEXTCLOUD_ADMIN_PASS

    if [[ -z "$MARIADB_NC_PASS" ]]; then
      ask_password "MariaDB password for Nextcloud user" MARIADB_NC_PASS
    fi
    if [[ -z "$REDIS_PASS" ]]; then
      ask_password "Redis password for Nextcloud cache" REDIS_PASS
    fi

    # Create PV and PVC with dynamic storage mount
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nextcloud-data-pv
  labels:
    type: local
spec:
  storageClassName: manual
  capacity:
    storage: 256Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: ${STORAGE_MOUNT}/nextcloud
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data
  namespace: nextcloud
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 256Gi
EOF

    local nc_values
    nc_values=$(mktemp /tmp/nextcloud-values-XXXXXX.yaml)
    chmod 600 "$nc_values"

    cat > "$nc_values" << VALUES
nextcloud:
  host: ${TAILSCALE_FQDN}
  username: ${NEXTCLOUD_ADMIN_USER}
  password: "${NEXTCLOUD_ADMIN_PASS}"
  trusted_domains:
    - ${TAILSCALE_FQDN}
    - ${TAILSCALE_FQDN}:8443
    - nextcloud.${DOMAIN}
  configs:
    ratelimit.config.php: |-
      <?php
      \$CONFIG = array (
        'ratelimit.protection.enabled' => false,
        'auth.bruteforce.protection.enabled' => false,
        'auth.bruteforce.max-attempts' => 9999,
      );
    overwriteprotocol.config.php: |-
      <?php
      \$CONFIG = array (
        'overwriteprotocol' => 'https',
      );
internalDatabase:
  enabled: false
mariadb:
  enabled: false
externalDatabase:
  enabled: true
  type: mysql
  host: mariadb.databases.svc.cluster.local
  database: nextcloud
  user: nextcloud
  password: "${MARIADB_NC_PASS}"
redis:
  enabled: false
externalRedis:
  enabled: true
  host: redis-master.databases.svc.cluster.local
  port: "6379"
  password: "${REDIS_PASS}"
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
  hosts:
    - host: ${TAILSCALE_FQDN}
      paths:
        - /
    - host: nextcloud.${DOMAIN}
      paths:
        - /
persistence:
  enabled: true
  existingClaim: nextcloud-data
resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi
cronjob:
  enabled: true
VALUES

    log "Deploying Nextcloud via Helm..."
    helm upgrade --install nextcloud oci://registry-1.docker.io/nextcloud/nextcloud \
      -n nextcloud -f "$nc_values" --wait --timeout 10m
    rm -f "$nc_values"
    ok "Nextcloud deployed successfully."
    INSTALLED_STEPS+=("Nextcloud")
  fi

  # 3. Glance
  if ask_yes_no "  Deploy Glance (Homelab dashboard)?"; then
    if [[ -d "$REPO_DIR/charts/glance" ]]; then
      kubectl create namespace glance 2>/dev/null || true
      log "Deploying Glance via Helm..."
      helm upgrade --install glance "$REPO_DIR/charts/glance" -n glance --wait --timeout 3m
      ok "Glance deployed successfully."
      INSTALLED_STEPS+=("Glance")
    else
      warn "Glance chart not found at $REPO_DIR/charts/glance."
    fi
  fi
}

# ── Step 8: Networking ───────────────────────────────────────────────────────
setup_networking() {
  heading "Step 8/11: Networking (/etc/hosts & Tailscale Serve)"
  if ! ask_yes_no "Configure local networking (/etc/hosts and Tailscale Serve)?"; then
    warn "Skipping networking configuration."
    return
  fi

  if [[ -z "$DOMAIN" ]]; then
    ask_input "Local domain suffix" "lab.local" DOMAIN
  fi
  if [[ -z "$TAILSCALE_FQDN" ]]; then
    ask_input "Tailscale FQDN (e.g. homeserver.tailb96c63.ts.net)" "homeserver.tailb96c63.ts.net" TAILSCALE_FQDN
    TAILSCALE_HOST="${TAILSCALE_FQDN%%.*}"
  fi

  local detected_ip
  detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "192.168.0.250")
  local lan_ip=""
  ask_input "LAN IP address for /etc/hosts entries" "$detected_ip" lan_ip

  for host in glance navidrome nextcloud; do
    if ! grep -q "${host}.${DOMAIN}" /etc/hosts 2>/dev/null; then
      echo "${lan_ip}  ${host}.${DOMAIN}" >> /etc/hosts
    fi
  done
  ok "/etc/hosts entries updated for ${DOMAIN}."

  # Install host sync script if available
  if [[ -f "$REPO_DIR/scripts/update-homeserver-hosts" ]]; then
    install -m 755 "$REPO_DIR/scripts/update-homeserver-hosts" /usr/local/bin/update-homeserver-hosts
    if [[ -f "$REPO_DIR/scripts/homeserver-hosts.service" ]]; then
      install -m 644 "$REPO_DIR/scripts/homeserver-hosts.service" /etc/systemd/system/homeserver-hosts.service
      systemctl daemon-reload
      systemctl enable --now homeserver-hosts.service 2>/dev/null || true
    fi
  fi

  # Tailscale Serve
  if command -v tailscale &>/dev/null; then
    if tailscale status &>/dev/null; then
      log "Configuring Tailscale Serve..."
      tailscale serve --bg --https 4443 http://glance.glance:8080 2>/dev/null || true
      tailscale serve --bg --https 4533 http://navidrome.navidrome:4533 2>/dev/null || true
      tailscale serve --bg --https 8443 http://nextcloud.nextcloud:8080 2>/dev/null || true
      ok "Tailscale Serve configured (Glance: 4443, Navidrome: 4533, Nextcloud: 8443)."
    else
      warn "Tailscale not authenticated. Run 'sudo tailscale up' to enable Tailscale Serve."
    fi
  else
    warn "Tailscale binary not found. Install from https://tailscale.com/download if remote access is desired."
  fi
  INSTALLED_STEPS+=("Networking")
}

# ── Step 9: Minecraft ────────────────────────────────────────────────────────
setup_minecraft() {
  heading "Step 9/11: Minecraft Fabric Docker Server"
  if ! ask_yes_no "Set up Minecraft Fabric Docker server?"; then
    warn "Skipping Minecraft setup."
    return
  fi

  local mc_dir="$REPO_DIR/apps/minecraft-docker"
  mkdir -p "$mc_dir" "$STORAGE_MOUNT/minecraft"

  # Ensure mc_status_server.py is present on the storage mount
  if [[ -f "$mc_dir/mc_status_server.py" ]]; then
    cp "$mc_dir/mc_status_server.py" "$STORAGE_MOUNT/mc_status_server.py"
  else
    cat > "$STORAGE_MOUNT/mc_status_server.py" << 'PY'
import socket, json
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        data = {"online": False, "version": "", "players": 0, "max_players": 0}
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3)
            s.connect(("minecraft", 25565))
            s.send(b"\xfe\x01")
            raw = s.recv(4096)
            if raw and raw[0] == 0xff:
                raw = raw[3:].decode("utf-16be", errors="ignore")
                parts = raw.split("\x00")
                data = {"online": True, "version": parts[2] if len(parts) > 2 else "",
                        "players": int(parts[4]) if len(parts) > 4 else 0,
                        "max_players": int(parts[5]) if len(parts) > 5 else 0}
            s.close()
        except Exception:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8082), Handler).serve_forever()
PY
  fi
  chmod 755 "$STORAGE_MOUNT/mc_status_server.py"

  # Make all helper scripts executable
  chmod +x "$mc_dir"/*.sh 2>/dev/null || true

  ok "Minecraft directories, scripts, and status monitor prepared."

  if ask_yes_no "  Start Minecraft server containers now via Docker Compose?" "n"; then
    (cd "$mc_dir" && ./start.sh)
    ok "Minecraft server started."
  fi
  INSTALLED_STEPS+=("Minecraft Server")
}

# ── Step 10: Playit ──────────────────────────────────────────────────────────
setup_playit() {
  heading "Step 10/11: Playit.gg Tunnel"
  if ! ask_yes_no "Install and configure Playit tunnel agent?"; then
    warn "Skipping Playit setup."
    return
  fi

  mkdir -p /opt/playit /etc/playit /var/log/playit

  if ! command -v /opt/playit/playitd &>/dev/null; then
    log "Downloading Playit agent binary..."
    curl -fsSL https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-amd64.tar.gz \
      -o /tmp/playit.tar.gz
    tar xzf /tmp/playit.tar.gz -C /tmp/
    install -m 755 /tmp/playit-linux-amd64 /opt/playit/playitd
    rm -f /tmp/playit.tar.gz /tmp/playit-linux-amd64
  fi

  # Symlink to /usr/local/bin/playit so playit-start.sh and CLI work seamlessly
  ln -sf /opt/playit/playitd /usr/local/bin/playit

  log "Playit Secret Key Setup:"
  echo -e "  ${YELLOW}Notice:${RESET} If you do not have a Playit secret key yet, leave this blank."
  echo -e "  The agent will generate a claim link on its first start."
  ask_secret_optional "Enter Playit secret key" PLAYIT_SECRET

  if [[ -n "$PLAYIT_SECRET" ]]; then
    cat > /etc/playit/playit.toml << TOML
secret_key = "${PLAYIT_SECRET}"
TOML
  else
    cat > /etc/playit/playit.toml << 'TOML'
# No secret_key specified yet.
# Check /var/log/playit/playit.log or run 'playit setup' to link this agent to your playit.gg account.
TOML
  fi
  chmod 600 /etc/playit/playit.toml

  cat > /etc/systemd/system/playit.service << 'UNIT'
[Unit]
Description=Playit Agent
Documentation=https://playit.gg
Wants=network-pre.target
After=network-pre.target

[Service]
User=playit
Group=playit
RuntimeDirectory=playit
RuntimeDirectoryMode=0750
LogsDirectory=playit
LogsDirectoryMode=0750
UMask=0007
ExecStart=/opt/playit/playitd --secret-path /etc/playit/playit.toml --socket-path /run/playit/playitd.sock -l /var/log/playit/playit.log
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

  id -u playit &>/dev/null || useradd -r -s /sbin/nologin playit
  chown -R playit:playit /opt/playit /etc/playit /var/log/playit

  systemctl daemon-reload
  systemctl enable playit
  systemctl restart playit
  ok "Playit agent installed and service started."

  if [[ -z "$PLAYIT_SECRET" ]]; then
    echo ""
    warn "Playit was started without a secret key."
    log "Check the claim URL in the log with: sudo tail -n 20 /var/log/playit/playit.log"
    log "Or run 'playit setup' in your terminal."
  fi
  INSTALLED_STEPS+=("Playit Tunnel")
}

# ── Step 11: Display Services ────────────────────────────────────────────────
setup_display() {
  heading "Step 11/11: Display Power Management"
  if ! ask_yes_no "Install panel-off.service (powers off laptop internal display)?" "n"; then
    warn "Skipping display service installation."
    return
  fi

  cat > /etc/systemd/system/panel-off.service << 'UNIT'
[Unit]
Description=Power off internal display panel via fbdev DPMS
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/bin/sh -c 'echo 4 > /sys/class/graphics/fb0/blank || true; echo 4 > /sys/class/backlight/intel_backlight/bl_power || true'

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  ok "Installed /etc/systemd/system/panel-off.service."

  if ask_yes_no "  Enable panel-off.service to automatically run on boot?" "n"; then
    systemctl enable panel-off.service
    ok "panel-off.service enabled."
  fi
  INSTALLED_STEPS+=("Display Power Service")
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  heading "Bootstrap Summary"
  if [[ ${#INSTALLED_STEPS[@]} -eq 0 ]]; then
    warn "No components were installed."
    return
  fi

  echo -e "${GREEN}Configured Components:${RESET}"
  for step in "${INSTALLED_STEPS[@]}"; do
    echo -e "  ✔ $step"
  done
  echo ""

  local target_host="${TAILSCALE_FQDN:-${DOMAIN}}"
  echo -e "${BOLD}Service Access URLs:${RESET}"
  for step in "${INSTALLED_STEPS[@]}"; do
    case "$step" in
      Glance)
        echo -e "  • Glance Dashboard:   https://${target_host}:4443"
        ;;
      Navidrome)
        echo -e "  • Navidrome Music:    https://${target_host}:4533 (or LAN port 31433)"
        ;;
      Nextcloud)
        echo -e "  • Nextcloud:          https://${target_host}:8443"
        ;;
      "Minecraft Server")
        echo -e "  • Minecraft Server:   <host-ip>:25565 / status API at http://<host-ip>:8082"
        ;;
    esac
  done

  echo ""
  echo -e "${BOLD}Next steps:${RESET}"
  if [[ " ${INSTALLED_STEPS[*]} " =~ "Docker" ]]; then
    echo "  1. If you were added to the docker group, log out and log back in (or run 'newgrp docker')."
  fi
  if [[ " ${INSTALLED_STEPS[*]} " =~ "Minecraft" ]]; then
    echo "  2. Minecraft management: cd apps/minecraft-docker && ./status.sh"
  fi
  echo "  3. Cluster status: kubectl get nodes,pods -A"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${RESET}"
  echo -e "${BOLD}${CYAN}               Home Server Setup & Bootstrapper                       ${RESET}"
  echo -e "${BOLD}${CYAN}──────────────────────────────────────────────────────────────────────${RESET}"
  echo "You will be prompted before each step to choose whether to install it,"
  echo "and to provide custom passwords, usernames, and hostnames directly."
  echo ""

  system_prep
  setup_storage
  setup_docker
  setup_k3s
  setup_helm
  setup_databases
  setup_apps
  setup_networking
  setup_minecraft
  setup_playit
  setup_display
  print_summary
}

main "$@"