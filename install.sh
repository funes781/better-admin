set -euo pipefail

# COLORS
RED='\033[0;31m'; 
GREEN='\033[0;32m'; 
YELLOW='\033[1;33m'
BLUE='\033[0;34m'; 
CYAN='\033[0;36m'; 
BOLD='\033[1m'; 
RESET='\033[0m'

log()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}\n"; }
ask()    { echo -e "${YELLOW}[?]${RESET} $*"; }

# UTILS
confirm() {
    local msg="${1:-Continue?} [y/N] "
    read -rp "$(echo -e "${YELLOW}[?]${RESET} ${msg}")" answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This installer must be run as root (or with sudo)."
        echo "  Run: sudo bash install.sh"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
    else
        OS_ID="unknown"
        OS_VERSION=""
    fi
}

get_server_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    echo "${ip:-127.0.0.1}"
}

# DEPENDS
step_check_deps() {
    header "Step 1/6 · Checking existing dependencies"
 
    local missing=()
 
    for cmd in curl wget git python3; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd - found ($(command -v "$cmd"))"
        else
            warn "$cmd - NOT found"
            missing+=("$cmd")
        fi
    done
 
    if command -v docker &>/dev/null; then
        ok "docker - found ($(docker --version | head -1))"
        DOCKER_INSTALLED=true
    else
        warn "docker - NOT found"
        DOCKER_INSTALLED=false
    fi
 
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        ok "docker compose (plugin) - found"
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        ok "docker-compose (standalone) - found"
        COMPOSE_CMD="docker-compose"
    else
        warn "docker compose - NOT found"
        COMPOSE_CMD=""
    fi
 
    if command -v mkcert &>/dev/null; then
        ok "mkcert - found"
        MKCERT_INSTALLED=true
    else
        warn "mkcert - NOT found"
        MKCERT_INSTALLED=false
    fi
 
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        warn "Missing basic tools: ${missing[*]}"
        if ! confirm "Attempt to install missing tools automatically?"; then
            error "Cannot continue without required tools. Aborting."
            exit 1
        fi
        install_basic_tools "${missing[@]}"
    fi
}

install_basic_tools() {
    local tools=("$@")
    detect_os
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq "${tools[@]}"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y "${tools[@]}"
            else
                yum install -y "${tools[@]}"
            fi
            ;;
        *)
            warn "Unknown OS '$OS_ID'. Please install manually: ${tools[*]}"
            ;;
    esac
}
 
# DOCKER
step_install_docker() {
    header "Step 2/6 - Docker installation"
 
    if [[ "$DOCKER_INSTALLED" == true && -n "$COMPOSE_CMD" ]]; then
        ok "Docker and Compose already installed - skipping."
        return
    fi
 
    if ! confirm "Docker is not installed. Install Docker Engine now?"; then
        error "Docker is required. Aborting."
        exit 1
    fi
 
    detect_os
    log "Detected OS: ${OS_ID} ${OS_VERSION}"
 
    case "$OS_ID" in
        ubuntu|debian)
            log "Installing Docker via official script..."
            curl -fsSL https://get.docker.com | bash
            systemctl enable --now docker
            ;;
        centos|rhel|rocky|almalinux)
            log "Installing Docker on RHEL-family..."
            dnf install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            systemctl enable --now docker
            ;;
        fedora)
            dnf install -y docker docker-compose-plugin
            systemctl enable --now docker
            ;;
        *)
            warn "Unsupported OS '${OS_ID}'. Trying generic Docker script..."
            curl -fsSL https://get.docker.com | bash
            ;;
    esac
 
    local sudo_user="${SUDO_USER:-}"
    if [[ -n "$sudo_user" ]]; then
        usermod -aG docker "$sudo_user"
        ok "Added user '$sudo_user' to docker group (re-login required for effect)."
    fi
 
    COMPOSE_CMD="docker compose"
    ok "Docker installed successfully."
}

