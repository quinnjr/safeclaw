#!/bin/bash
# chroot-install.sh — Install and manage a chroot jail for safeclaw on
# bare-metal Debian/Ubuntu, Fedora/RHEL/CentOS, or Arch Linux systems.
#
# Usage:
#   chroot-install.sh setup   [-b /path/to/safeclaw]  Install deps, build chroot
#   chroot-install.sh start   [-- safeclaw-args...]    Mount & run inside chroot
#   chroot-install.sh stop                               Kill agent & unmount
#   chroot-install.sh shell                              Open a bash shell in the jail
#   chroot-install.sh status                             Show mount and process status
#   chroot-install.sh teardown                           Remove chroot entirely
#
# Environment overrides:
#   JAIL_ROOT      Chroot base directory       (default: /opt/safeclaw)
#   SA_BINARY      Path to safeclaw binary   (default: ./target/release/safeclaw)
#   SA_USER        Runtime user                (default: safeclaw)
#   SA_GROUP       Runtime group               (default: safeclaw)
#
# Copyright (c) 2026 Joseph R. Quinn
# Contact: quinn.josephr@protonmail.com

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────

JAIL="${JAIL_ROOT:-/opt/safeclaw}"
SA_USER="${SA_USER:-safeclaw}"
SA_GROUP="${SA_GROUP:-safeclaw}"
SA_BINARY="${SA_BINARY:-./target/release/safeclaw}"
SYSTEMD_UNIT="safeclaw.service"
PID_FILE="$JAIL/run/safeclaw.pid"

# ── Helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This command must be run as root (use sudo)."
        exit 1
    fi
}

# ── Distro detection ────────────────────────────────────────────────

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu|linuxmint|pop|raspbian)
                DISTRO_FAMILY="debian" ;;
            fedora|rhel|centos|rocky|alma|ol|amzn)
                DISTRO_FAMILY="rpm" ;;
            arch|manjaro|endeavouros|garuda|artix)
                DISTRO_FAMILY="arch" ;;
            *)
                # Try ID_LIKE as fallback
                case "${ID_LIKE:-}" in
                    *debian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
                    *rhel*|*fedora*)   DISTRO_FAMILY="rpm" ;;
                    *arch*)            DISTRO_FAMILY="arch" ;;
                    *)
                        err "Unsupported distribution: $ID ($PRETTY_NAME)"
                        err "Supported families: Debian/Ubuntu, Fedora/RHEL, Arch Linux"
                        exit 1 ;;
                esac ;;
        esac
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
    else
        err "Cannot detect distribution (/etc/os-release not found)."
        exit 1
    fi
}

# ── nvm / pyenv directories ──────────────────────────────────────────

NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
PYENV_ROOT="${PYENV_ROOT:-/usr/local/pyenv}"
NODE_VERSION="--lts"
PYTHON_VERSION="3.12"

# Source nvm into the current shell (idempotent).
load_nvm() {
    export NVM_DIR
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
}

# Source pyenv into the current shell (idempotent).
load_pyenv() {
    export PYENV_ROOT
    export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
    command -v pyenv &>/dev/null && eval "$(pyenv init -)"
}

# ── Package installation ────────────────────────────────────────────

install_base_packages_debian() {
    log "Installing base packages via apt (Debian/Ubuntu)..."
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl git bash \
        make gcc zlib1g-dev libbz2-dev libreadline-dev libssl-dev \
        libsqlite3-dev libffi-dev liblzma-dev xz-utils
}

install_base_packages_rpm() {
    log "Installing base packages via dnf/yum (RPM)..."
    local PKG_MGR="dnf"
    command -v dnf &>/dev/null || PKG_MGR="yum"
    $PKG_MGR install -y \
        ca-certificates curl git bash \
        make gcc zlib-devel bzip2-devel readline-devel openssl-devel \
        sqlite-devel libffi-devel xz-devel
}

install_base_packages_arch() {
    log "Installing base packages via pacman (Arch)..."
    pacman -Sy --noconfirm --needed \
        ca-certificates curl git bash \
        base-devel openssl zlib bzip2 readline sqlite libffi xz
}

