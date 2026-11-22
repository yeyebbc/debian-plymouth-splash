#!/bin/sh
# Debian 13: install the white Debian boot and shutdown splash.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

usage() {
    cat <<'EOF'
Usage: sudo sh debian-plymouth-splash.sh [--no-grub]

Installs a white Debian swirl on black for boot, power-off, and reboot.
Requires Debian with systemd, plymouth, plymouth-label, desktop-base, and
ImageMagick with SVG support (librsvg2-bin supplies the SVG renderer).
Rebuilds and verifies existing /boot/initrd.img-* images using
initramfs-tools. Re-running is safe.

Updates GRUB if /boot/grub/grub.cfg exists. Use --no-grub to skip GRUB
even if its configuration is present. GRUB remains visible; existing
Windows entries must survive regeneration. GRUB_DISABLE_UEFI_FIRMWARE=true
hides the stock firmware entry, false permits it, and unset preserves its
visibility. A disabled generator stays disabled; custom entries are left alone.

For other bootloaders, add quiet splash to the Debian kernel command line
without removing other arguments. If the boot image embeds a Debian
initramfs (e.g. Android boot.img), rebuild it with the updated initramfs.
If there is no local initramfs, Plymouth can start when systemd takes over.
For an earlier splash, include and start Plymouth in your existing ramdisk.
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
require_commands() {
    for tool do
        command -v "$tool" >/dev/null || fail "Missing required command: $tool"
    done
}

manage_grub=auto
case $#:${1-} in
    1:-h|1:--help) usage; exit 0 ;;
    1:--no-grub) manage_grub=no ;;
    0:) ;;
    *) usage >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || fail 'Run this installer with sudo.'
require_commands plymouth plymouth-set-default-theme systemctl systemd-analyze
if command -v magick >/dev/null; then imagemagick=magick
elif command -v convert >/dev/null; then imagemagick=convert
else fail 'Install imagemagick first.'
fi

name=debian-monochrome
theme=/usr/share/plymouth/themes/$name
logo=/usr/share/desktop-base/debian-logos/logo.svg
grub=/boot/grub/grub.cfg
dropin=/etc/default/grub.d/99-debian-monochrome-splash.cfg
[ -r "$logo" ] || fail 'Install desktop-base for the official Debian swirl.'
[ ! -L "$theme" ] || fail "Unexpected Plymouth theme path: $theme"