# MKCERT
step_install_mkcert() {
    header "Step 3/6 - mkcert (locally-trusted TLS)"
 
    if [[ "$MKCERT_INSTALLED" == true ]]; then
        ok "mkcert already installed - skipping."
    else
        if ! confirm "Install mkcert for locally-trusted HTTPS certificates?"; then
            warn "Skipping mkcert. HTTPS will use a self-signed cert (browser will warn)."
            MKCERT_INSTALLED=false
            return
        fi
 
        log "Installing mkcert..."
        detect_os
 
        # Install nss-tools (needed for Firefox)
        case "$OS_ID" in
            ubuntu|debian)
                apt-get install -y -qq libnss3-tools
                ;;
            centos|rhel|rocky|almalinux|fedora)
                dnf install -y nss-tools 2>/dev/null || yum install -y nss-tools
                ;;
        esac
 
        local mkcert_ver="v1.4.4"
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64)  MKCERT_ARCH="amd64" ;;
            aarch64) MKCERT_ARCH="arm64" ;;
            *)       MKCERT_ARCH="amd64" ; warn "Unknown arch $arch, defaulting to amd64" ;;
        esac
 
        curl -fsSL "https://github.com/FiloSottile/mkcert/releases/download/${mkcert_ver}/mkcert-${mkcert_ver}-linux-${MKCERT_ARCH}" \
            -o /usr/local/bin/mkcert
        chmod +x /usr/local/bin/mkcert
        MKCERT_INSTALLED=true
        ok "mkcert installed."
    fi
 
    log "Installing mkcert local CA (you may be prompted for sudo password)..."
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" CAROOT="$(sudo -u "$SUDO_USER" mkcert -CAROOT 2>/dev/null)" \
            mkcert -install 2>/dev/null || mkcert -install
    else
        mkcert -install
    fi
    ok "Local CA installed - browsers on this machine will trust the cert."
}

# TLS
step_setup_tls() {
    header "Step 4/6 - TLS configuration"
 
    local server_ip
    server_ip=$(get_server_ip)
    log "Detected server IP: ${server_ip}"
 
    echo ""
    echo "Choose HTTPS mode:"
    echo "  1) IP-only (mkcert cert for ${server_ip}) - no domain needed"
    echo "  2) Domain   - provide your domain name (config only, cert via mkcert)"
    echo "  3) Domain + Let's Encrypt (certbot) - for production with real domain"
    echo ""
    read -rp "$(echo -e "${YELLOW}[?]${RESET} Enter choice [1/2/3]: ")" tls_choice
 
    mkdir -p nginx/certs
 
    case "${tls_choice:-1}" in
        1)
            TLS_MODE="ip"
            SERVER_NAME="$server_ip"
            log "Generating mkcert certificate for IP: ${server_ip}"
            mkcert -cert-file nginx/certs/fullchain.pem \
                   -key-file  nginx/certs/privkey.pem \
                   "$server_ip" "localhost" "127.0.0.1"
            ok "Certificate generated for ${server_ip}"
            echo ""
            ok "Access your services at:"
            echo "   API      → https://${server_ip}/api/v1/status"
            echo "   Grafana  → https://${server_ip}/grafana/"
            echo "   API Docs → https://${server_ip}/docs"
            ;;
        2)
            TLS_MODE="domain"
            read -rp "$(echo -e "${YELLOW}[?]${RESET} Enter your domain (e.g. monitoring.example.com): ")" DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                error "Domain cannot be empty."
                exit 1
            fi
            SERVER_NAME="$DOMAIN"
            log "Generating mkcert certificate for domain: ${DOMAIN}"
            mkcert -cert-file nginx/certs/fullchain.pem \
                   -key-file  nginx/certs/privkey.pem \
                   "$DOMAIN" "www.${DOMAIN}"
            ok "Certificate generated for ${DOMAIN}"
            warn "Note: This cert is trusted only on this machine. For production, use option 3 (Let's Encrypt)."
            echo ""
            ok "Make sure DNS for ${DOMAIN} points to ${server_ip}, then access:"
            echo "   API      → https://${DOMAIN}/api/v1/status"
            echo "   Grafana  → https://${DOMAIN}/grafana/"
            ;;
        3)
            TLS_MODE="letsencrypt"
            read -rp "$(echo -e "${YELLOW}[?]${RESET} Enter your domain (e.g. monitoring.example.com): ")" DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                error "Domain cannot be empty."
                exit 1
            fi
            read -rp "$(echo -e "${YELLOW}[?]${RESET} Enter your email for Let's Encrypt: ")" LE_EMAIL
            SERVER_NAME="$DOMAIN"
 
            warn "Let's Encrypt mode: a temporary self-signed cert will be used on first boot."
            warn "After stack starts, run: ./certbot-renew.sh to get real cert."
 
            if command -v openssl &>/dev/null; then
                openssl req -x509 -nodes -newkey rsa:2048 \
                    -keyout nginx/certs/privkey.pem \
                    -out    nginx/certs/fullchain.pem \
                    -days   1 \
                    -subj   "/CN=${DOMAIN}" 2>/dev/null
                ok "Temporary self-signed cert created. Replace with Let's Encrypt cert after start."
            else
                error "openssl not found. Install it and re-run, or choose option 1 or 2."
                exit 1
            fi
 
            # Write certbot helper
            cat > certbot-renew.sh << CERTBOT_EOF
#!/usr/bin/env bash
# Run this after the stack is up to obtain a real Let's Encrypt certificate
set -euo pipefail
DOMAIN="${DOMAIN}"
EMAIL="${LE_EMAIL}"
 