install_nvm() {
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        info "nvm already installed at $NVM_DIR"
    else
        log "Installing nvm..."
        mkdir -p "$NVM_DIR"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | \
            NVM_DIR="$NVM_DIR" bash
    fi
    load_nvm

    if nvm ls "$NODE_VERSION" &>/dev/null; then
        info "Node.js LTS already installed via nvm."
    else
        log "Installing Node.js LTS via nvm..."
        nvm install "$NODE_VERSION"
    fi
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    log "Node.js $(node --version) active via nvm."
}

install_pyenv() {
    if [ -d "$PYENV_ROOT/bin" ]; then
        info "pyenv already installed at $PYENV_ROOT"
    else
        log "Installing pyenv..."
        curl -fsSL https://pyenv.run | PYENV_ROOT="$PYENV_ROOT" bash
    fi
    load_pyenv

    if pyenv versions --bare | grep -q "^${PYTHON_VERSION}"; then
        info "Python $PYTHON_VERSION already installed via pyenv."
    else
        log "Installing Python $PYTHON_VERSION via pyenv..."
        pyenv install "$PYTHON_VERSION"
    fi
    pyenv global "$PYTHON_VERSION"
    log "Python $(python3 --version) active via pyenv."
}

install_host_packages() {
    detect_distro
    info "Detected: $DISTRO_NAME (family: $DISTRO_FAMILY)"

    # Base packages (build deps for pyenv, plus git/curl/bash)
    case "$DISTRO_FAMILY" in
        debian) install_base_packages_debian ;;
        rpm)    install_base_packages_rpm ;;
        arch)   install_base_packages_arch ;;
    esac

    # nvm + Node.js LTS
    install_nvm

    # pyenv + Python
    install_pyenv

    # Claude Code CLI (uses nvm-managed npm)
    load_nvm
    if ! command -v claude &>/dev/null; then
        log "Installing Claude Code CLI..."
        npm install -g @anthropic-ai/claude-code
    else
        info "Claude Code CLI already installed."
    fi

    # ngrok
    if ! command -v ngrok &>/dev/null; then
        log "Installing ngrok..."
        local ARCH
        ARCH="$(uname -m)"
        local NGROK_ARCH="amd64"
        [ "$ARCH" = "aarch64" ] && NGROK_ARCH="arm64"
        curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz" \
            -o /tmp/ngrok.tgz
        tar -xzf /tmp/ngrok.tgz -C /usr/local/bin
        rm -f /tmp/ngrok.tgz
        chmod +x /usr/local/bin/ngrok
    else
        info "ngrok already installed."
    fi

    # Python packages used by skills (uses pyenv-managed pip)
    load_pyenv
    log "Installing Python packages for skills..."
    pip install --quiet \
        requests \
        google-api-python-client \
        google-auth-httplib2 \
        google-auth-oauthlib \
        python-dotenv \
        schedule \
        httpx \
        beautifulsoup4 \
        feedparser \
        icalendar
}

# ── User creation ────────────────────────────────────────────────────

create_user() {
    if id "$SA_USER" &>/dev/null; then
        info "User '$SA_USER' already exists."
        return
    fi

    log "Creating system user '$SA_USER'..."
    case "$DISTRO_FAMILY" in
        debian)
            addgroup --system "$SA_GROUP"
            adduser --system --ingroup "$SA_GROUP" --home "/home/$SA_USER" \
                    --shell /bin/bash --disabled-password "$SA_USER"
            ;;
        rpm)
            groupadd --system "$SA_GROUP"
            useradd --system --gid "$SA_GROUP" --home-dir "/home/$SA_USER" \
                    --create-home --shell /bin/bash "$SA_USER"
            ;;
        arch)
            groupadd --system "$SA_GROUP" 2>/dev/null || true
            useradd --system --gid "$SA_GROUP" --home-dir "/home/$SA_USER" \
                    --create-home --shell /bin/bash "$SA_USER"
            ;;
    esac
}

# ── Build the chroot ─────────────────────────────────────────────────

