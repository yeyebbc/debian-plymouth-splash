#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

usage() {
    cat <<'EOF'
Usage: sudo ./debian-grub-menu.sh [--gfxmode MODES]

Install the black GRUB theme on Debian, trying 4K first by default.
With Debian as the default and a single detected Windows entry, place the
regular boot options above a visual divider. Otherwise use a plain centered
menu. Leave Plymouth, Secure Boot, and the existing boot entries alone.

MODES is a comma-separated GRUB resolution list, such as 1920x1080,auto.
The script neither installs GRUB nor enables os-prober. It keeps a backup of
any grub.cfg it replaces and does not reboot.
EOF
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
mode=3840x2160,2560x1440,1920x1080,auto
case $#:${1-} in
    1:-h|1:--help) usage; exit 0 ;;
    0:) ;;
    2:--gfxmode) mode=$2 ;;
    *) usage >&2; exit 2 ;;
esac
printf '%s\n' "$mode" | grep -Eq '^(auto|[1-9][0-9]*x[1-9][0-9]*(x[1-9][0-9]*)?)(,(auto|[1-9][0-9]*x[1-9][0-9]*(x[1-9][0-9]*)?))*$' &&
    [ "$(printf '%s' "$mode" | wc -l)" -eq 0 ] || fail 'Invalid GRUB resolution list.'
[ "$(id -u)" -eq 0 ] || fail 'Run with sudo.'
[ -r /etc/os-release ] && ( . /etc/os-release; [ "${ID:-}" = debian ] ) || fail 'This installer targets Debian.'
for tool in grub-mkconfig grub-script-check dpkg-divert flock; do
    command -v "$tool" >/dev/null || fail "Missing command: $tool"
done

grub=/boot/grub/grub.cfg
scripts=/etc/grub.d
defaults=/etc/default/grub.d/98-centered-monochrome.cfg
theme=/boot/grub/themes/centered-monochrome
linux=$scripts/10_linux
prober=$scripts/30_os-prober
linux_vendor=$scripts/.10_linux.distrib
prober_vendor=$scripts/.30_os-prober.distrib
legacy=$scripts/30_os-prober_advanced
marker='# Managed by debian-grub-menu.sh'

[ -f "$grub" ] && [ ! -L "$grub" ] || fail "Expected a regular GRUB configuration: $grub"
[ -d /etc/default/grub.d ] && [ -d "$scripts" ] || fail 'Expected the Debian GRUB defaults and generator directories.'
exec 9>/boot/grub/.centered-menu.lock
flock -n 9 || fail 'Another GRUB theme installation is running.'
work=$(mktemp -d /boot/grub/.centered-menu.XXXXXXXX)
changes=no
committed=no
backup=
linux_added=no
prober_added=no
made_theme=no

