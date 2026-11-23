#!/bin/sh
set -eu

log() { printf '[cachyos-kernel] %s\n' "$*"; }
err() { printf '[cachyos-kernel] Error: %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "Run this script as root."
    exit 1
fi

COPR_REPO="bieszczaders/kernel-cachyos"
KERNEL_PKG="kernel-cachyos"
KERNEL_DEVEL_PKG="kernel-cachyos-devel-matched"
KERNEL_PACKAGES="kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel-cachyos-devel-matched"

restore_kernel_install_hooks() {
    for _f in \
        /usr/lib/kernel/install.d/05-rpmostree.install \
        /usr/lib/kernel/install.d/50-dracut.install
    do
        [ -f "${_f}.bak" ] && mv -f "${_f}.bak" "${_f}"
    done
}

cleanup() {
    restore_kernel_install_hooks
}

trap cleanup 0

log "Temporarily disabling kernel install hooks."
for _f in \
    /usr/lib/kernel/install.d/05-rpmostree.install \
    /usr/lib/kernel/install.d/50-dracut.install
do
    [ -f "${_f}" ] || continue
    if [ -e "${_f}.bak" ]; then
        err "Backup already exists: ${_f}.bak"
        exit 1
    fi
    mv "${_f}" "${_f}.bak"
    printf '#!/bin/sh\nexit 0\n' >"${_f}"
    chmod +x "${_f}"
done

log "Removing the default Fedora kernel packages."
dnf -y remove \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

log "Enabling COPR repository: ${COPR_REPO}"
dnf -y copr enable "${COPR_REPO}"

log "Installing CachyOS kernel packages (NVIDIA and Secure Boot signing are not configured)."
# Intentional word splitting: this is a fixed list of package names.
# shellcheck disable=SC2086
dnf -y install ${KERNEL_PACKAGES}

KERNEL_VERSION=$(rpm -q "${KERNEL_PKG}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)
if [ -z "${KERNEL_VERSION}" ]; then
    err "Could not determine the installed CachyOS kernel version."
    exit 1
fi
log "Installed kernel version: ${KERNEL_VERSION}"

restore_kernel_install_hooks
trap - 0

log "Removing kernel build headers after package installation."
dnf -y remove "${KERNEL_DEVEL_PKG}" || true

log "CachyOS kernel installation complete. NVIDIA and Secure Boot signing were not installed or configured."
