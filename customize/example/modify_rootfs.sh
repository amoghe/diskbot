#!/bin/bash

function log() {
  echo "[CHROOT] $*"
}

function add_admin_user() {
  useradd \
  --password '$1$ABCDEFGH$hGGndps75hhROKqu/zh9q1' \
  --shell /bin/bash \
  --create-home \
  --groups sudo \
  admin
}

function update_locales() {
  locale-gen en_US.UTF-8
  update-locale LANG=en_US.UTF-8 LC_MESSAGES=POSIX
}

function lvm_initramfs_hook() {
  LVM_INITRAMFS_HOOK=/usr/share/initramfs-tools/scripts/local-top/lvm2
  sed -i'.orig' \
    -e 's/lvchange_activate() {/vgchange --sysinit -aay\n\nlvchange_activate() {/' \
    $LVM_INITRAMFS_HOOK
  update-initramfs -u
}

function set_hostname() {
  echo "amnesiac" > /etc/hostname
}

#
# main
#

log "Setting up admin user"
add_admin_user

log "Setting up locale"
update_locales

log "Adding lvm2 hook for initramfs"
lvm_initramfs_hook

log "Changing hostname"
set_hostname
