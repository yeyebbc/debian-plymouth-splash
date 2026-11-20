#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/grub-firmware.sh"
unset GRUB_DISABLE_UEFI_FIRMWARE
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/grub.d"

cat > "$work/plain.cfg" <<'GRUB'
set timeout_style=menu
set timeout=5
menuentry 'Debian' --id 'gnulinux-simple-root' {
    linux /vmlinuz root=UUID=root ro quiet splash
    initrd /initrd.img
}
menuentry 'Windows Boot Manager' --id 'osprober-efi-A39D-1724' {
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
### BEGIN /etc/grub.d/40_custom ###
menuentry 'My firmware shortcut' --id 'my-firmware' {
    fwsetup
}
### END /etc/grub.d/40_custom ###
GRUB
cp "$work/plain.cfg" "$work/with-firmware.cfg"
cat >> "$work/with-firmware.cfg" <<'GRUB'
### BEGIN /etc/grub.d/30_uefi-firmware ###
if [ "$grub_platform" = "efi" ]; then
    fwsetup --is-supported
    if [ "$?" = 0 ]; then
        menuentry 'Paramètres du micrologiciel' $menuentry_id_option 'uefi-firmware' {
            fwsetup
        }
    fi
fi
### END /etc/grub.d/30_uefi-firmware ###
GRUB
printf '#!/bin/sh\n' > "$work/generator"
chmod +x "$work/generator"

policy() { grub_firmware_policy "$work/grub" "$work/$1.cfg" "$work/generator"; }
apply() { grub_apply_firmware_policy "$1" "$work/candidate.cfg" "$work/filtered.cfg"; }

# With no option, regeneration must not add a firmware entry to an existing menu.
[ "$(policy plain)" = hide ]
cp "$work/with-firmware.cfg" "$work/candidate.cfg"
apply "$(policy plain)"
cmp "$work/plain.cfg" "$work/candidate.cfg"
grub-script-check "$work/candidate.cfg"

# The generated firmware entry remains untouched when already present.
[ "$(policy with-firmware)" = allow ]
cp "$work/with-firmware.cfg" "$work/candidate.cfg"
apply "$(policy with-firmware)"
cmp "$work/with-firmware.cfg" "$work/candidate.cfg"

# Debian defaults are shell fragments: later overrides win even if computed.
printf 'GRUB_DISABLE_UEFI_FIRMWARE=false\n' > "$work/grub"
printf 'setting=true\nGRUB_DISABLE_UEFI_FIRMWARE="$setting"\n' > "$work/grub.d/90-site.cfg"
[ "$(policy with-firmware)" = hide ]
apply "$(policy with-firmware)"
cmp "$work/plain.cfg" "$work/candidate.cfg"

printf 'GRUB_DISABLE_UEFI_FIRMWARE=false\n' > "$work/grub.d/99-site.cfg"
[ "$(policy plain)" = enable ]
cp "$work/with-firmware.cfg" "$work/candidate.cfg"
apply "$(policy plain)"
cmp "$work/with-firmware.cfg" "$work/candidate.cfg"

# Enabling via defaults cannot override a missing or disabled generator.
chmod -x "$work/generator"
[ "$(policy with-firmware)" = hide ]
rm "$work/generator"
[ "$(policy with-firmware)" = hide ]

# Do not strip an administrator's unrelated command from a modified generator.
cat "$work/plain.cfg" > "$work/candidate.cfg"
cat >> "$work/candidate.cfg" <<'GRUB'
### BEGIN /etc/grub.d/30_uefi-firmware ###
source /grub/site-menu.cfg
### END /etc/grub.d/30_uefi-firmware ###
GRUB
cp "$work/candidate.cfg" "$work/custom.cfg"
if apply hide 2>"$work/error"; then
    printf '%s\n' 'Custom generator content should have blocked the change.' >&2
    exit 1
fi
cmp "$work/custom.cfg" "$work/candidate.cfg"
printf '%s\n' 'GRUB firmware policy checks passed.'
