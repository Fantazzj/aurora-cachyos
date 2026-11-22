#!/bin/bash

phase_kernel() {
# ---------------------------------------------------------------------------
# CachyOS kernel swap
# ---------------------------------------------------------------------------
# Ported from hurunagus-silverblue's BlueBuild custom-kernel module
# (modules/custom-kernel/custom-kernel.sh) -- the proven mechanic for swapping a
# kernel into an atomic image. Kept in dnf5 form and trimmed to what this image
# actually needs:
#
#   * Secure Boot signing is NOT done here: it is phase_sign below, one layer
#     further on, so that the signed artifact, its verification and the key's
#     provenance sit together (a build secret cannot be seen by the layer cache,
#     so signing must not share a layer with the kernel swap). This phase leaves
#     the kernel UNSIGNED on purpose.
#   * The NVIDIA/akmods half is NOT ported: this image targets Intel iGPUs and
#     installs no out-of-tree kernel modules. -devel-matched is still installed
#     so that stays possible later.
#   * An initramfs IS generated, and that part is not optional here: the base
#     image bakes /usr/lib/modules/$kver/initramfs.img and 50-dracut.install is
#     stubbed during the swap, so nothing else would produce one for the new
#     kernel -- a kernel without an initramfs cannot boot.
#
# Kernel source: bieszczaders/kernel-cachyos, the official CachyOS port to
# Fedora. It carries the CachyOS patch set (BORE CPU scheduler, 1000 Hz tick,
# PREEMPT_DYNAMIC, BFQ/Kyber, BBR, x86_64-v3). kernel-cachyos is the GCC build;
# kernel-cachyos-lto is its clang/ThinLTO twin with an otherwise identical
# config (vmlinuz ~3% smaller), so switching between them is the one-line
# KERNEL_FLAVOR below.
echo "::group:: Swapping in the CachyOS kernel"

KERNEL_FLAVOR="cachyos"

case "${KERNEL_FLAVOR}" in
    cachyos)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos
            kernel-cachyos-core
            kernel-cachyos-modules
            kernel-cachyos-devel-matched
        )
        ;;
    cachyos-lto)
        KERNEL_COPR="bieszczaders/kernel-cachyos-lto"
        KERNEL_PACKAGES=(
            kernel-cachyos-lto
            kernel-cachyos-lto-core
            kernel-cachyos-lto-modules
            kernel-cachyos-lto-devel-matched
        )
        ;;
    cachyos-lts)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos-lts
            kernel-cachyos-lts-core
            kernel-cachyos-lts-modules
            kernel-cachyos-lts-devel-matched
        )
        ;;
    cachyos-lts-lto)
        KERNEL_COPR="bieszczaders/kernel-cachyos-lto"
        KERNEL_PACKAGES=(
            kernel-cachyos-lts-lto
            kernel-cachyos-lts-lto-core
            kernel-cachyos-lts-lto-modules
            kernel-cachyos-lts-lto-devel-matched
        )
        ;;
    cachyos-rt)
        KERNEL_COPR="bieszczaders/kernel-cachyos"
        KERNEL_PACKAGES=(
            kernel-cachyos-rt
            kernel-cachyos-rt-core
            kernel-cachyos-rt-modules
            kernel-cachyos-rt-devel-matched
        )
        ;;
    *)
        echo "Unsupported KERNEL_FLAVOR: ${KERNEL_FLAVOR}" >&2
        exit 1
        ;;
esac

# The kernel's %posttrans guards `kernel-install add` behind
# `[ ! -e /run/ostree-booted ]`. Inside a container build that path does not
# exist, so the kernel-install hooks really do run: 05-rpmostree.install would
# try to drive rpm-ostree, and 50-dracut.install would build an initramfs with
# flags we do not control. Stub both for the duration of the swap, restore after.
KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)

disable_kernel_install_hooks() {
    local hook
    for hook in "${KERNEL_HOOKS[@]}"; do
        [[ -f "${hook}" ]] || continue
        mv "${hook}" "${hook}.bak"
        printf '%s\n' '#!/bin/sh' 'exit 0' >"${hook}"
        chmod +x "${hook}"
    done
}

restore_kernel_install_hooks() {
    local hook
    for hook in "${KERNEL_HOOKS[@]}"; do
        if [[ -f "${hook}.bak" ]]; then
            mv -f "${hook}.bak" "${hook}"
        fi
    done
}

disable_kernel_install_hooks

# Because kernel-install runs during the transaction below (see the note above),
# it writes boot artifacts into /boot: /boot/vmlinuz-*, config-*, System.map-*
# and symvers-*.zst (hardlinks to the module dir) plus a /boot/loader/ dir. The
# base image's /boot is deliberately empty and bootc manages /boot on the
# deployed host, so snapshot /boot here and delete only what appears. Snapshot
# rather than hardcoding paths, so a future base image that ships something in
# /boot is not clobbered.
KERNEL_BOOT_SNAPSHOT="$(mktemp)"
find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort >"${KERNEL_BOOT_SNAPSHOT}"