build_chroot() {
    local binary="$1"

    if [ ! -f "$binary" ]; then
        err "safeclaw binary not found at: $binary"
        err "Build it first (cargo build --release) or set SA_BINARY."
        exit 1
    fi

    log "Building chroot jail at $JAIL"

    # Directory structure
    mkdir -p "$JAIL"/{dev,etc,proc,sys,tmp,run,var/tmp}
    mkdir -p "$JAIL/dev/pts"
    mkdir -p "$JAIL/home/$SA_USER/.config/safeclaw"
    mkdir -p "$JAIL/home/$SA_USER/.local/share/safeclaw/skills"
    mkdir -p "$JAIL/usr/local/bin"
    chmod 1777 "$JAIL/tmp"

    # ── Read-only bind mounts (done at start time) ───────────────────
    # We prepare the mount-point directories now; actual mounts happen
    # in the 'start' command so they survive reboots cleanly.
    for dir in bin sbin lib usr; do
        [ -d "/$dir" ] && mkdir -p "$JAIL/$dir"
    done
    # lib64 exists on most x86_64 glibc systems
    [ -d /lib64 ] && mkdir -p "$JAIL/lib64"

    # ── Copy safeclaw binary ───────────────────────────────────────
    install -m 0755 "$binary" "$JAIL/usr/local/bin/safeclaw"
    log "Installed safeclaw binary into jail"

    # ── Minimal /dev ─────────────────────────────────────────────────
    create_dev_node() {
        local name="$1" type="$2" major="$3" minor="$4" mode="$5"
        [ -e "$JAIL/dev/$name" ] || mknod -m "$mode" "$JAIL/dev/$name" "$type" "$major" "$minor"
    }

    create_dev_node null    c 1 3 666
    create_dev_node zero    c 1 5 666
    create_dev_node full    c 1 7 666
    create_dev_node random  c 1 8 444
    create_dev_node urandom c 1 9 444
    create_dev_node tty     c 5 0 666

    ln -sf /proc/self/fd   "$JAIL/dev/fd"     2>/dev/null || true
    ln -sf /proc/self/fd/0 "$JAIL/dev/stdin"  2>/dev/null || true
    ln -sf /proc/self/fd/1 "$JAIL/dev/stdout" 2>/dev/null || true
    ln -sf /proc/self/fd/2 "$JAIL/dev/stderr" 2>/dev/null || true

    # ── Minimal /etc ─────────────────────────────────────────────────
    sync_etc

    # ── Ownership ────────────────────────────────────────────────────
    chown -R "$SA_USER:$SA_GROUP" \
        "$JAIL/home/$SA_USER" \
        "$JAIL/tmp" \
        "$JAIL/run"

    log "Chroot jail built successfully at $JAIL"
}

# Copy dynamic /etc files into the jail (called at setup and start).
sync_etc() {
    for f in resolv.conf hosts hostname passwd group nsswitch.conf localtime; do
        [ -f "/etc/$f" ] && cp -f "/etc/$f" "$JAIL/etc/$f" 2>/dev/null || true
    done

    # TLS trust store
    for d in ssl pki ca-certificates; do
        if [ -d "/etc/$d" ]; then
            rm -rf "$JAIL/etc/$d"
            cp -a "/etc/$d" "$JAIL/etc/$d"
        fi
    done

    # ld.so.cache for glibc systems (Debian/RPM) — needed by dynamic binaries
    [ -f /etc/ld.so.cache ] && cp -f /etc/ld.so.cache "$JAIL/etc/" 2>/dev/null || true
}

# ── Mount / unmount ──────────────────────────────────────────────────

BIND_DIRS="bin sbin lib usr"

