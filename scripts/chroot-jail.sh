#!/bin/bash
# chroot-jail.sh — Create and enter a chroot jail for safeclaw.
#
# This script builds a minimal chroot filesystem under /jail using hardlinks
# (zero extra disk space on the same filesystem) from the container's installed
# packages, then chroots into the jail and exec's safeclaw as the non-root
# "safeclaw" user via su-exec.
#
# The entrypoint starts as root (required for mknod, mount, chroot) and drops
# to the safeclaw user before executing the application binary.
#
# Bypass:  NO_JAIL=1  or  --no-jail  flag to skip the jail for debugging.
#
# Copyright (c) 2026 Joseph R. Quinn
# Contact: quinn.josephr@protonmail.com

set -euo pipefail

JAIL="/jail"
RUN_USER="safeclaw"
RUN_GROUP="safeclaw"

# ── Bypass ───────────────────────────────────────────────────────────
NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
PYENV_ROOT="${PYENV_ROOT:-/usr/local/pyenv}"

# Resolve nvm node binary path
NVM_NODE_BIN=""
if [ -d "$NVM_DIR/versions/node" ]; then
    NVM_NODE_VER="$(ls "$NVM_DIR/versions/node/" 2>/dev/null | head -1)"
    [ -n "$NVM_NODE_VER" ] && NVM_NODE_BIN="$NVM_DIR/versions/node/$NVM_NODE_VER/bin"
fi
# Also check the 'default' symlink
[ -d "$NVM_DIR/versions/node/default/bin" ] && NVM_NODE_BIN="$NVM_DIR/versions/node/default/bin"

SA_PATH="${NVM_NODE_BIN:+$NVM_NODE_BIN:}$PYENV_ROOT/shims:$PYENV_ROOT/bin:/usr/local/bin:/usr/bin:/bin"

if [ "${NO_JAIL:-}" = "1" ] || [ "${1:-}" = "--no-jail" ]; then
    [ "${1:-}" = "--no-jail" ] && shift
    echo "[entrypoint] chroot jail bypassed (NO_JAIL=1)"
    chmod 1777 /tmp
    chown -R "$RUN_USER:$RUN_GROUP" /data/safeclaw /config/safeclaw /home/safeclaw 2>/dev/null || true
    export NVM_DIR PYENV_ROOT PATH="$SA_PATH"
    exec su-exec "$RUN_USER:$RUN_GROUP" /usr/local/bin/safeclaw "$@"
fi

echo "[entrypoint] building chroot jail at $JAIL"

# ── Hardlink system directories ──────────────────────────────────────
# cp -al creates directory trees with hardlinks to the original files.
# On the same overlay filesystem this uses zero additional disk space
# and completes in under a second for a typical Alpine install.

for dir in bin sbin lib usr; do
    src="/$dir"
    dst="$JAIL/$dir"
    if [ -d "$src" ] && [ ! -d "$dst" ]; then
        cp -al "$src" "$dst"
    fi
done

# ── Additional directories ───────────────────────────────────────────
mkdir -p "$JAIL"/{dev,etc,proc,sys,tmp,run,root}
mkdir -p "$JAIL/dev/pts"
mkdir -p "$JAIL/home/safeclaw"
mkdir -p "$JAIL/data/safeclaw/skills"
mkdir -p "$JAIL/config/safeclaw"
chmod 1777 "$JAIL/tmp"

# ── Minimal /dev ─────────────────────────────────────────────────────
# Only the device nodes that safeclaw and its child processes need.

create_dev() {
    local name="$1" type="$2" major="$3" minor="$4" mode="$5"
    [ -e "$JAIL/dev/$name" ] || mknod -m "$mode" "$JAIL/dev/$name" "$type" "$major" "$minor" 2>/dev/null || true
}

create_dev null    c 1 3 666
create_dev zero    c 1 5 666
create_dev full    c 1 7 666
create_dev random  c 1 8 444
create_dev urandom c 1 9 444
create_dev tty     c 5 0 666