restore() {
    if [ -e "$work/snapshot/$1" ]; then
        cp -p -- "$work/snapshot/$1" "$2"
    else
        rm -f -- "$2"
    fi
}
cleanup() {
    result=$?
    trap - EXIT
    if [ "$changes" = yes ] && [ "$committed" = no ]; then
        set +e
        restore defaults "$defaults"
        restore legacy "$legacy"
        if [ "$prober_added" = yes ]; then
            rm -f -- "$prober"
            dpkg-divert --quiet --local --rename --remove --divert "$prober_vendor" "$prober"
        else
            restore prober "$prober"
        fi
        if [ "$linux_added" = yes ]; then
            rm -f -- "$linux"
            dpkg-divert --quiet --local --rename --remove --divert "$linux_vendor" "$linux"
        else
            restore linux "$linux"
        fi
        for file in theme.txt plain.txt recovery.txt divider.png selection_c.png row-spacing.png; do
            if [ -d "$theme" ]; then restore "$file" "$theme/$file"; fi
        done
        if [ "$made_theme" = yes ]; then rmdir -- "$theme"; fi
        if [ -n "$backup" ]; then rm -f -- "$backup"; fi
    fi
    rm -rf -- "$work"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

check_diversion() {
    actual=$(dpkg-divert --truename "$1")
    if [ "$actual" = "$1" ]; then
        [ ! -e "$2" ] && [ ! -L "$2" ] || fail "Unexpected file: $2"
    elif [ "$actual" = "$2" ] && [ "$(dpkg-divert --listpackage "$1")" = LOCAL ]; then
        [ -f "$2" ] && [ ! -L "$2" ] || fail "Missing regular generator: $2"
        if ! grep -Fxq -- "$marker" "$1" &&
            [ "$(sha256sum -- "$1" | cut -d ' ' -f 1)" != "$3" ]; then
            fail "Refusing to replace an unrecognized GRUB wrapper: $1"
        fi
    else
        fail "Unrecognized GRUB diversion: $1 -> $actual"
    fi
}
[ -x "$linux" ] && [ -f "$prober" ] || fail 'Expected Debian 10_linux and 30_os-prober generators.'
[ ! -L "$theme" ] && { [ ! -e "$theme" ] || [ -d "$theme" ]; } || fail "Unexpected theme directory: $theme"
for file in "$linux" "$prober" "$legacy" "$defaults" "$theme"/*.txt "$theme"/*.png; do
    [ ! -L "$file" ] && { [ ! -e "$file" ] || [ -f "$file" ]; } || fail "Not a regular file: $file"
done
check_diversion "$linux" "$linux_vendor" 0fb401dcbb12e52d04faf9c2d5d45ef6e33c23d49c729716291affa97c6f0838
check_diversion "$prober" "$prober_vendor" ''
if [ -e "$legacy" ] && [ "$(sha256sum -- "$legacy" | cut -d ' ' -f 1)" != 9078aa58e7a0b3b1503a62d7717cd362ba2a260abb4f0f4129332390a808a6cb ]; then
    fail "Refusing to remove an unrecognized generator: $legacy"
fi
if [ -e "$defaults" ] && ! grep -Fxq -- "$marker" "$defaults" &&
    [ "$(sha256sum -- "$defaults" | cut -d ' ' -f 1)" != 8af2a5e1f81ce1a2addcb8a092e74c0f0ab293b7ab20991e14262ba1d9acf69a ]; then
    fail "Refusing to overwrite an unrecognized drop-in: $defaults"
fi
if [ -d "$theme" ] && [ ! -e "$defaults" ]; then
    fail "Refusing to take over a theme without its defaults file: $theme"
fi

mkdir "$work/assets" "$work/snapshot"
cat > "$work/defaults" <<EOF
$marker
GRUB_GFXMODE=$mode
GRUB_THEME=$theme/plain.txt
GRUB_BACKGROUND=""
GRUB_TIMEOUT_STYLE=menu
case \${GRUB_TIMEOUT:-0} in 0) GRUB_TIMEOUT=5 ;; esac
EOF
cat > "$work/linux" <<'SHELL'
#!/bin/sh
# Managed by debian-grub-menu.sh
set -eu
vendor=/etc/grub.d/.10_linux.distrib
# Reordering a non-default index could cause a different entry to auto-boot.
[ "${GRUB_DEFAULT:-0}" = 0 ] || exec "$vendor" "$@"
config=$(mktemp)
trap 'rm -f -- "$config"' EXIT
"$vendor" "$@" > "$config"
awk '
    { lines[NR] = $0 }
    /^menuentry[[:space:]]/ { entries++; if (/gnulinux-simple-/) debian = NR }
    /^submenu[[:space:]]/ {
        submenus++
        if (/gnulinux-advanced-/) start = NR
    }
    start && NR > start && !end && /^}$/ { end = NR }
    END {
        if (entries != 1 || submenus != 1 || !debian || !start || end <= start) {
            for (i = 1; i <= NR; i++) print lines[i]
            exit
        }
        for (i = 1; i < start; i++) print lines[i]
        print "function centered_monochrome_advanced {"
        print lines[start]
        print "\tif [ -n \"$theme\" ]; then set theme=centered-monochrome/recovery.txt; fi"
        for (i = start + 1; i <= end; i++) print lines[i]
        print "}"
        print "set centered_monochrome_has_advanced=1"
        for (i = end + 1; i <= NR; i++) print lines[i]
    }
' "$config"
SHELL
cat > "$work/prober" <<'SHELL'
#!/bin/sh
# Managed by debian-grub-menu.sh
set -eu
vendor=/etc/grub.d/.30_os-prober.distrib
config=$(mktemp)
trap 'rm -f -- "$config"' EXIT
# Keep os-prober disabled if the administrator had disabled its generator.
if [ -x "$vendor" ]; then "$vendor" "$@" > "$config"; fi
# Unknown earlier generators or Xen can put another row above Windows.
standard_order() {
    for script in /etc/grub.d/*; do
        [ -f "$script" ] && [ -x "$script" ] || continue
        case ${script##*/} in
            00_header|05_debian_theme|10_linux|25_bli) ;;
            20_linux_xen)
                for image in /boot/xen*; do
                    if [ -f "$image" ]; then return 1; fi
                done ;;
            30_os-prober) return 0 ;;
            *) return 1 ;;
        esac
    done
    return 1
}
register_advanced() {
    cat <<'GRUB'
if [ "$centered_monochrome_has_advanced" = 1 ]; then
    centered_monochrome_advanced
fi
GRUB
}
if standard_order && awk '
    /^(menuentry|submenu)[[:space:]]/ { entries++ }
    /^menuentry[[:space:]].*--class windows([[:space:]]|$).*osprober-(efi|chain)-/ { windows++ }
    END { exit !(entries == 1 && windows == 1) }
