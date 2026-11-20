# Shared firmware-menu policy for the Debian installers. Source this file.

grub_has_firmware_entry() {
    awk '
        /^### BEGIN .*\/30_uefi-firmware ###$/ { stock = 1 }
        /^### END .*\/30_uefi-firmware ###$/ { stock = 0 }
        stock && /^[[:space:]]*menuentry[[:space:]]/ { found = 1 }
        END { exit !found }
    ' "$1"
}

grub_firmware_policy() (
    # Arguments: GRUB defaults file, active grub.cfg, stock generator path.
    defaults=$1 active=$2 generator=$3
    if [ ! -x "$generator" ]; then
        printf '%s\n' hide
        exit
    fi
    # grub-mkconfig reads these as shell code, in this order, without nounset.
    set +u
    if [ -f "$defaults" ]; then . "$defaults" >&2; fi
    for cfg in "$defaults.d"/*.cfg; do
        if [ -f "$cfg" ]; then . "$cfg" >&2; fi
    done
    case ${GRUB_DISABLE_UEFI_FIRMWARE-} in
        true) printf '%s\n' hide ;;
        false) printf '%s\n' enable ;;
        '')
            if grub_has_firmware_entry "$active"; then
                printf '%s\n' allow
            else
                printf '%s\n' hide
            fi ;;
        *) printf '%s\n' 'GRUB_DISABLE_UEFI_FIRMWARE must be true or false.' >&2; exit 1 ;;
    esac
)

grub_without_firmware_entry() {
    # Debian 2.12 ignores GRUB_DISABLE_UEFI_FIRMWARE. Drop only the stock
    # generator's firmware-only section; never edit a vendor script or custom entry.
    awk '
        /^### BEGIN .*\/30_uefi-firmware ###$/ { stock = 1; next }
        /^### END .*\/30_uefi-firmware ###$/ { stock = 0; next }
        !stock { print; next }
        {
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if (/^($|#|else$|fi$|}$)/ || /^if \[ .* \]; then$/ ||
                /^if fwsetup --is-supported; then$/ || /^fwsetup( --is-supported)?$/ ||
                /^menuentry .* [\047"]uefi-firmware[\047"] \{$/) next
            unexpected = 1
        }
        END { if (stock || unexpected) exit 1 }
    ' "$1"
}

grub_apply_firmware_policy() {
    # Arguments: policy, staged grub.cfg, scratch file on the same filesystem.
    [ "$1" = hide ] || return 0
    if ! grub_without_firmware_entry "$2" > "$3"; then
        printf '%s\n' 'The firmware generator emitted custom content; refusing to modify the GRUB menu.' >&2
        return 1
    fi
    # Keep the generated configuration's ownership and mode.
    cat -- "$3" > "$2"
}