if [ "$manage_grub" = auto ] && { [ -e "$grub" ] || [ -L "$grub" ]; }; then
    manage_grub=yes
    [ -f "$grub" ] && [ ! -L "$grub" ] || fail "Expected a regular GRUB configuration: $grub"
    [ ! -L "$dropin" ] && { [ ! -e "$dropin" ] || [ -f "$dropin" ]; } ||
        fail "Unexpected GRUB defaults path: $dropin"
    require_commands grub-mkconfig grub-script-check
    script_path=$(realpath -- "$0")
    script_dir=${script_path%/*}
    . "$script_dir/grub-firmware.sh"
    firmware_policy=$(grub_firmware_policy /etc/default/grub "$grub" /etc/grub.d/30_uefi-firmware)
else
    manage_grub=no
fi

set --
for image in /boot/initrd.img-*; do
    if [ -f "$image" ]; then set -- "$@" "$image"; fi
done
if [ "$#" -gt 0 ]; then
    require_commands update-initramfs unmkinitramfs
elif [ "$manage_grub" = yes ]; then
    fail 'No installed initramfs images under /boot.'
fi
plugin_dir=$(plymouth --get-splash-plugin-path)
[ -r "${plugin_dir%/}/script.so" ] && [ -r "${plugin_dir%/}/label-pango.so" ] ||
    fail 'Install plymouth and plymouth-label first.'

work=$(mktemp -d)
grub_work=
restore_grub=no
cleanup() {
    if [ "$restore_grub" = yes ]; then rm -f -- "$dropin"; fi
    [ -z "$grub_work" ] || rm -rf -- "$grub_work"
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Pre-render common sizes to avoid Plymouth's runtime resampling at those sizes.
"$imagemagick" -background none -density 576 "$logo" -trim +repage -alpha extract "$work/source-mask.png"
for height in 96 120 240 480; do
    width=$(( (height * 13 + 8) / 16 ))
    size=${width}x${height}
    "$imagemagick" "$work/source-mask.png" -filter Triangle -resize "$size" \
        -background black -gravity center -extent "$size" -auto-level "$work/mask.png"
    "$imagemagick" -size "$size" xc:'#FFFFFF' "$work/mask.png" \
        -compose CopyOpacity -composite -strip "PNG32:$work/swirl-$height.png"
done

cat > "$work/$name.plymouth" <<EOF
[Plymouth Theme]
Name=Debian Monochrome
Description=Responsive white Debian swirl on black
ModuleName=script

[script]
ImageDir=$theme
ScriptFile=$theme/$name.script
EOF
cat > "$work/$name.script" <<'PLYMOUTH'
Window.SetBackgroundTopColor(0, 0, 0);
Window.SetBackgroundBottomColor(0, 0, 0);

swirl = Image("swirl-480.png");
screens[0] = NULL;
screen_count = 0;
message_image = NULL;
prompt_image = NULL;
answer_image = NULL;

fun center(sprite, image, screen, y, z) {
    sprite.SetPosition(screen.x + Math.Int((screen.width - image.GetWidth()) / 2), y, z);
}

fun label_image(text) {
    if (text == NULL || text == "") return NULL;
    return Image.Text(text, 1, 1, 1);
}

fun place_label(sprite, image, screen, y) {
    if (image == NULL) {
        sprite.SetOpacity(0);
        return 0;
    }
    local.width = Math.Max(1, screen.width - 16);
    if (image.GetWidth() > width) {
        image = image.Scale(width, Math.Max(1, Math.Int(image.GetHeight() * width / image.GetWidth())));
    }
    center(sprite, image, screen, y, 1);
    sprite.SetImage(image);
    sprite.SetOpacity(1);
    return image.GetHeight();
}

fun place_message(screen) {
    if (message_image == NULL) {
        screen.message.SetOpacity(0);
        return;
    }
    place_label(screen.message, message_image, screen,
                Math.Max(0, screen.top - message_image.GetHeight() - 16));
}

fun place_prompt(screen) {
    local.y = screen.top + screen.logo_height + 16;
    local.height = place_label(screen.prompt, prompt_image, screen, y);
    place_label(screen.answer, answer_image, screen, y + height + 8);
}

fun layout_displays() {
    local.index = 0;
    local.left = 0;
    while (Window.GetWidth(index) != NULL) {
        if (screens[index] == NULL) {
            global.screens[index].logo = Sprite();
            global.screens[index].message = Sprite();
            global.screens[index].prompt = Sprite();
            global.screens[index].answer = Sprite();
        }
        local.screen = screens[index];
        screen.x = left;
        screen.width = Window.GetWidth(index);
        local.height = Window.GetHeight(index);
        # Plymouth reports logical pixels and maps them to each output's DPI scale.
        # The short edge sets the size, with a logical floor and a small-screen cap.
        local.edge = Math.Min(screen.width, height);
        local.logo_height = Math.Max(1, Math.Min(Math.Clamp(Math.Int(edge / 9 + 0.5), 96, 480), Math.Int(edge / 4)));
        if (screen.logo_height != logo_height) {
            if (logo_height == 480) {
                screen.logo_image = swirl;
            } else if (logo_height == 96 || logo_height == 120 || logo_height == 240) {
                screen.logo_image = Image("swirl-" + logo_height + ".png");
            } else {
                local.logo_width = Math.Max(1, Math.Int(logo_height * swirl.GetWidth() / swirl.GetHeight() + 0.5));
                screen.logo_image = swirl.Scale(logo_width, logo_height);
            }
            screen.logo.SetImage(screen.logo_image);
            screen.logo_height = logo_height;
        }
        screen.top = Math.Int((height - logo_height) / 2);
        # Give each display its own non-overlapping viewport in the sprite scene.
        Window.SetX(index, left);
        Window.SetY(index, 0);
        center(screen.logo, screen.logo_image, screen, screen.top, 0);
        place_message(screen);
        place_prompt(screen);
        left += screen.width;
        index++;
    }
    local.old_count = screen_count;
    global.screen_count = index;
    while (index < old_count) {
        global.screens[index] = NULL;
        index++;
    }
}

fun show_message(text) {
    global.message_image = label_image(text);
    local.i = 0;
    for (i = 0; i < screen_count; i++) place_message(screens[i]);
}

fun hide_message(text) { show_message(""); }

fun show_question(prompt, answer) {
    global.prompt_image = label_image(prompt);
    global.answer_image = label_image(answer);
    local.i = 0;
    for (i = 0; i < screen_count; i++) place_prompt(screens[i]);
}

fun show_password(prompt, count) {
    local.bullets = "";
    local.i = 0;
    for (i = 0; i < count; i++) bullets += "*";
    show_question(prompt, bullets);
}

fun show_normal() { show_question("", ""); }

layout_displays();
Plymouth.SetDisplayHotplugFunction(layout_displays);
Plymouth.SetDisplayMessageFunction(show_message);
Plymouth.SetHideMessageFunction(hide_message);
Plymouth.SetDisplayPasswordFunction(show_password);
Plymouth.SetDisplayQuestionFunction(show_question);
Plymouth.SetDisplayNormalFunction(show_normal);
PLYMOUTH

check_grub() {
    awk '
        $1 == "set" && $2 ~ /^timeout_style=/ { menu = ($2 == "timeout_style=menu") }
        menu && $1 == "set" && $2 ~ /^timeout=(-1|[1-9][0-9]*)$/ { visible = 1 }
        /^### BEGIN .*\/10_linux ###$/ { debian = 1; next }
        /^### END .*\/10_linux ###$/ { debian = 0; next }
        debian && $1 ~ /^linux(efi)?$/ && $0 !~ /[[:space:]]single([[:space:]]|$)/ {
            linux_entry = 1
            if ($0 !~ /[[:space:]]quiet([[:space:]]|$)/ || $0 !~ /[[:space:]]splash([[:space:]]|$)/) bad = 1
        }
        END { exit !(visible && linux_entry && !bad) }
    ' "$1"
}

windows_entries() {
    awk 'tolower($0) ~ /^[[:space:]]*menuentry[[:space:]].*windows/ {
        sub(/\(on \/dev\/[^)]+\)/, ""); print
    }' "$1"
}

if [ "$manage_grub" = yes ]; then
    if [ ! -e "$dropin" ]; then
        cat > "$work/grub-defaults" <<'GRUB'
# Show Plymouth after selecting Debian, not in the GRUB menu.
for plymouth_flag in quiet splash; do
    case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
        *" $plymouth_flag "*) ;;
        *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }$plymouth_flag" ;;
    esac
done
unset plymouth_flag
GRUB_TIMEOUT_STYLE=menu
case ${GRUB_TIMEOUT:-0} in 0) GRUB_TIMEOUT=5 ;; esac
GRUB
        restore_grub=yes
        install -D -m 0644 -- "$work/grub-defaults" "$dropin"
    fi
    if ! check_grub "$grub" ||
        { [ "$firmware_policy" = enable ] && ! grub_has_firmware_entry "$grub"; }; then
        grub_work=$(mktemp -d /boot/grub/.debian-monochrome.XXXXXXXX)
        grub-mkconfig -o "$grub_work/grub.cfg"
        grub_apply_firmware_policy "$firmware_policy" "$grub_work/grub.cfg" "$grub_work/no-firmware.cfg"
        grub-script-check "$grub_work/grub.cfg"
        check_grub "$grub_work/grub.cfg" || fail 'The generated GRUB configuration does not keep a visible menu and quiet splash.'
        if [ "$firmware_policy" = allow ] && ! grub_has_firmware_entry "$grub_work/grub.cfg"; then
            fail 'The generated menu lost the firmware entry; leaving the current GRUB menu intact.'
        fi
        windows_entries "$grub" > "$work/windows.old"
        windows_entries "$grub_work/grub.cfg" > "$work/windows.new"
        if grep -Fxvf "$work/windows.new" "$work/windows.old"; then
            fail 'An existing Windows entry is missing; leaving the current GRUB menu intact.'
        fi
    elif [ "$firmware_policy" = hide ] && grub_has_firmware_entry "$grub"; then
        grub_work=$(mktemp -d /boot/grub/.debian-monochrome.XXXXXXXX)
        cp -p -- "$grub" "$grub_work/grub.cfg"
        grub_apply_firmware_policy "$firmware_policy" "$grub_work/grub.cfg" "$grub_work/no-firmware.cfg"
        grub-script-check "$grub_work/grub.cfg"
    else
        grub-script-check "$grub"
        printf '%s\n' 'Existing GRUB menu already has quiet splash and matches the firmware policy; leaving grub.cfg unchanged.'
    fi
fi

install -d -m 0755 -- "$theme"
install -m 0644 -- "$work/$name.plymouth" "$work/$name.script" "$work"/swirl-*.png "$theme/"
rm -f -- "$theme/swirl.png"
if [ "$(plymouth-set-default-theme)" != "$name" ]; then plymouth-set-default-theme "$name"; fi

for action in poweroff reboot; do
    mode=$action
    if [ "$action" = poweroff ]; then mode=shutdown; fi
    cat > "$work/shutdown-service" <<EOF
[Unit]
Before=shutdown.target

[Service]
# The attached console session makes Plymouth turn systemd status output back on.
ExecStart=
ExecStart=/usr/sbin/plymouthd --mode=$mode
# Let the renderer take over its VT before the final shutdown jobs proceed.
ExecStartPost=-/usr/bin/timeout 2s /bin/sh -c 'until /usr/bin/plymouth --has-active-vt; do /usr/bin/sleep 0.05; done'
EOF
    install -D -m 0644 -- "$work/shutdown-service" "/etc/systemd/system/plymouth-$action.service.d/50-quiet-splash.conf"
done
systemd-analyze verify --recursive-errors=no poweroff.target reboot.target plymouth-poweroff.service plymouth-reboot.service
systemctl daemon-reload

if [ "$#" -gt 0 ]; then
    update-initramfs -u -k all
    for image do
        unmkinitramfs "$image" "$work/initrd"
        embedded=$(find "$work/initrd" -type f -path "*/${theme#/}/$name.plymouth" -print)
        [ -f "$embedded" ] || fail "No unique $name theme in $image."
        for file in "$work/$name.plymouth" "$work/$name.script" "$work"/swirl-*.png; do
            cmp -- "$file" "${embedded%/*}/${file##*/}"
        done
        conf=$(find "$work/initrd" -type f -path '*/etc/plymouth/plymouthd.conf' -print)
        grep -Fxq "Theme=$name" "$conf" || fail "The theme is not selected in $image."
        printf 'Verified theme in %s\n' "$image"
        rm -rf -- "$work/initrd"
    done
fi

if [ -n "$grub_work" ]; then mv -fT -- "$grub_work/grub.cfg" "$grub"; fi
restore_grub=no
printf '%s\n' 'Installed responsive Plymouth theme and power-off/reboot configuration.'
if [ "$manage_grub" = no ]; then
    printf '%s\n' 'GRUB was not changed. Add quiet splash to your Debian kernel command line.'
    if [ "$#" -eq 0 ]; then
        printf '%s\n' \
            'No /boot/initrd.img-* images found; no initramfs was rebuilt.' \
            'Plymouth can start when systemd takes over. For an earlier splash, include and start Plymouth in your boot ramdisk.'
    else
        printf '%s\n' 'If your boot image embeds the initramfs (e.g. Android boot.img), rebuild it with the updated initramfs.'
    fi
fi