mount_jail() {
    log "Mounting filesystems into jail..."

    # Read-only bind mounts of system directories
    for dir in $BIND_DIRS; do
        src="/$dir"
        dst="$JAIL/$dir"
        [ -d "$src" ] || continue
        [ -d "$dst" ] || mkdir -p "$dst"
        if mountpoint -q "$dst" 2>/dev/null; then
            continue
        fi
        mount --bind "$src" "$dst"
        mount -o remount,bind,ro "$dst"
    done

    # lib64 (x86_64 glibc)
    if [ -d /lib64 ] && [ -d "$JAIL/lib64" ]; then
        if ! mountpoint -q "$JAIL/lib64" 2>/dev/null; then
            mount --bind /lib64 "$JAIL/lib64"
            mount -o remount,bind,ro "$JAIL/lib64"
        fi
    fi

    # /proc
    if ! mountpoint -q "$JAIL/proc" 2>/dev/null; then
        mount -t proc proc "$JAIL/proc"
    fi

    # /sys (read-only)
    if ! mountpoint -q "$JAIL/sys" 2>/dev/null; then
        mount --bind /sys "$JAIL/sys"
        mount -o remount,bind,ro "$JAIL/sys" 2>/dev/null || true
    fi

    # /dev/pts for pseudo-terminals
    if ! mountpoint -q "$JAIL/dev/pts" 2>/dev/null; then
        mount -t devpts devpts "$JAIL/dev/pts" 2>/dev/null || true
    fi

    # tmpfs for /tmp
    if ! mountpoint -q "$JAIL/tmp" 2>/dev/null; then
        mount -t tmpfs -o size=512m,noexec,nosuid,mode=1777 tmpfs "$JAIL/tmp"
    fi

    # Refresh DNS and cert files
    sync_etc

    log "All jail mounts active."
}

umount_jail() {
    log "Unmounting jail filesystems..."

    # Unmount in reverse order; ignore errors for things that aren't mounted.
    for mp in \
        "$JAIL/tmp" \
        "$JAIL/dev/pts" \
        "$JAIL/sys" \
        "$JAIL/proc" \
        "$JAIL/lib64" \
        "$JAIL/usr" \
        "$JAIL/lib" \
        "$JAIL/sbin" \
        "$JAIL/bin"; do
        [ -d "$mp" ] && mountpoint -q "$mp" 2>/dev/null && umount -l "$mp" 2>/dev/null || true
    done

    log "Jail filesystems unmounted."
}

# ── Systemd service ─────────────────────────────────────────────────

install_systemd_unit() {
    local unit_path="/etc/systemd/system/$SYSTEMD_UNIT"
    local script_path
    script_path="$(realpath "$0")"

    log "Installing systemd unit: $SYSTEMD_UNIT"

    cat > "$unit_path" <<UNIT
[Unit]
Description=safeclaw AI assistant (chroot)
Documentation=https://github.com/quinnjr/safeclaw
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

ExecStartPre=$script_path mount-only
ExecStart=/usr/sbin/chroot --userspec=$SA_USER:$SA_GROUP $JAIL /usr/local/bin/safeclaw
ExecStopPost=$script_path umount-only

Environment=XDG_DATA_HOME=/home/$SA_USER/.local/share
Environment=XDG_CONFIG_HOME=/home/$SA_USER/.config
Environment=HOME=/home/$SA_USER
Environment=NVM_DIR=$NVM_DIR
Environment=PYENV_ROOT=$PYENV_ROOT

Restart=on-failure
RestartSec=10
TimeoutStopSec=30

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=false
ReadOnlyPaths=/
ReadWritePaths=$JAIL/home/$SA_USER $JAIL/tmp $JAIL/run

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    log "Systemd unit installed."
    info "Enable with:  systemctl enable $SYSTEMD_UNIT"
    info "Start with:   systemctl start $SYSTEMD_UNIT"
    info "Logs with:    journalctl -u $SYSTEMD_UNIT -f"
}

# ── Commands ─────────────────────────────────────────────────────────

cmd_setup() {
    require_root

    local binary="$SA_BINARY"

    # Parse flags
    while [ $# -gt 0 ]; do
        case "$1" in
            -b|--binary) binary="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done

    detect_distro
    install_host_packages
    create_user
    build_chroot "$binary"
    install_systemd_unit

    echo ""
    log "Setup complete!"
    echo ""
    info "Jail root:     $JAIL"
    info "Runtime user:  $SA_USER"
    info "Data dir:      $JAIL/home/$SA_USER/.local/share/safeclaw/"
    info "Config dir:    $JAIL/home/$SA_USER/.config/safeclaw/"
    echo ""
    info "Next steps:"
    info "  1. Copy your config.toml into: $JAIL/home/$SA_USER/.config/safeclaw/"
    info "  2. Set environment variables in /etc/systemd/system/$SYSTEMD_UNIT"
    info "     (DASHBOARD_PASSWORD, JWT_SECRET, TELEGRAM_BOT_TOKEN, etc.)"
    info "  3. systemctl enable --now $SYSTEMD_UNIT"
    info ""
    info "Or run manually: $0 start"
}

