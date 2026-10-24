# shellcheck shell=bash disable=SC2034 # the variables are read by the scripts that source this file
# SPDX-License-Identifier: GPL-3.0-or-later

# Sets OVMF_CODE, OVMF_VARS_TEMPLATE and OVMF_FORMAT for builder-vm.sh and desktop-vm.sh:
# APEX_OVMF_CODE and APEX_OVMF_VARS when set, else the first pair this host has.
find_ovmf() {
    if [[ -n ${APEX_OVMF_CODE:-} || -n ${APEX_OVMF_VARS:-} ]]; then
        OVMF_CODE=${APEX_OVMF_CODE:-} OVMF_VARS_TEMPLATE=${APEX_OVMF_VARS:-} OVMF_FORMAT=${APEX_OVMF_FORMAT:-raw}
        [[ -r $OVMF_CODE && -r $OVMF_VARS_TEMPLATE ]] ||
            die "APEX_OVMF_CODE and APEX_OVMF_VARS must both name readable firmware files"
        return 0
    fi
    local root=${FIRMWARE_ROOT:-} pair code vars fmt
    for pair in \
        "/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd raw" \
        "/usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_VARS.fd raw" \
        "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd raw" \
        "/usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2 /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2 qcow2"; do
        read -r code vars fmt <<<"$pair"
        if [[ -r $root$code && -r $root$vars ]]; then
            OVMF_CODE=$root$code OVMF_VARS_TEMPLATE=$root$vars OVMF_FORMAT=$fmt
            return 0
        fi
    done
    die "no OVMF firmware found: install ovmf (Ubuntu) or edk2-ovmf (Fedora), or set APEX_OVMF_CODE and APEX_OVMF_VARS"
}

# A VM made on another host keeps that host's variable store, which this firmware may not read.
check_vars() {
    local vars=$1
    [[ $(stat -c %s -- "$vars") == "$(stat -c %s -- "$OVMF_VARS_TEMPLATE")" ]] ||
        die "$vars does not fit this host's firmware ($OVMF_VARS_TEMPLATE): copy that file over it; the VM boots from its fallback path"
}