# Standard fd symlinks (resolve via /proc once it's mounted)
ln -sf /proc/self/fd   "$JAIL/dev/fd"      2>/dev/null || true
ln -sf /proc/self/fd/0 "$JAIL/dev/stdin"   2>/dev/null || true
ln -sf /proc/self/fd/1 "$JAIL/dev/stdout"  2>/dev/null || true
ln -sf /proc/self/fd/2 "$JAIL/dev/stderr"  2>/dev/null || true

# ── Mount /proc ──────────────────────────────────────────────────────
# Docker's default seccomp profile allows mounting procfs.
if ! mountpoint -q "$JAIL/proc" 2>/dev/null; then
    mount -t proc proc "$JAIL/proc" 2>/dev/null || true
fi

# ── Minimal /etc ─────────────────────────────────────────────────────
# Copy only the files safeclaw and its child processes need.
# Network resolution, user database, TLS trust store.

for f in resolv.conf hosts hostname passwd group shadow nsswitch.conf localtime; do
    [ -f "/etc/$f" ] && cp -f "/etc/$f" "$JAIL/etc/$f" 2>/dev/null || true
done

# TLS CA certificates
[ -d /etc/ssl ] && cp -a /etc/ssl "$JAIL/etc/" 2>/dev/null || true

# Alpine package keys (some tools check these)
[ -d /etc/apk ] && cp -a /etc/apk "$JAIL/etc/" 2>/dev/null || true

# ── Bind-mount data & config volumes into the jail ───────────────────
# The Docker volumes are mounted at /data and /config on the host
# container filesystem. We bind-mount them into the jail so the agent
# sees them at the same canonical paths.
#
# If bind-mount is not available (no SYS_ADMIN), fall back to the
# jail-internal directories that Docker can mount directly.

bind_volume() {
    local src="$1" dst="$2"
    if [ -d "$src" ] && [ -d "$dst" ]; then
        # Skip if the source and destination are the same (volumes
        # already mounted directly into the jail path)
        if [ "$(stat -c %d:%i "$src" 2>/dev/null)" = "$(stat -c %d:%i "$dst" 2>/dev/null)" ]; then
            return 0
        fi
        # Use --rbind so that Docker file-level submounts (e.g.
        # config.toml mounted into a directory) propagate correctly.
        mount --rbind "$src" "$dst" 2>/dev/null && return 0
        # Fallback: copy contents (for when bind mount is not permitted)
        cp -a "$src/." "$dst/" 2>/dev/null || true
    fi
}

bind_volume /data/safeclaw  "$JAIL/data/safeclaw"
bind_volume /config/safeclaw "$JAIL/config/safeclaw"

# Bind-mount the Claude CLI config directory into the jail so that
# token refreshes performed inside the jail persist back to the host
# volume.  Symlink ~/.claude for convenience so Claude CLI and skills
# find credentials at the expected HOME-relative path.
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-/claude-config}"
if [ -d "$CLAUDE_CFG" ]; then
    mkdir -p "$JAIL/$CLAUDE_CFG"
    bind_volume "$CLAUDE_CFG" "$JAIL/$CLAUDE_CFG"
    mkdir -p "$JAIL/home/safeclaw"
    ln -sfn "$CLAUDE_CFG" "$JAIL/home/safeclaw/.claude"
fi

# ── Fix ownership for the non-root user ──────────────────────────────
# Data, config, home, and tmp must be writable by safeclaw.
# System directories (bin, lib, usr, etc) stay owned by root (read-only).
chown -R "$RUN_USER:$RUN_GROUP" \
    "$JAIL/data/safeclaw" \
    "$JAIL/config/safeclaw" \
    "$JAIL/home/safeclaw" \
    2>/dev/null || true

# ── Enter the jail as non-root ───────────────────────────────────────
echo "[entrypoint] chroot jail ready — entering as $RUN_USER"
export NVM_DIR PYENV_ROOT PATH="$SA_PATH"
exec /usr/sbin/chroot "$JAIL" /sbin/su-exec "$RUN_USER:$RUN_GROUP" /usr/local/bin/safeclaw "$@"