' "$config"; then
    cat -- "$config"
    register_advanced
    cat <<'GRUB'
if [ "$centered_monochrome_has_advanced" = 1 -a -n "$theme" ]; then
    set theme=centered-monochrome/theme.txt
fi
GRUB
else
    register_advanced
    cat -- "$config"
fi
cat <<'GRUB'
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
GRUB
SHELL

# GRUB uses a fixed pitch. Two synchronized views draw the same entries 18 px
# apart. The mask removes duplicates to make only the middle gap wider.
cat > "$work/assets/theme.txt" <<'THEME'
desktop-color: "#000000"
title-text: ""

# Components are painted in reverse order: views, mask, divider.
+ image {
    left = 50%-180
    top = 50%-1
    width = 360
    height = 2
    file = "divider.png"
}
+ image {
    left = 50%-192
    top = 50%-72
    width = 384
    height = 144
    file = "row-spacing.png"
}
THEME
for top in -72 -54; do
    cat >> "$work/assets/theme.txt" <<EOF
+ boot_menu {
    left = 50%-192
    top = 50%$top
    width = 384
    height = 126
    item_font = "GNU Unifont Regular 16"
    item_color = "#C0C0C0"
    selected_item_color = "#FFFFFF"
    selected_item_pixmap_style = "selection_*.png"
    item_height = 18
    item_spacing = 18
    item_padding = 0
    icon_width = 0
    icon_height = 0
    item_icon_space = 12
}
EOF
done
cat > "$work/assets/recovery.txt" <<'THEME'
desktop-color: "#000000"
title-text: ""
+ boot_menu {
    left = 45%-272
    top = 50%-68
    width = 10%+544
    height = 136
    item_font = "GNU Unifont Regular 16"
    item_color = "#C0C0C0"
    selected_item_color = "#FFFFFF"
    selected_item_pixmap_style = "selection_*.png"
    item_height = 28
    item_spacing = 8
    item_padding = 0
    icon_width = 0
    icon_height = 0
    item_icon_space = 12
}
THEME
cp -- "$work/assets/recovery.txt" "$work/assets/plain.txt"
for file in theme plain; do
    if [ "$file" = theme ]; then
        left=50%-180 top=50%+86 width=360
    else
        left=45%-260 top=50%+78 width=10%+520
    fi
    cat >> "$work/assets/$file.txt" <<EOF