cmd_start() {
    require_root

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        err "safeclaw is already running (PID $(cat "$PID_FILE"))."
        exit 1
    fi

    mount_jail

    # Refresh /etc files
    sync_etc

    # Resolve nvm/pyenv node and python paths for the chroot
    load_nvm 2>/dev/null || true
    load_pyenv 2>/dev/null || true
    local nvm_bin=""
    [ -d "$NVM_DIR" ] && nvm_bin="$NVM_DIR/versions/node/$(ls "$NVM_DIR/versions/node/" 2>/dev/null | tail -1)/bin"
    local pyenv_bin="$PYENV_ROOT/shims:$PYENV_ROOT/bin"

    log "Starting safeclaw as $SA_USER in chroot..."
    exec chroot --userspec="$SA_USER:$SA_GROUP" "$JAIL" \
        /usr/bin/env \
        HOME="/home/$SA_USER" \
        XDG_DATA_HOME="/home/$SA_USER/.local/share" \
        XDG_CONFIG_HOME="/home/$SA_USER/.config" \
        NVM_DIR="$NVM_DIR" \
        PYENV_ROOT="$PYENV_ROOT" \
        PATH="${nvm_bin}:${pyenv_bin}:/usr/local/bin:/usr/bin:/bin" \
        /usr/local/bin/safeclaw "$@"
}

cmd_stop() {
    require_root

    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping safeclaw (PID $pid)..."
            kill "$pid"
            # Wait up to 15 seconds
            local i=0
            while kill -0 "$pid" 2>/dev/null && [ $i -lt 15 ]; do
                sleep 1
                i=$((i + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                warn "Forcefully killing PID $pid"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    else
        warn "No PID file found. Checking for running processes..."
        pkill -f "$JAIL/usr/local/bin/safeclaw" 2>/dev/null || true
    fi

    umount_jail
    log "Stopped."
}

cmd_shell() {
    require_root
    mount_jail

    load_nvm 2>/dev/null || true
    load_pyenv 2>/dev/null || true
    local nvm_bin=""
    [ -d "$NVM_DIR" ] && nvm_bin="$NVM_DIR/versions/node/$(ls "$NVM_DIR/versions/node/" 2>/dev/null | tail -1)/bin"
    local pyenv_bin="$PYENV_ROOT/shims:$PYENV_ROOT/bin"

    info "Entering jail as $SA_USER (type 'exit' to leave)..."
    chroot --userspec="$SA_USER:$SA_GROUP" "$JAIL" \
        /usr/bin/env \
        HOME="/home/$SA_USER" \
        XDG_DATA_HOME="/home/$SA_USER/.local/share" \
        XDG_CONFIG_HOME="/home/$SA_USER/.config" \
        NVM_DIR="$NVM_DIR" \
        PYENV_ROOT="$PYENV_ROOT" \
        PATH="${nvm_bin}:${pyenv_bin}:/usr/local/bin:/usr/bin:/bin" \
        TERM="${TERM:-xterm}" \
        /bin/bash -l || true

    info "Left jail shell."
}

cmd_status() {
    echo -e "${CYAN}── Chroot jail status ──${NC}"
    echo ""

    if [ ! -d "$JAIL" ]; then
        warn "Jail directory does not exist: $JAIL"
        warn "Run '$0 setup' first."
        return
    fi

    info "Jail root: $JAIL"

    # Mount status
    echo ""
    echo -e "${CYAN}Mounts:${NC}"
    local any_mounted=false
    for dir in bin sbin lib lib64 usr proc sys dev/pts tmp; do
        local mp="$JAIL/$dir"
        if [ -d "$mp" ] && mountpoint -q "$mp" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} /$dir  →  $mp"
            any_mounted=true
        elif [ -d "$mp" ]; then
            echo -e "  ${RED}○${NC} /$dir  (not mounted)"
        fi
    done
    if [ "$any_mounted" = "false" ]; then
        warn "No filesystems mounted. Run '$0 start' or '$0 mount-only'."
    fi

    # Process status
    echo ""
    echo -e "${CYAN}Process:${NC}"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} safeclaw running (PID $(cat "$PID_FILE"))"
    elif pgrep -f "$JAIL/usr/local/bin/safeclaw" &>/dev/null; then
        echo -e "  ${GREEN}●${NC} safeclaw running (PID $(pgrep -f "$JAIL/usr/local/bin/safeclaw"))"
    else
        echo -e "  ${RED}○${NC} safeclaw not running"
    fi

    # Disk usage
    echo ""
    echo -e "${CYAN}Disk (jail-owned data only):${NC}"
    if [ -d "$JAIL/home/$SA_USER" ]; then
        echo -e "  home:   $(du -sh "$JAIL/home/$SA_USER" 2>/dev/null | cut -f1)"
    fi
    echo ""
}