echo "Requesting Let's Encrypt cert for \${DOMAIN}..."
docker run --rm \\
  -v "\$(pwd)/nginx/certs:/etc/letsencrypt/live/\${DOMAIN}" \\
  -v "\$(pwd)/certbot_www:/var/www/certbot" \\
  certbot/certbot certonly \\
    --webroot \\
    --webroot-path /var/www/certbot \\
    --email "\${EMAIL}" \\
    --agree-tos \\
    --no-eff-email \\
    -d "\${DOMAIN}"
 
echo "Reloading nginx..."
docker compose exec nginx nginx -s reload
echo "Done! Cert installed for \${DOMAIN}"
CERTBOT_EOF
            chmod +x certbot-renew.sh
            ok "certbot-renew.sh created. Run it after the stack is up."
            ;;
        *)
            error "Invalid choice."
            exit 1
            ;;
    esac
 
    sed -i "s/\${SERVER_NAME}/${SERVER_NAME}/g" nginx/nginx.conf
    ok "Nginx configured for: ${SERVER_NAME}"
}

step_generate_credentials() {
    header "Step 5/6 - Generating credentials & .env"
 
    if [[ -f ".env" ]]; then
        warn ".env already exists."
        if ! confirm "Regenerate credentials? (old .env will be backed up)"; then
            ok "Keeping existing .env"
            return
        fi
    fi
 
    log "Generating API key and Grafana password..."
    python3 api/generate_env.py
 
    if [[ -n "${DOMAIN:-}" ]]; then
        if grep -q "^DOMAIN=" .env; then
            sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
        else
            echo "DOMAIN=${DOMAIN}" >> .env
        fi
        ok "Domain '${DOMAIN}' saved to .env"
    fi
 
    ok "Credentials written to .env"
    echo ""
    echo -e "${YELLOW} The .env file contains secrets ${RESET}"
}

# START
step_start_stack() {
    header "Step 7/7 · Building & starting the stack"
 
    echo "The following containers will be started:"
    echo "monitoring-api         (FastAPI — port internal)"
    echo "monitoring-prometheus  (Prometheus — port internal)"
    echo "monitoring-grafana     (Grafana — port internal)"
    echo "monitoring-nginx       (Nginx — ports 80, 443)"
    # echo "monitoring-node-exporter"
    # echo "monitoring-cadvisor"
    echo ""
 
    if ! confirm "Build and start all containers now?"; then
        echo ""
        ok "Setup complete! Start manually with:"
        echo "  ${COMPOSE_CMD} up -d --build"
        exit 0
    fi
 
    log "Building images..."
    $COMPOSE_CMD build --no-cache
 
    log "Starting containers..."
    $COMPOSE_CMD up -d
 
    log "Waiting for services to be healthy (30s)..."
    sleep 30
 
    echo ""
    header "Installation complete!"
 
    local api_key
    api_key=$(grep ^API_KEY .env | cut -d= -f2)
    local gf_pass
    gf_pass=$(grep ^GRAFANA_ADMIN_PASSWORD .env | cut -d= -f2)
    local base_url="https://${SERVER_NAME}"
 
    echo -e "│  API Base     : ${CYAN}${base_url}/api/v1/${RESET}"
    echo -e "│  API Docs     : ${CYAN}${base_url}/docs${RESET}"
    echo -e "│  Grafana      : ${CYAN}${base_url}/grafana/${RESET}"
    echo -e "│  Health Check : ${CYAN}${base_url}/health${RESET}"

    echo ""

    echo -e "│  Grafana user : admin"
    echo -e "│  Grafana pass : ${YELLOW}${gf_pass}${RESET}"
    echo -e "│  API Key      : ${YELLOW}${api_key:0:20}…${RESET}  (full key in .env)"
    
    echo ""

    echo "Useful commands:"
    echo "  ${COMPOSE_CMD} ps           — container status"
    echo "  ${COMPOSE_CMD} logs -f api  — follow API logs"
    echo "  ${COMPOSE_CMD} down         — stop all containers"
    echo "  ${COMPOSE_CMD} restart api  — restart API only"
    echo ""
    if [[ "${TLS_MODE:-}" == "letsencrypt" ]]; then
        warn "Don't forget to run ./certbot-renew.sh to get your real TLS certificate!"
    fi
}

# MAIN
main() {
    if [[ ! -f "docker-compose.yml" ]]; then
        error "Run this script from the monitoring-system directory."
        error "  cd monitoring-system && sudo bash install.sh"
        exit 1
    fi
 
    require_root
 
    DOCKER_INSTALLED=false
    MKCERT_INSTALLED=false
    COMPOSE_CMD="docker compose"
    TLS_MODE="ip"
    SERVER_NAME="127.0.0.1"
    DOMAIN=""
 
    step_check_deps
    step_install_docker
    step_install_mkcert
    step_setup_tls
    step_generate_credentials
    step_start_stack
}
 
main "$@"