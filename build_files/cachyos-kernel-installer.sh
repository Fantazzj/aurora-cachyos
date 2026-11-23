#!/usr/bin/env bash
set -euo pipefail

# Sostituisce il kernel Fedora con quello CachyOS nell'immagine Aurora/bootc.
# Da eseguire durante la build dell'immagine, come root.
#
# Nota Secure Boot: questo script NON firma vmlinuz. Per avviare con Secure
# Boot attivo occorre aggiungere una fase di firma e registrare la chiave MOK;
# altrimenti disattivare Secure Boot nel firmware.

KERNEL_COPR="bieszczaders/kernel-cachyos"
KERNEL_PACKAGES=(
    kernel-cachyos
    kernel-cachyos-core
    kernel-cachyos-modules
    kernel-cachyos-devel-matched
)

KERNEL_HOOKS=(
    /usr/lib/kernel/install.d/05-rpmostree.install
    /usr/lib/kernel/install.d/50-dracut.install
)
KERNEL_BOOT_SNAPSHOT=""
HOOKS_DISABLED=0

restore_kernel_install_hooks() {
    local hook
    for hook in "${KERNEL_HOOKS[@]}"; do
        if [[ -f "${hook}.bak" ]]; then
            mv -f "${hook}.bak" "${hook}"
        fi
    done
    HOOKS_DISABLED=0
}

cleanup() {
    restore_kernel_install_hooks
    if [[ -n "${KERNEL_BOOT_SNAPSHOT}" ]]; then
        rm -f "${KERNEL_BOOT_SNAPSHOT}"
    fi
}
trap cleanup EXIT

disable_kernel_install_hooks() {
    local hook

    for hook in "${KERNEL_HOOKS[@]}"; do
        [[ -f "${hook}" ]] || continue

        if [[ -e "${hook}.bak" ]]; then
            echo "Errore: esiste già il backup ${hook}.bak" >&2
            return 1
        fi

        mv "${hook}" "${hook}.bak"
        printf '%s\n' '#!/bin/sh' 'exit 0' > "${hook}"
        chmod 0755 "${hook}"
    done

    HOOKS_DISABLED=1
}

echo "::group::Installazione degli strumenti DNF"
dnf5 install -y dnf5-plugins
echo "::endgroup::"

echo "::group::Sostituzione del kernel con CachyOS"

disable_kernel_install_hooks

# Durante la transazione kernel-install potrebbe scrivere file in /boot.
# Conserviamo ciò che era presente per rimuovere soltanto i nuovi elementi.
KERNEL_BOOT_SNAPSHOT="$(mktemp)"
find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort \
    > "${KERNEL_BOOT_SNAPSHOT}"

echo "Rimozione dei pacchetti kernel Fedora"
dnf5 remove -y \
    kernel \
    kernel-core \
    kernel-modules \
    kernel-modules-core \
    kernel-modules-extra \
    kernel-devel \
    kernel-devel-matched || true

# L'immagine usa il kernel CachyOS al posto dei moduli del kernel base.
rm -rf /usr/lib/modules/*

echo "Abilitazione del COPR ${KERNEL_COPR}"
dnf5 -y copr enable "${KERNEL_COPR}"

echo "Installazione: ${KERNEL_PACKAGES[*]}"
dnf5 install -y "${KERNEL_PACKAGES[@]}"

mapfile -t KERNEL_VERSIONS < <(
    find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
)

if (( ${#KERNEL_VERSIONS[@]} != 1 )); then
    printf 'Atteso un solo kernel in /usr/lib/modules; trovati %d: %s\n' \
        "${#KERNEL_VERSIONS[@]}" "${KERNEL_VERSIONS[*]}" >&2
    exit 1
fi

KERNEL_VERSION="${KERNEL_VERSIONS[0]}"
echo "Kernel installato: ${KERNEL_VERSION}"

restore_kernel_install_hooks

NEW_BOOT_ENTRIES=()
while IFS= read -r entry; do
    [[ -n "${entry}" ]] && NEW_BOOT_ENTRIES+=("${entry}")
done < <(
    comm -13 \
        "${KERNEL_BOOT_SNAPSHOT}" \
        <(find /boot -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
)

if (( ${#NEW_BOOT_ENTRIES[@]} )); then
    echo "Pulizia degli elementi creati in /boot: ${NEW_BOOT_ENTRIES[*]}"
    for entry in "${NEW_BOOT_ENTRIES[@]}"; do
        rm -rf -- "/boot/${entry}"
    done
fi

rm -f "${KERNEL_BOOT_SNAPSHOT}"
KERNEL_BOOT_SNAPSHOT=""

# Il kernel di un'immagine bootc deve avere l'initramfs nella directory
# dei moduli. Gli hook sono stati disattivati durante la transazione, quindi
# lo generiamo esplicitamente con la configurazione dracut dell'immagine.
INITRAMFS="/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"

echo "Generazione dell'initramfs: ${INITRAMFS}"
DRACUT_NO_XATTR=1 dracut \
    --no-hostonly \
    --kver "${KERNEL_VERSION}" \
    --reproducible \
    --add ostree \
    --force "${INITRAMFS}"

if [[ ! -s "${INITRAMFS}" ]]; then
    echo "Errore: initramfs mancante o vuoto: ${INITRAMFS}" >&2
    exit 1
fi

chmod 0600 "${INITRAMFS}"
if command -v restorecon >/dev/null 2>&1; then
    restorecon "${INITRAMFS}" 2>/dev/null || true
fi

# Il COPR serve solo durante la build: i pacchetti installati restano
# nell'immagine, ma la repo non viene lasciata abilitata sul sistema.
rm -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:bieszczaders:*.repo

echo "Kernel CachyOS ${KERNEL_VERSION} e initramfs installati"
echo "::endgroup::"