echo "Removing the stock Fedora kernel"
dnf5 remove -y \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true
rm -rf /usr/lib/modules/* || true

echo "Enabling ${KERNEL_COPR}"
dnf5 -y copr enable "${KERNEL_COPR}"

echo "Installing ${KERNEL_PACKAGES[*]}"
# Deliberately strict: with the stock kernel already removed, a failure here
# would leave the image with no kernel at all, so abort rather than ship one
# that cannot boot.
dnf5 install -y "${KERNEL_PACKAGES[@]}"

mapfile -t KERNEL_VERSIONS < <(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
if (( ${#KERNEL_VERSIONS[@]} != 1 )); then
    printf 'Expected exactly one kernel in /usr/lib/modules, found %d: %s\n' \
        "${#KERNEL_VERSIONS[@]}" "${KERNEL_VERSIONS[*]}" >&2
    exit 1
fi
KERNEL_VERSION="${KERNEL_VERSIONS[0]}"
echo "Kernel version: ${KERNEL_VERSION}"

restore_kernel_install_hooks

# Undo the /boot pollution described above, keeping only what was there before
# the swap. Without this the image ships stale /boot content and bootc's
# nonempty-boot lint flips from pass to warning (verified: 12 passed/2 warnings
# becomes 11 passed/3 warnings).
NEW_BOOT_ENTRIES=()
while IFS= read -r boot_entry; do
    [[ -n "${boot_entry}" ]] || continue
    NEW_BOOT_ENTRIES+=("${boot_entry}")
done < <(comm -13 "${KERNEL_BOOT_SNAPSHOT}" <(find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort))
rm -f "${KERNEL_BOOT_SNAPSHOT}"
if (( ${#NEW_BOOT_ENTRIES[@]} )); then
    echo "Removing ${#NEW_BOOT_ENTRIES[@]} /boot entries left by the kernel transaction: ${NEW_BOOT_ENTRIES[*]}"
    for boot_entry in "${NEW_BOOT_ENTRIES[@]}"; do
        rm -rf -- "/boot/${boot_entry}"
    done
fi

# Only the CachyOS repo is dropped. The omedora COPR is deliberately left
# enabled above -- omedora's helpers use it -- so never wildcard this pattern.
rm -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:bieszczaders:*.repo

echo "Generating the initramfs for ${KERNEL_VERSION}"
# Match how the base image's own initramfs is built: the image sets hostonly=no
# (20-atomic-nohostonly.conf) and adds the ostree+bootc dracut modules
# (20-atomic-bootc-ostree.conf), so those come from config; the explicit flags
# below are belt-and-braces.
DRACUT_NO_XATTR=1 dracut \
    --no-hostonly \
    --kver "${KERNEL_VERSION}" \
    --reproducible \
    --add ostree \
    -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"

# dracut writes this file outside any RPM transaction, so no scriptlet labels
# it. The base image's own initramfs is mode 0600; match it and relabel when
# policy is available in the build container.
chmod 0600 "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
if command -v restorecon >/dev/null 2>&1; then
    restorecon "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" 2>/dev/null || true
fi

# Assert the initramfs really exists and is plausibly sized. `set -e` already
# catches a non-zero dracut, but dracut can log a failure and still exit 0 (it
# prints "dracut-install: ERROR: installing '/root' to '/root'" on this image
# because /root is a symlink to var/roothome with no target in the build
# container -- harmless, and the stock initramfs omits /root too). A kernel with
# no usable initramfs cannot boot, so never let that through silently.
INITRAMFS_MIN_BYTES=$((100 * 1024 * 1024))
INITRAMFS_SIZE="$(stat -c %s "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" 2>/dev/null || echo 0)"
if (( INITRAMFS_SIZE < INITRAMFS_MIN_BYTES )); then
    printf 'initramfs for %s is missing or implausibly small (%s bytes, expected >%s); refusing to ship a likely-unbootable image\n' \
        "${KERNEL_VERSION}" "${INITRAMFS_SIZE}" "${INITRAMFS_MIN_BYTES}" >&2
    exit 1
fi
echo "initramfs verified: ${INITRAMFS_SIZE} bytes"

echo "CachyOS kernel ${KERNEL_VERSION} installed"
echo "::endgroup::"
}

echo "::group:: Cleaning up"
dnf5 clean all
rm -rf \
    /run/dnf \
    /run/selinux-policy \
    /run/tuned \
    /var/lib/dnf \
    /var/lib/fprint \
    /var/lib/rpm-state \
    /var/cache/libdnf5 \
    /var/log/dnf.log \
    /var/log/dnf.librepo.log \
    /var/log/dnf.rpm.log \
    /var/log/hawkey.log
echo "::endgroup::"

phase_kernel