+ label {
    id = "__timeout__"
    left = $left
    top = $top
    width = $width
    height = 24
    text = "Booting in %d seconds"
    align = "left"
    font = "GNU Unifont Regular 16"
    color = "#8C8C8C"
}
EOF
done
# Small PNG assets are embedded to keep this installer self-contained.
base64 -d > "$work/assets/divider.png" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEklEQVQI12P08PBggAEmBiQAABSO
ANys7/sbAAAAAElFTkSuQmCC
PNG
base64 -d > "$work/assets/selection_c.png" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAFElEQVQI12NUUlJigAEmBiSAmwMA
FPAAbv+wByAAAAAASUVORK5CYII=
PNG
base64 -d > "$work/assets/row-spacing.png" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAYAAAACQCAYAAAABZryQAAABmElEQVR42u3dsQEDIRAEscP998zX
gAMIRqpgswl3BgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+N+amf16BAD3/V4PAOANAQCIEgCA
KAEAiBIAgCgBAIgSAIAoAQCIEgCAKAEAiBIAgCgBAIgSAIAoAQCIEgCAKAEAiBIAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAgGNrZvbrEQDc5xMYIEoAAKIEACBKAACiBAAgSgAAogQAIEoAAKIE
ACBKAACiBAAgSgAAogQAIEoAAKIEACBKAACiBAAgSgAAogQAIEoAAKIEACBKAACiBAAgSgAAogQA
IEoAAKIEACBKAACiBAAgSgAAogQAIEoAAKIEACBKAACiBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAADg2JqZ/XoEAPf5BAaIEgCAKAEAiBIAgCgBAIgSAIAoAQCIEgCAKAEAiBIAgCgBAIgSAIAo
AQCIEgCAKAEAiBIAgCgBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADj2Ab3nA4uNJP9OAAAA
AElFTkSuQmCC
PNG

snapshot() { if [ -f "$1" ]; then cp -p -- "$1" "$work/snapshot/$2"; fi; }
snapshot "$defaults" defaults
snapshot "$linux" linux
snapshot "$prober" prober
snapshot "$legacy" legacy
for file in "$work/assets/"*; do snapshot "$theme/${file##*/}" "${file##*/}"; done
changes=yes
if [ ! -d "$theme" ]; then install -d -m 0755 -- "$theme"; made_theme=yes; fi
install -m 0644 -- "$work/assets/"* "$theme/"
install -m 0644 -- "$work/defaults" "$defaults"
if [ "$(dpkg-divert --truename "$linux")" = "$linux" ]; then
    dpkg-divert --quiet --local --rename --add --divert "$linux_vendor" "$linux"
    linux_added=yes
fi
if [ "$(dpkg-divert --truename "$prober")" = "$prober" ]; then
    dpkg-divert --quiet --local --rename --add --divert "$prober_vendor" "$prober"
    prober_added=yes
fi
install -m 0755 -- "$work/linux" "$linux"
install -m 0755 -- "$work/prober" "$prober"
rm -f -- "$legacy"

grub-mkconfig -o "$work/grub.cfg"
grub-script-check "$work/grub.cfg"
# Accept rediscovered devices and added entries, but never lose a boot option
# or change a boot payload. Use stable IDs where available, not disk names.
boot_contract() {
    awk '
        /^[[:space:]]*(linux|linuxefi|initrd|initrdefi|chainloader|fwsetup)([[:space:]]|$)/ { sub(/^[[:space:]]+/, ""); print }
        /^[[:space:]]*(menuentry|submenu)[[:space:]]/ {
            if (match($0, /\$menuentry_id_option \047[^\047]+\047/)) print substr($0, RSTART, RLENGTH)
            else { sub(/^[[:space:]]+/, ""); print }
        }
    ' "$1" | LC_ALL=C sort
}
boot_contract "$grub" > "$work/before"
boot_contract "$work/grub.cfg" > "$work/after"
LC_ALL=C comm -23 "$work/before" "$work/after" > "$work/missing"
if [ -s "$work/missing" ]; then
    cat "$work/missing" >&2
    fail 'The generated menu lost entries or changed boot commands. Nothing was installed.'
fi
grep -Eq '^[[:space:]]*set timeout_style=menu$' "$work/grub.cfg" || fail 'The generated configuration does not display a menu.'
grep -Eq '^[[:space:]]*set timeout=(-1|[1-9][0-9]*)$' "$work/grub.cfg" || fail 'The generated menu has no visible timeout.'
grep -Eq '^set theme=.*\/grub\/themes\/centered-monochrome\/plain\.txt$' "$work/grub.cfg" || fail 'The generated configuration did not load the graphical theme.'
if ! cmp -s -- "$grub" "$work/grub.cfg"; then
    backup=$(mktemp "$grub.before-centered-menu.XXXXXXXX")
    cp -p -- "$grub" "$backup"
    mv -fT -- "$work/grub.cfg" "$grub"
fi
committed=yes
if [ -n "$backup" ]; then printf 'Previous GRUB configuration: %s\n' "$backup"; fi
printf '%s\n' 'GRUB theme installed. Plymouth and Secure Boot were not changed.'