cmd_teardown() {
    require_root

    warn "This will REMOVE the entire chroot jail at $JAIL"
    warn "and uninstall the systemd unit."
    echo -n "Are you sure? [y/N] "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Cancelled."
        exit 0
    fi

    # Stop any running instance
    cmd_stop 2>/dev/null || true

    # Remove systemd unit
    if [ -f "/etc/systemd/system/$SYSTEMD_UNIT" ]; then
        systemctl disable "$SYSTEMD_UNIT" 2>/dev/null || true
        rm -f "/etc/systemd/system/$SYSTEMD_UNIT"
        systemctl daemon-reload
        log "Removed systemd unit."
    fi

    # Remove chroot (but not bind mount sources, obviously)
    if [ -d "$JAIL" ]; then
        # Make sure nothing is mounted
        umount_jail 2>/dev/null || true
        rm -rf "$JAIL"
        log "Removed $JAIL"
    fi

    log "Teardown complete."
    info "The '$SA_USER' system user was NOT removed. Remove manually with: userdel -r $SA_USER"
}

# ── Internal commands (used by systemd) ──────────────────────────────

cmd_mount_only() {
    require_root
    mount_jail
}

cmd_umount_only() {
    require_root
    umount_jail
}

# ── Main ─────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
safeclaw chroot jail installer

Usage: $(basename "$0") <command> [options]

Commands:
  setup    [-b binary]   Install dependencies, create user, build chroot, install systemd unit
  start    [-- args...]  Mount jail filesystems and run safeclaw inside the chroot
  stop                   Stop safeclaw and unmount jail filesystems
  shell                  Open an interactive bash shell inside the jail
  status                 Show jail mount and process status
  teardown               Remove the chroot jail and systemd unit entirely

Options:
  -b, --binary PATH      Path to the safeclaw binary (default: ./target/release/safeclaw)

Environment:
  JAIL_ROOT    Chroot base directory  (default: /opt/safeclaw)
  SA_BINARY    Binary path            (default: ./target/release/safeclaw)
  SA_USER      Runtime user           (default: safeclaw)
  SA_GROUP     Runtime group          (default: safeclaw)

Examples:
  sudo ./scripts/chroot-install.sh setup
  sudo ./scripts/chroot-install.sh setup -b /usr/local/bin/safeclaw
  sudo ./scripts/chroot-install.sh start
  sudo ./scripts/chroot-install.sh shell
  sudo ./scripts/chroot-install.sh status
  sudo ./scripts/chroot-install.sh stop
  sudo ./scripts/chroot-install.sh teardown
EOF
}

case "${1:-}" in
    setup)      shift; cmd_setup "$@" ;;
    start)      shift; cmd_start "$@" ;;
    stop)       cmd_stop ;;
    shell)      cmd_shell ;;
    status)     cmd_status ;;
    teardown)   cmd_teardown ;;
    mount-only) cmd_mount_only ;;
    umount-only) cmd_umount_only ;;
    -h|--help|help) usage ;;
    "")         usage; exit 1 ;;
    *)          err "Unknown command: $1"; usage; exit 1 ;;
esac
