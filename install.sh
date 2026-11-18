#!/bin/bash
# install.sh - Arch + Hyprland: минимальная установка, пастельно-оливковая тема
# Запуск: su -   затем   bash install.sh [ИМЯ_ПОЛЬЗОВАТЕЛЯ]
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root: su -"; exit 1; }
[ -f /etc/arch-release ] || { echo "Нужен Arch Linux"; exit 1; }
U="${1:-$(getent passwd 1000 | cut -d: -f1 || true)}"
[ -n "$U" ] || { echo "Не нашёл пользователя. Запусти: bash install.sh ИМЯ"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "Пользователь $U не существует"; exit 1; }
H="/home/$U"
G="$(id -gn "$U")"

# ================= пакеты =================
# multilib нужен только для Steam (32-бит библиотеки)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  grep -q '^\[multilib\]' /etc/pacman.conf \
    || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
# Arch - rolling: без полного обновления ставить пакеты нельзя
pacman -Syu --noconfirm --needed sudo
nv="$(pacman -Qq 2>/dev/null | grep -E '^(nvidia|lib32-nvidia|opencl-nvidia|lib32-opencl-nvidia)' || true)"
[ -z "$nv" ] || pacman -Rns --noconfirm $nv || true
pacman -S --noconfirm --needed \
  hyprland hyprland-guiutils xdg-desktop-portal-hyprland xorg-xwayland qt6-wayland \
  alacritty waybar wofi swaybg \
  pipewire pipewire-pulse wireplumber \
  brightnessctl grim slurp wl-clipboard \
  ttf-dejavu ttf-font-awesome noto-fonts-emoji papirus-icon-theme adwaita-icon-theme lxqt-policykit ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
  python-gobject gtk3 mesa vulkan-intel power-profiles-daemon libpulse networkmanager gtk-layer-shell udisks2 xdg-utils xdg-user-dirs \
  fastfetch chafa cava nano curl dosfstools exfatprogs ntfs-3g mat2 bubblewrap perl-image-exiftool \
  firefox firefox-i18n-ru telegram-desktop \
  jre21-openjdk
echo "=== Steam ==="
pacman -S --noconfirm --needed steam lib32-mesa lib32-vulkan-intel \
  || echo "!! Steam не установился (скрипт продолжает работу)"

# ================= sudo =================
usermod -aG wheel,video "$U"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null || rm -f /etc/sudoers.d/10-wheel

# ================= NVIDIA: отключена полностью, работает только Intel =================
# 1) драйверы (nouveau/nvidia) не загружаются никогда
cat > /etc/modprobe.d/disable-nvidia.conf <<'NVEOF'
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
blacklist nvidiafb
blacklist i2c_nvidia_gpu
install nouveau /bin/false
options nouveau modeset=0
NVEOF
# 2) при загрузке ядро "забывает" само PCI-устройство NVIDIA: карта не видна системе и не питается
cat > /etc/udev/rules.d/00-remove-nvidia.rules <<'NVEOF'
# NVIDIA USB xHCI / Type-C UCSI / Audio / VGA-3D: удалить из системы
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
NVEOF
udevadm control --reload 2>/dev/null || true
# 3) чтобы nouveau не попал в initramfs
if command -v mkinitcpio >/dev/null 2>&1; then mkinitcpio -P || echo "!! mkinitcpio вернул ошибку (проверь вручную)"; fi

# профили питания (меню производительности)
systemctl enable power-profiles-daemon.service >/dev/null 2>&1 || echo "!! не удалось включить power-profiles-daemon"
systemctl start power-profiles-daemon.service >/dev/null 2>&1 || true

# Prism Launcher больше не нужен: убрать, если уже установлен
if pacman -Q prismlauncher >/dev/null 2>&1; then pacman -Rns --noconfirm prismlauncher || echo "!! не удалось удалить prismlauncher"; fi

# сеть: меню Wi-Fi работает через NetworkManager (включаем, только если нет другого сетевого сервиса)
if ! systemctl is-active --quiet NetworkManager.service; then
  other=""
  for s in iwd systemd-networkd dhcpcd wpa_supplicant connman netctl; do
    if systemctl is-enabled --quiet "$s.service" 2>/dev/null || systemctl is-active --quiet "$s.service" 2>/dev/null; then
      other="$other $s"
    fi
  done
  if [ -z "$other" ]; then
    systemctl enable --now NetworkManager.service >/dev/null 2>&1 || echo "!! не удалось включить NetworkManager"
  else
    echo "!! сеть сейчас управляется:$other - меню сети в waybar заработает только с NetworkManager"
  fi
fi

# ================= системные утилиты =================
cat > /usr/local/bin/pkg-install <<'EOF2'
#!/bin/sh
f="$(readlink -f "$1")"
[ -f "$f" ] || { echo "Файл не найден: $1"; exit 1; }
exec alacritty --title "Установка пакета Arch" -e sh -c '
echo "Устанавливаю: $1"; echo
sudo pacman -U --noconfirm "$1"
echo; printf "Готово. Нажми Enter, чтобы закрыть..."; read _
' sh "$f"
EOF2
chmod 755 /usr/local/bin/pkg-install

cat > /usr/local/bin/launcher.sh <<'EOF'
#!/bin/sh
# повторное нажатие закрывает wofi
if pgrep -x wofi >/dev/null 2>&1; then
  pkill -x wofi
  exit 0
fi
exec wofi --show drun
EOF
chmod 755 /usr/local/bin/launcher.sh
cat > /usr/local/bin/hypr-launcher <<'EOF'
#!/bin/sh
exec /usr/local/bin/launcher.sh
EOF
chmod 755 /usr/local/bin/hypr-launcher

# ---------- файловый менеджер Files ----------
cat > /usr/local/bin/files <<'EOF'
#!/usr/bin/python3
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import unquote
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

HOME = os.path.realpath(os.path.expanduser("~"))
TRASH = os.path.join(HOME, ".local", "share", "Trash")
TRASH_FILES = os.path.join(TRASH, "files")
TRASH_INFO = os.path.join(TRASH, "info")
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "files")
MARKS = os.path.join(CONF, "bookmarks")
DND = [Gtk.TargetEntry.new("text/uri-list", 0, 0)]
ACT_COPY, ACT_MOVE = Gdk.DragAction.COPY, Gdk.DragAction.MOVE
CSS = b"""
* { font-family: "DejaVu Sans Mono", monospace; font-size: 11px; }
window { background-color: rgba(15,20,16,0.82); color: #e4ebe2; }
window.dialog, window.messagedialog { background-color: rgb(20,27,22); }
.bar { padding: 8px 10px 4px 10px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 14px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(169,204,130,0.16); }
button:checked { background-color: rgba(169,204,130,0.30); }
button:disabled { opacity: 0.35; }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 14px; box-shadow: none;
padding: 2px 12px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
.side { background-color: rgba(169,204,130,0.04); border-right: 1px solid rgba(169,204,130,0.15); }
.side row { padding: 5px 10px; margin: 1px 8px; border-radius: 10px; background: transparent; }
.side row:hover { background-color: rgba(169,204,130,0.10); }
.side row:selected { background-color: rgba(169,204,130,0.25); color: #ffffff; }
.side row:drop(active) { background-color: rgba(169,204,130,0.35); }
.sect { color: #8a9a82; font-size: 9px; padding: 10px 18px 2px 18px; }
treeview.view { background-color: transparent; color: #e4ebe2; }
treeview.view:hover { background-color: rgba(169,204,130,0.08); }
treeview.view:selected { background-color: rgba(169,204,130,0.28); color: #ffffff; }
treeview.view:drop(active) { border: 1px solid rgba(169,204,130,0.80); }
treeview.view.dnd { border: 1px solid rgba(169,204,130,0.80); }
treeview header button { background-color: transparent; border: none; border-radius: 0;
border-bottom: 1px solid rgba(169,204,130,0.18); color: #8a9a82; padding: 3px 8px; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar { background: transparent; border: none; }
.status { color: #8a9a82; padding: 3px 14px 6px 14px; }
.err { color: #d98b7d; }
.dim { color: #8a9a82; }
menu, .menu { background-color: rgb(20,27,22); color: #e4ebe2; border: 1px solid rgba(169,204,130,0.30);
border-radius: 8px; padding: 4px; }
menuitem { padding: 4px 10px; border-radius: 6px; }
menuitem:hover { background-color: rgba(169,204,130,0.18); }
separator { background-color: rgba(169,204,130,0.15); min-height: 1px; }
treeview entry, treeview.view entry, entry.cell { background-color: rgb(30,41,32); background-image: none;
color: #e4ebe2; border: 1px solid #a9cc82; border-radius: 6px; padding: 1px 6px; box-shadow: none; }
.sub { color: #8a9a82; font-size: 9px; }
levelbar trough { background-color: rgba(169,204,130,0.15); border: none; border-radius: 3px; min-height: 4px; }
levelbar block.empty { background-color: transparent; border: none; }
levelbar.ok block.filled { background-color: #a9cc82; border: none; border-radius: 3px; }
levelbar.warn block.filled { background-color: #d8b76c; border: none; border-radius: 3px; }
levelbar.crit block.filled { background-color: #d98b7d; border: none; border-radius: 3px; }
"""
PLACES = [
    ("user-home-symbolic", "Домашняя папка", HOME),
    ("user-desktop-symbolic", "Рабочий стол", os.path.join(HOME, "Desktop")),
    ("folder-documents-symbolic", "Документы", os.path.join(HOME, "Documents")),
    ("folder-download-symbolic", "Загрузки", os.path.join(HOME, "Downloads")),
    ("folder-pictures-symbolic", "Изображения", os.path.join(HOME, "Pictures")),
    ("folder-music-symbolic", "Музыка", os.path.join(HOME, "Music")),
    ("folder-videos-symbolic", "Видео", os.path.join(HOME, "Videos")),
]
SKIP_FS = ("swap", "crypto_LUKS", "LVM2_member", "linux_raid_member")
ARCHIVE_EXT = (".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")


def human(n):
    units = ("Б", "КБ", "МБ", "ГБ", "ТБ")
    for i, u in enumerate(units):
        if n < 1024 or i == len(units) - 1:
            return f"{n:.0f} {u}" if i == 0 else f"{n:.1f} {u}"
        n /= 1024


def unique(dest_dir, name):
    base, ext = os.path.splitext(name)
    cand, i = name, 1
    while os.path.lexists(os.path.join(dest_dir, cand)):
        cand = f"{base} ({i}){ext}"
        i += 1
    return os.path.join(dest_dir, cand)


def is_real_dir(p):
    return os.path.isdir(p) and not os.path.islink(p)


def in_trash(p):
    return p == TRASH_FILES or p.startswith(TRASH_FILES + os.sep)


def err_text(e):
    return getattr(e, "message", None) or str(e)


def remove_path(p):
    if is_real_dir(p):
        shutil.rmtree(p)
    else:
        os.remove(p)


def drop_trashinfo(src):
    if os.path.dirname(src) == TRASH_FILES:
        try:
            os.remove(os.path.join(TRASH_INFO, os.path.basename(src) + ".trashinfo"))
        except OSError:
            pass


def transfer(paths, dest, move):
    """Копирует или переносит paths в папку dest. Возвращает (сколько сделано, [ошибки])."""
    done, errs = 0, []
    to_trash = in_trash(dest)
    rdest = os.path.realpath(dest)
    for src in paths:
        try:
            if not os.path.lexists(src):
                raise OSError("нет такого файла: " + os.path.basename(src))
            if to_trash:
                if not in_trash(src):
                    Gio.File.new_for_path(src).trash(None)
                    done += 1
                continue
            if move and os.path.realpath(os.path.dirname(src)) == rdest:
                continue
            dst = unique(dest, os.path.basename(src))
            rsrc = os.path.realpath(src)
            if is_real_dir(src) and (rdest + os.sep).startswith(rsrc + os.sep):
                raise OSError("нельзя поместить папку саму в себя")
            if move:
                shutil.move(src, dst)
                drop_trashinfo(src)
            elif is_real_dir(src):
                shutil.copytree(src, dst, symlinks=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
            done += 1
        except Exception as e:
            errs.append(err_text(e))
    return done, errs


def restore(path):
    """Возвращает файл из корзины на прежнее место."""
    if os.path.dirname(path) != TRASH_FILES:
        raise OSError("восстановить можно только то, что лежит в корне корзины")
    info = os.path.join(TRASH_INFO, os.path.basename(path) + ".trashinfo")
    orig = None
    try:
        with open(info, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("Path="):
                    orig = unquote(line[5:].strip())
                    break
    except OSError:
        pass
    if not orig or not os.path.isabs(orig):
        raise OSError("неизвестно, откуда этот файл")
    parent = os.path.dirname(orig)
    os.makedirs(parent, exist_ok=True)
    dst = unique(parent, os.path.basename(orig))
    shutil.move(path, dst)
    try:
        os.remove(info)
    except OSError:
        pass
    return dst


def make_zip(paths, dest):
    """Пакует paths в zip. Возвращает список ошибок (пустой - всё хорошо)."""
    import zipfile
    errs = []
    try:
        with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
            for src in paths:
                base = os.path.dirname(src)
                todo = [src]
                if is_real_dir(src):
                    for r, ds, fs in os.walk(src):
                        todo.extend(os.path.join(r, n) for n in ds + fs)
                for p in todo:
                    try:
                        z.write(p, os.path.relpath(p, base))
                    except Exception as e:
                        errs.append(err_text(e))
    except Exception as e:
        errs.append(err_text(e))
    return errs


def extract_archive(src, dest):
    """Распаковывает zip/tar в новую папку dest. Возвращает список ошибок."""
    import tarfile
    import zipfile
    try:
        os.makedirs(dest)
        if zipfile.is_zipfile(src):
            with zipfile.ZipFile(src) as z:
                z.extractall(dest)
        elif tarfile.is_tarfile(src):
            if not hasattr(tarfile, "data_filter"):
                raise OSError("в этом Python нет безопасной распаковки tar")
            with tarfile.open(src) as t:
                t.extractall(dest, filter="data")
        else:
            raise OSError("это не zip/tar-архив")
    except Exception as e:
        shutil.rmtree(dest, ignore_errors=True)
        return [err_text(e)]
    return []


def empty_trash():
    errs = []
    for d in (TRASH_FILES, TRASH_INFO):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            try:
                remove_path(os.path.join(d, n))
            except Exception as e:
                errs.append(err_text(e))
    return errs


def tree_stats(paths, stop):
    size = files = dirs = 0
    stack = list(paths)
    while stack and not stop.is_set():
        p = stack.pop()
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            dirs += 1
            try:
                with os.scandir(p) as it:
                    stack.extend(e.path for e in it)
            except OSError:
                pass
        else:
            files += 1
            size += st.st_size
    return size, files, dirs


def load_marks():
    try:
        with open(MARKS, encoding="utf-8") as f:
            return [ln.strip() for ln in f if ln.strip().startswith("/")]
    except OSError:
        return []


def save_marks(marks):
    try:
        os.makedirs(CONF, exist_ok=True)
        with open(MARKS, "w", encoding="utf-8") as f:
            f.write("".join(m + "\n" for m in marks))
    except OSError:
        pass


def uris_to_paths(data):
    out = []
    for u in data.get_uris() or []:
        p = Gio.File.new_for_uri(u).get_path()
        if p:
            out.append(p)
    return out


def drag_status(ctx, action, t):
    f = getattr(Gdk, "drag_status", None)
    if f is not None:
        f(ctx, action, t)
    else:
        ctx.drag_status(action, t)


def stem_len(name, isdir):
    """Сколько символов в имени без расширения (для выделения при переименовании)."""
    if isdir:
        return len(name)
    m = re.search(r"\.tar\.(gz|bz2|xz|zst|lz4|lzma)$", name, re.I)
    if m and m.start() > 0:
        return m.start()
    i = name.rfind(".")
    return i if i > 0 else len(name)


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def truthy(v):
    return str(v).lower() in ("1", "true")


def lsblk_json(cols):
    for c in (cols, cols.replace("MOUNTPOINTS", "MOUNTPOINT")):
        try:
            r = subprocess.run(["lsblk", "-b", "-J", "-o", c], capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                return json.loads(r.stdout)
        except Exception:
            pass
    return {}


def mount_list(n):
    mps = n.get("mountpoints")
    if mps is None:
        mps = [n.get("mountpoint")]
    return [m for m in mps if m]


SHOW_MP = ("/media", "/run/media", "/mnt")


def list_devices():
    data = lsblk_json("NAME,LABEL,SIZE,FSTYPE,MOUNTPOINTS,PATH,TYPE,RM,PKNAME,UUID")
    res = []

    def walk(nodes, inherit_rm=False):
        for n in nodes:
            rm = truthy(n.get("rm")) or inherit_rm
            fs = n.get("fstype")
            typ = n.get("type")
            mps = mount_list(n)
            keep, mp = False, None
            if fs and fs not in SKIP_FS and typ != "loop":
                vis = [m for m in mps if m in ("/", "/home") or m.startswith(SHOW_MP)]
                if not mps:
                    # крошечный EFI-раздел внутреннего диска в списке не нужен
                    keep = not (fs == "vfat" and to_int(n.get("size")) < (1 << 30) and not rm)
                elif vis:
                    keep = True
                    mp = "/" if "/" in vis else vis[0]
            if keep:
                if n.get("label"):
                    title = n.get("label")
                elif mp == "/":
                    title = "Система"
                elif mp == "/home":
                    title = "Домашний диск"
                else:
                    title = n.get("name")
                res.append(dict(path=n.get("path"), name=n.get("name"), label=n.get("label") or "",
                                title=title, size=to_int(n.get("size")), fstype=fs, mp=mp, rm=rm,
                                pk=n.get("pkname") or "", uuid=n.get("uuid") or ""))
            walk(n.get("children") or [], rm)
    walk(data.get("blockdevices", []))
    return res


# ---------- управление дисками (через UDisks2, права запрашивает polkit) ----------
UDISKS = "org.freedesktop.UDisks2"
MIB = 1 << 20
GPT_LINUX = "0fc63daf-8483-4772-8e79-3d69d8477de4"
GPT_MSDATA = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
FS_TOOLS = (
    ("ext4", "ext4 (Linux)", "mkfs.ext4"),
    ("btrfs", "btrfs", "mkfs.btrfs"),
    ("xfs", "xfs", "mkfs.xfs"),
    ("vfat", "FAT32 (флешки, EFI)", "mkfs.fat"),
    ("exfat", "exFAT (флешки, Windows и Mac)", "mkfs.exfat"),
    ("ntfs", "NTFS (Windows)", "mkfs.ntfs"),
)
OWNER_FS = ("ext4", "btrfs", "xfs")


def udisks_call(path, iface, method, sig, args, timeout=600000):
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    return bus.call_sync(UDISKS, path, iface, method, GLib.Variant(sig, args), None,
                         Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, timeout, None)


def dbus_err(e):
    msg = getattr(e, "message", None) or str(e)
    msg = re.sub(r"^GDBus\.Error:[\w.\-]+:\s*", "", msg.strip())
    return msg.splitlines()[0] if msg else "неизвестная ошибка"


def block_path(dev):
    return "/org/freedesktop/UDisks2/block_devices/" + os.path.basename(dev)


def sys_start(name):
    try:
        with open(f"/sys/class/block/{name}/start") as f:
            return int(f.read().strip()) * 512
    except (OSError, ValueError):
        return None


def scan_disks():
    data = lsblk_json("NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,PTTYPE,RM,MODEL")
    disks = []
    for n in data.get("blockdevices", []):
        if n.get("type") != "disk" or str(n.get("name", "")).startswith(("zram", "ram")):
            continue
        size = to_int(n.get("size"))
        d = dict(path=n.get("path"), name=n.get("name"), size=size, model=(n.get("model") or "").strip(),
                 pttype=n.get("pttype") or "", rm=truthy(n.get("rm")), fstype=n.get("fstype") or "",
                 mps=mount_list(n), parts=[], gaps=[])
        occ = []
        for c in n.get("children") or []:
            if c.get("type") != "part":
                continue
            st = sys_start(c.get("name"))
            psz = to_int(c.get("size"))
            d["parts"].append(dict(path=c.get("path"), name=c.get("name"), size=psz,
                                   fstype=c.get("fstype") or "", label=c.get("label") or "",
                                   mps=mount_list(c), start=st))
            if st is not None:
                occ.append((st, st + psz))
        if d["pttype"] in ("gpt", "dos"):
            hi = (size - 34 * 512) // MIB * MIB
            cur = MIB
            for s, e in sorted(occ):
                a, b = -(-cur // MIB) * MIB, s // MIB * MIB
                if b - a >= 8 * MIB:
                    d["gaps"].append((a, b))
                cur = max(cur, e)
            a = -(-cur // MIB) * MIB
            if hi - a >= 8 * MIB:
                d["gaps"].append((a, hi))
        disks.append(d)
    return disks


def mounted_safe_to_unmount(mps):
    return all(m.startswith(SHOW_MP) for m in mps)


class DiskManager(Gtk.Window):
    def __init__(self, parent):
        super().__init__(title="Диски и разделы")
        self.set_transient_for(parent)
        self.set_destroy_with_parent(True)
        self.set_default_size(840, 540)
        self.set_decorated(False)
        self.owner = parent
        self.info = {}
        self.busy = False
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        bar.get_style_context().add_class("bar")
        title = Gtk.Label(label="Диски и разделы", xalign=0)
        bar.pack_start(title, True, True, 6)
        b_ref = Gtk.Button(label="Обновить")
        b_ref.connect("clicked", lambda *_: self.refresh())
        b_close = Gtk.Button(label="Закрыть")
        b_close.connect("clicked", lambda *_: self.destroy())
        bar.pack_start(b_ref, False, False, 0)
        bar.pack_start(b_close, False, False, 0)
        root.pack_start(bar, False, False, 0)
        # key, имя, метка/модель, файловая система, размер, состояние, цвет
        self.store = Gtk.TreeStore(str, str, str, str, str, str, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.get_selection().connect("changed", self.on_sel)
        for i, (name, w) in enumerate((("Устройство", 190), ("Метка / модель", 200), ("ФС", 80),
                                       ("Размер", 90), ("Состояние", 200))):
            r = Gtk.CellRendererText()
            r.set_property("ellipsize", Pango.EllipsizeMode.END)
            col = Gtk.TreeViewColumn(name, r, text=i + 1, foreground=6)
            col.set_min_width(w)
            col.set_resizable(True)
            self.view.append_column(col)
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.view)
        root.pack_start(scroll, True, True, 0)
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        btns.get_style_context().add_class("bar")
        self.b_create = self.add_btn(btns, "Создать раздел", self.create_dialog)
        self.b_fmt = self.add_btn(btns, "Форматировать…", self.format_dialog)
        self.b_label = self.add_btn(btns, "Метка…", self.label_dialog)
        self.b_del = self.add_btn(btns, "Удалить раздел", self.delete_part)
        self.b_mount = self.add_btn(btns, "Подключить", self.toggle_mount)
        self.b_table = self.add_btn(btns, "Создать таблицу GPT", self.make_table)
        root.pack_start(btns, False, False, 0)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        root.pack_start(self.status, False, False, 0)
        self.connect("key-press-event", lambda w, ev: self.destroy() or True
                     if Gdk.keyval_name(ev.keyval) == "Escape" else False)
        self.on_sel()
        self.say("Читаю список дисков…")
        self.refresh()

    def add_btn(self, box, text, cb):
        b = Gtk.Button(label=text)
        b.connect("clicked", lambda *_: cb())
        box.pack_start(b, False, False, 0)
        return b

    def say(self, text, err=False):
        ctx = self.status.get_style_context()
        if err:
            ctx.add_class("err")
        else:
            ctx.remove_class("err")
        self.status.set_text(text)
        return False

    # ---------- список ----------
    def refresh(self):
        def work():
            GLib.idle_add(self.fill, scan_disks())
        threading.Thread(target=work, daemon=True).start()
        return False

    def cur_key(self):
        model, it = self.view.get_selection().get_selected()
        return model[it][0] if it else None

    def fill(self, disks):
        keep = self.cur_key()
        self.store.clear()
        self.info = {}
        for d in disks:
            dkey = "d:" + d["path"]
            self.info[dkey] = dict(kind="disk", disk=d)
            if d["pttype"]:
                state = {"gpt": "GPT", "dos": "MBR"}.get(d["pttype"], d["pttype"])
            else:
                state = "нет таблицы разделов"
            if d["rm"]:
                state += "  ·  съёмный"
            top = self.store.append(None, [dkey, d["path"], d["model"], d["fstype"], human(d["size"]),
                                           state, "#e4ebe2"])
            items = [(p["start"] if p["start"] is not None else 0, "part", p) for p in d["parts"]]
            items += [(g[0], "free", g) for g in d["gaps"]]
            for _, kind, obj in sorted(items, key=lambda t: t[0]):
                if kind == "part":
                    key = "p:" + obj["path"]
                    self.info[key] = dict(kind="part", disk=d, p=obj)
                    if obj["mps"]:
                        st = "подключён: " + ", ".join(obj["mps"])
                    else:
                        st = "не подключён"
                    self.store.append(top, [key, obj["path"], obj["label"], obj["fstype"],
                                            human(obj["size"]), st, "#e4ebe2"])
                else:
                    key = f"f:{d['path']}:{obj[0]}"
                    self.info[key] = dict(kind="free", disk=d, gap=obj)
                    self.store.append(top, [key, "Свободное место", "", "", human(obj[1] - obj[0]),
                                            "", "#a9cc82"])
        self.view.expand_all()
        if keep:
            for row in self.iter_rows(self.store.get_iter_first()):
                if row[0] == keep:
                    self.view.get_selection().select_path(row.path)
                    break
        self.on_sel()
        if not self.busy:
            self.say(f"Дисков: {len(disks)}" if disks else "Диски не найдены")
        return False

    def iter_rows(self, it):
        while it:
            yield self.store[it]
            child = self.store.iter_children(it)
            for r in self.iter_rows(child):
                yield r
            it = self.store.iter_next(it)

    def on_sel(self, *_):
        k = self.info.get(self.cur_key())
        kind = k["kind"] if k else None
        part, free, disk = kind == "part", kind == "free", kind == "disk"
        p = k["p"] if part else None
        mounted = bool(p and p["mps"])
        has_fs = bool(p and p["fstype"] and p["fstype"] not in SKIP_FS)
        can_mount = bool(has_fs and (not mounted or mounted_safe_to_unmount(p["mps"])))
        d = k["disk"] if disk else None
        self.enable(self.b_create, free, "Выбери строку «Свободное место»")
        self.enable(self.b_fmt, part and not mounted,
                    "Выбери раздел" if not part else "Раздел подключён: сначала отключи его")
        self.enable(self.b_del, part and not mounted,
                    "Выбери раздел" if not part else "Раздел подключён: сначала отключи его")
        self.enable(self.b_label, has_fs, "Выбери раздел с файловой системой")
        self.enable(self.b_mount, can_mount,
                    "Выбери раздел с файловой системой" if not has_fs
                    else "Системный раздел (/, /boot, /home) отсюда не отключается")
        self.b_mount.set_label("Отключить" if mounted else "Подключить")
        self.enable(self.b_table, bool(d and not d["pttype"] and not d["mps"]),
                    "Выбери диск без таблицы разделов" if not disk
                    else "На диске уже есть таблица разделов или он подключён")

    def enable(self, btn, ok, why):
        btn.set_sensitive(bool(ok))
        btn.set_tooltip_text(None if ok else why)

    # ---------- операции ----------
    def run_op(self, text, fn):
        if self.busy:
            return
        self.busy = True
        self.say(text)

        def work():
            err = None
            try:
                fn()
            except GLib.Error as e:
                err = dbus_err(e)
            except Exception as e:
                err = err_text(e)
            GLib.idle_add(self.op_done, err)
        threading.Thread(target=work, daemon=True).start()

    def op_done(self, err):
        self.busy = False
        self.say(("Ошибка: " + err) if err else "Готово", bool(err))
        GLib.timeout_add(800, self.refresh)
        self.owner.refresh_devices()
        return False

    def grid_dialog(self, title, ok_text):
        dlg = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dlg.add_button("Отмена", Gtk.ResponseType.CANCEL)
        dlg.add_button(ok_text, Gtk.ResponseType.OK)
        grid = Gtk.Grid(column_spacing=14, row_spacing=8, margin=16)
        dlg.get_content_area().add(grid)
        return dlg, grid

    def fs_combo(self, with_empty):
        combo = Gtk.ComboBoxText()
        for key, title, tool in FS_TOOLS:
            if shutil.which(tool):
                combo.append(key, title)
        if with_empty:
            combo.append("empty", "Без файловой системы")
        combo.set_active(0)
        return combo

    def ask(self, text):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                buttons=Gtk.ButtonsType.YES_NO, text=text)
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.YES

    def create_dialog(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "free":
            return
        d, (s, e) = k["disk"], k["gap"]
        max_mib = (e - s) // MIB
        dlg, grid = self.grid_dialog("Новый раздел", "Создать")
        info = Gtk.Label(label=f"{d['path']}  ·  свободно {human(e - s)}", xalign=0)
        info.get_style_context().add_class("dim")
        spin = Gtk.SpinButton.new_with_range(1, max_mib, 1)
        spin.set_value(max_mib)
        combo = self.fs_combo(True)
        entry = Gtk.Entry()
        entry.set_placeholder_text("необязательно")
        grid.attach(info, 0, 0, 2, 1)
        for i, (t, w) in enumerate((("Размер, МиБ", spin), ("Файловая система", combo), ("Метка", entry))):
            lab = Gtk.Label(label=t, xalign=0)
            grid.attach(lab, 0, i + 1, 1, 1)
            grid.attach(w, 1, i + 1, 1, 1)
        dlg.show_all()
        resp = dlg.run()
        mib = int(spin.get_value())
        fs = combo.get_active_id() or "empty"
        label = entry.get_text().strip()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return
        size = (e - s) if mib >= max_mib else mib * MIB
        gpt = d["pttype"] == "gpt"
        if gpt:
            ptype = GPT_MSDATA if fs in ("vfat", "exfat", "ntfs") else GPT_LINUX
        else:
            ptype = {"vfat": "0x0c", "exfat": "0x07", "ntfs": "0x07"}.get(fs, "0x83")
        fopts = {}
        if label and fs != "empty":
            fopts["label"] = GLib.Variant("s", label)
        if fs in OWNER_FS:
            fopts["take-ownership"] = GLib.Variant("b", True)
        name = label[:30] if gpt else ""

        def go():
            path = block_path(d["path"])
            try:
                udisks_call(path, UDISKS + ".PartitionTable", "CreatePartitionAndFormat",
                            "(ttssa{sv}sa{sv})", (s, size, ptype, name, {}, fs, fopts))
            except GLib.Error as ex:
                if "type" not in dbus_err(ex).lower():
                    raise
                udisks_call(path, UDISKS + ".PartitionTable", "CreatePartitionAndFormat",
                            "(ttssa{sv}sa{sv})", (s, size, "", name, {}, fs, fopts))
        self.run_op("Создаю раздел…", go)

    def format_dialog(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "part" or k["p"]["mps"]:
            return
        p = k["p"]
        dlg, grid = self.grid_dialog("Форматирование", "Форматировать")
        info = Gtk.Label(label=f"{p['path']}  ·  {human(p['size'])}", xalign=0)
        info.get_style_context().add_class("dim")
        combo = self.fs_combo(False)
        entry = Gtk.Entry()
        entry.set_text(p["label"])
        grid.attach(info, 0, 0, 2, 1)
        grid.attach(Gtk.Label(label="Файловая система", xalign=0), 0, 1, 1, 1)
        grid.attach(combo, 1, 1, 1, 1)
        grid.attach(Gtk.Label(label="Метка", xalign=0), 0, 2, 1, 1)
        grid.attach(entry, 1, 2, 1, 1)
        dlg.show_all()
        resp = dlg.run()
        fs = combo.get_active_id()
        label = entry.get_text().strip()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK or not fs:
            return
        what = p["path"] + (f" «{p['label']}»" if p["label"] else "")
        if not self.ask(f"Форматировать {what} в {fs}?\nВсе данные на разделе будут удалены."):
            return
        fopts = {"update-partition-type": GLib.Variant("b", True)}
        if label:
            fopts["label"] = GLib.Variant("s", label)
        if fs in OWNER_FS:
            fopts["take-ownership"] = GLib.Variant("b", True)
        self.run_op("Форматирую…", lambda: udisks_call(block_path(p["path"]), UDISKS + ".Block", "Format",
                                                       "(sa{sv})", (fs, fopts)))

    def label_dialog(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "part":
            return
        p = k["p"]
        dlg, grid = self.grid_dialog("Метка раздела", "Сохранить")
        entry = Gtk.Entry()
        entry.set_text(p["label"])
        entry.set_activates_default(True)
        grid.attach(Gtk.Label(label=p["path"], xalign=0), 0, 0, 1, 1)
        grid.attach(entry, 1, 0, 1, 1)
        dlg.set_default_response(Gtk.ResponseType.OK)
        dlg.show_all()
        resp = dlg.run()
        label = entry.get_text().strip()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK:
            return
        self.run_op("Меняю метку…", lambda: udisks_call(block_path(p["path"]), UDISKS + ".Filesystem",
                                                        "SetLabel", "(sa{sv})", (label, {})))

    def delete_part(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "part" or k["p"]["mps"]:
            return
        p = k["p"]
        what = p["path"] + (f" «{p['label']}»" if p["label"] else "") + f", {human(p['size'])}"
        if not self.ask(f"Удалить раздел {what}?\nВсе данные в нём будут потеряны."):
            return
        self.run_op("Удаляю раздел…", lambda: udisks_call(block_path(p["path"]), UDISKS + ".Partition",
                                                          "Delete", "(a{sv})", ({},)))

    def toggle_mount(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "part":
            return
        p = k["p"]
        method = "Unmount" if p["mps"] else "Mount"
        self.run_op("Подождите…", lambda: udisks_call(block_path(p["path"]), UDISKS + ".Filesystem",
                                                      method, "(a{sv})", ({},)))

    def make_table(self):
        k = self.info.get(self.cur_key())
        if not k or k["kind"] != "disk":
            return
        d = k["disk"]
        if d["pttype"] or d["mps"]:
            return
        what = d["path"] + (f" ({d['model']})" if d["model"] else "") + f", {human(d['size'])}"
        extra = f"\nСейчас на нём файловая система {d['fstype']} - она будет стёрта." if d["fstype"] else ""
        if not self.ask(f"Создать новую таблицу разделов GPT на {what}?{extra}"):
            return
        self.run_op("Создаю таблицу разделов…", lambda: udisks_call(block_path(d["path"]), UDISKS + ".Block",
                                                                     "Format", "(sa{sv})", ("gpt", {})))


class Item:
    __slots__ = ("name", "path", "isdir", "size", "mtime", "icon")

    def __init__(self, name, path, isdir, size, mtime, icon):
        self.name, self.path, self.isdir, self.size, self.mtime, self.icon = name, path, isdir, size, mtime, icon


class FilesWindow(Gtk.Window):
    def __init__(self, start, select=None):
        super().__init__(title="Files")
        self.set_default_size(1040, 660)
        self.set_decorated(False)
        self.cwd = None
        self.hist, self.fwd = [], []
        self.hidden = False
        self.sort = ("name", False)
        self.clip = ([], False)
        self.devs = []
        self.marks = load_marks()
        self.sizes = {}
        self.items = []
        self.ftext = ""
        self.drag_paths = []
        self.drag_xy = (0, 0)
        self.scroll_id = 0
        self.disk_win = None
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.apply_css(screen)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        bar.get_style_context().add_class("bar")
        self.b_back = self.icon_button("go-previous-symbolic", self.go_back)
        self.b_fwd = self.icon_button("go-next-symbolic", self.go_forward)
        self.b_up = self.icon_button("go-up-symbolic", self.go_up)
        self.entry = Gtk.Entry()
        self.entry.set_hexpand(True)
        self.entry.connect("activate", self.on_entry)
        self.filter = Gtk.Entry()
        self.filter.set_placeholder_text("Фильтр (Ctrl+F)")
        self.filter.set_width_chars(16)
        self.filter_id = self.filter.connect("changed", self.on_filter)
        self.filter.connect("activate", lambda *_: self.view.grab_focus())
        self.b_new = self.icon_button("folder-new-symbolic", lambda *_: self.new_folder())
        self.b_new.set_tooltip_text("Новая папка (Ctrl+Shift+N)")
        self.b_newf = self.icon_button("document-new-symbolic", lambda *_: self.new_file())
        self.b_newf.set_tooltip_text("Новый файл")
        self.b_hidden = Gtk.ToggleButton()
        self.b_hidden.add(Gtk.Image.new_from_icon_name("view-reveal-symbolic", Gtk.IconSize.BUTTON))
        self.b_hidden.set_tooltip_text("Скрытые файлы (Ctrl+H)")
        self.b_hidden.connect("toggled", self.on_hidden_toggled)
        for w in (self.b_back, self.b_fwd, self.b_up):
            bar.pack_start(w, False, False, 0)
        bar.pack_start(self.entry, True, True, 0)
        bar.pack_start(self.filter, False, False, 0)
        bar.pack_start(self.b_new, False, False, 0)
        bar.pack_start(self.b_newf, False, False, 0)
        bar.pack_start(self.b_hidden, False, False, 0)
        root.pack_start(bar, False, False, 0)
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        root.pack_start(paned, True, True, 0)
        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("side")
        self.side.connect("row-activated", self.on_side_activated)
        self.side.connect("button-press-event", self.on_side_click)
        self.side.drag_dest_set(Gtk.DestDefaults.DROP, DND, ACT_COPY | ACT_MOVE)
        self.side.connect("drag-motion", self.on_side_motion)
        self.side.connect("drag-leave", self.on_side_leave)
        self.side.connect("drag-data-received", self.on_side_received)
        side_scroll = Gtk.ScrolledWindow()
        side_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        side_scroll.add(self.side)
        side_scroll.set_size_request(190, -1)
        paned.pack1(side_scroll, False, False)
        self.build_side()
        self.store = Gtk.ListStore(Gio.Icon, str, str, str, bool, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.set_enable_search(True)
        self.view.set_search_column(1)
        self.view.set_rubber_banding(True)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        self.view.connect("row-activated", self.on_row_activated)
        self.view.connect("button-press-event", self.on_view_click)
        self.view.enable_model_drag_source(Gdk.ModifierType.BUTTON1_MASK, DND, ACT_COPY | ACT_MOVE)
        self.view.drag_dest_set(Gtk.DestDefaults.DROP, DND, ACT_COPY | ACT_MOVE)
        self.view.connect_after("drag-begin", self.on_drag_begin)
        self.view.connect("drag-end", self.on_drag_end)
        self.view.connect("drag-data-get", self.on_drag_get)
        self.view.connect("drag-data-delete", self.on_drag_delete)
        self.view.connect("drag-motion", self.on_view_motion)
        self.view.connect("drag-leave", self.on_view_leave)
        self.view.connect("drag-data-received", self.on_view_received)
        self.name_col = Gtk.TreeViewColumn("Имя")
        self.name_col.set_expand(True)
        self.name_col.set_resizable(True)
        pix = Gtk.CellRendererPixbuf()
        pix.set_property("stock-size", int(Gtk.IconSize.LARGE_TOOLBAR))
        pix.set_property("xpad", 6)
        pix.set_property("ypad", 3)
        self.name_r = Gtk.CellRendererText()
        self.name_r.set_property("ellipsize", Pango.EllipsizeMode.END)
        self.name_r.connect("edited", self.on_edited)
        self.name_r.connect("editing-started", self.on_edit_started)
        self.name_r.connect("editing-canceled", lambda *_: self.name_r.set_property("editable", False))
        self.name_col.pack_start(pix, False)
        self.name_col.pack_start(self.name_r, True)
        self.name_col.add_attribute(pix, "gicon", 0)
        self.name_col.add_attribute(self.name_r, "text", 1)
        self.name_col.set_clickable(True)
        self.name_col.connect("clicked", self.on_header, "name")
        self.view.append_column(self.name_col)
        self.size_col = self.text_column("Размер", 2, "size")
        self.date_col = self.text_column("Изменён", 3, "date")
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.view)
        paned.pack2(scroll, True, False)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        root.pack_start(self.status, False, False, 0)
        # подключаем после создания строки статуса
        self.view.get_selection().connect("changed", self.update_status)
        self.connect("key-press-event", self.on_key)
        self.connect("notify::is-active", lambda *_: self.refresh_devices())
        GLib.timeout_add_seconds(20, self.on_timer)
        self.load(start, push=False, select=select)
        self.refresh_devices()
        self.view.grab_focus()

    def apply_css(self, screen):
        for rule in re.findall(rb"[^{}]+\{[^{}]*\}", CSS):
            prov = Gtk.CssProvider()
            try:
                prov.load_from_data(rule)
            except GLib.Error:
                continue
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def icon_button(self, icon, cb):
        b = Gtk.Button()
        b.add(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        b.connect("clicked", cb)
        return b

    def text_column(self, title, idx, key):
        r = Gtk.CellRendererText()
        r.set_property("xalign", 1.0)
        r.set_property("foreground", "#a8b8a0")
        col = Gtk.TreeViewColumn(title, r, text=idx)
        col.set_min_width(110)
        col.set_clickable(True)
        col.connect("clicked", self.on_header, key)
        self.view.append_column(col)
        return col

    # ---------- боковая панель ----------
    def side_row(self, icon, text, data):
        row = Gtk.ListBoxRow()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        box.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU), False, False, 0)
        lab = Gtk.Label(label=text, xalign=0)
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(lab, True, True, 0)
        row.add(box)
        row.fm_data = data
        return row

    def side_section(self, text):
        row = Gtk.ListBoxRow()
        row.set_selectable(False)
        row.set_activatable(False)
        lab = Gtk.Label(label=text, xalign=0)
        lab.get_style_context().add_class("sect")
        row.add(lab)
        return row

    def build_side(self):
        for r in self.side.get_children():
            self.side.remove(r)
        self.side.add(self.side_section("МЕСТА"))
        for icon, name, path in PLACES:
            if os.path.isdir(path):
                self.side.add(self.side_row(icon, name, ("dir", path)))
        self.side.add(self.side_row("user-trash-symbolic", "Корзина", ("dir", TRASH_FILES)))
        if self.marks:
            self.side.add(self.side_section("ЗАКЛАДКИ"))
            for p in self.marks:
                self.side.add(self.side_row("folder-symbolic", os.path.basename(p) or p, ("mark", p)))
        self.side.add(self.side_section("ДИСКИ"))
        for d in self.devs:
            self.side.add(self.dev_row(d))
        self.side.add(self.side_row("drive-harddisk-symbolic", "Управление дисками…", ("disks", None)))
        self.side.show_all()
        self.sync_side()

    def dev_row(self, d):
        row = Gtk.ListBoxRow()
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        icon = "drive-removable-media-symbolic" if d["rm"] else "drive-harddisk-symbolic"
        top.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU), False, False, 0)
        lab = Gtk.Label(label=d["title"], xalign=0)
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        top.pack_start(lab, True, True, 0)
        outer.pack_start(top, False, False, 0)
        usage = None
        if d["mp"]:
            try:
                usage = shutil.disk_usage(d["mp"])
            except OSError:
                usage = None
        sub = Gtk.Label(xalign=0)
        sub.get_style_context().add_class("sub")
        sub.set_margin_start(26)
        if usage and usage.total:
            sub.set_text(f"{human(usage.free)} свободно из {human(usage.total)}")
            frac = max(0.0, min(1.0, 1 - usage.free / usage.total))
            bar = Gtk.LevelBar()
            bar.set_min_value(0)
            bar.set_max_value(1)
            for off in ("low", "high", "full"):
                bar.remove_offset_value(off)
            bar.set_value(frac)
            bar.get_style_context().add_class("crit" if frac >= 0.9 else ("warn" if frac >= 0.75 else "ok"))
            bar.set_margin_start(26)
            bar.set_margin_bottom(2)
            outer.pack_start(sub, False, False, 0)
            outer.pack_start(bar, False, False, 0)
        else:
            sub.set_text(f"{human(d['size'])}  ·  не подключён")
            outer.pack_start(sub, False, False, 0)
        row.add(outer)
        row.fm_data = ("dev", d)
        row.set_tooltip_text(f"{d['path']}  ·  {d['fstype']}" + (f"\n{d['mp']}" if d["mp"] else ""))
        return row

    def sync_side(self):
        self.side.unselect_all()
        if not self.cwd:
            return
        for row in self.side.get_children():
            data = getattr(row, "fm_data", None)
            if data and data[0] in ("dir", "mark") and os.path.realpath(data[1]) == self.cwd:
                self.side.select_row(row)
                return
        best, best_len = None, -1
        for row in self.side.get_children():
            data = getattr(row, "fm_data", None)
            if data and data[0] == "dev" and data[1]["mp"]:
                mp = data[1]["mp"]
                if (self.cwd == mp or self.cwd.startswith(mp.rstrip("/") + "/")) and len(mp) > best_len:
                    best, best_len = row, len(mp)
        if best is not None:
            self.side.select_row(best)

    def open_disk_manager(self):
        if self.disk_win is not None:
            try:
                self.disk_win.present()
                return
            except Exception:
                self.disk_win = None
        self.disk_win = DiskManager(self)
        self.disk_win.connect("destroy", lambda *_: setattr(self, "disk_win", None))
        self.disk_win.show_all()

    def eject(self, d):
        def work():
            if d["mp"]:
                r = subprocess.run(["udisksctl", "unmount", "-b", d["path"]], capture_output=True, text=True)
                if r.returncode != 0:
                    GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось отключить").splitlines()[0], True)
                    return
            drive = "/dev/" + (d["pk"] or os.path.basename(d["path"]))
            r = subprocess.run(["udisksctl", "power-off", "-b", drive], capture_output=True, text=True)
            if r.returncode == 0:
                GLib.idle_add(self.say, "Можно доставать: " + d["title"], False)
                if self.cwd and d["mp"] and self.cwd.startswith(d["mp"]):
                    GLib.idle_add(self.load, HOME)
            else:
                GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось извлечь").splitlines()[0], True)
            GLib.idle_add(self.refresh_devices)
        threading.Thread(target=work, daemon=True).start()

    def disk_props(self, d):
        dlg = Gtk.Dialog(title="Свойства диска", transient_for=self, modal=True)
        dlg.add_button("Закрыть", Gtk.ResponseType.CLOSE)
        grid = Gtk.Grid(column_spacing=16, row_spacing=6, margin=16)
        dlg.get_content_area().add(grid)
        rows = [("Название", d["title"]), ("Устройство", d["path"]), ("Файловая система", d["fstype"]),
                ("Размер", human(d["size"]))]
        if d["label"]:
            rows.insert(1, ("Метка", d["label"]))
        if d["uuid"]:
            rows.append(("UUID", d["uuid"]))
        if d["mp"]:
            rows.append(("Подключён в", d["mp"]))
            try:
                u = shutil.disk_usage(d["mp"])
                rows.append(("Занято", f"{human(u.total - u.free)} из {human(u.total)}"))
                rows.append(("Свободно", human(u.free)))
            except OSError:
                pass
        else:
            rows.append(("Состояние", "не подключён"))
        for i, (k, v) in enumerate(rows):
            kl = Gtk.Label(label=k, xalign=0)
            kl.get_style_context().add_class("dim")
            vl = Gtk.Label(label=v, xalign=0)
            vl.set_selectable(True)
            grid.attach(kl, 0, i, 1, 1)
            grid.attach(vl, 1, i, 1, 1)
        dlg.show_all()
        dlg.run()
        dlg.destroy()

    def refresh_devices(self):
        threading.Thread(target=lambda: GLib.idle_add(self.show_devices, list_devices()), daemon=True).start()

    def on_timer(self):
        if self.is_active():
            self.refresh_devices()
        return True

    def show_devices(self, devs):
        if devs != self.devs:
            self.devs = devs
            self.build_side()
        return False

    def mount_and_open(self, d):
        def work():
            if d["mp"]:
                GLib.idle_add(self.load, d["mp"])
                return
            r = subprocess.run(["udisksctl", "mount", "-b", d["path"]], capture_output=True, text=True)
            m = re.search(r" at (.+?)\.?\s*$", r.stdout.strip())
            if r.returncode == 0 and m:
                GLib.idle_add(self.load, m.group(1))
                GLib.idle_add(self.refresh_devices)
            else:
                GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось подключить").splitlines()[0], True)
        threading.Thread(target=work, daemon=True).start()

    def unmount(self, d):
        def work():
            r = subprocess.run(["udisksctl", "unmount", "-b", d["path"]], capture_output=True, text=True)
            if r.returncode == 0:
                GLib.idle_add(self.say, "Отключено: " + d["label"], False)
                if self.cwd and d["mp"] and self.cwd.startswith(d["mp"]):
                    GLib.idle_add(self.load, HOME)
                GLib.idle_add(self.refresh_devices)
            else:
                GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось отключить").splitlines()[0], True)
        threading.Thread(target=work, daemon=True).start()

    def on_side_activated(self, box, row):
        data = getattr(row, "fm_data", None)
        if not data:
            return
        kind, val = data
        if kind == "disks":
            self.open_disk_manager()
            return
        if kind == "dev":
            self.mount_and_open(val)
            return
        if val == TRASH_FILES:
            os.makedirs(val, exist_ok=True)
        if os.path.isdir(val):
            self.load(val)
        else:
            self.say("Папка недоступна: " + val, True)

    def on_side_click(self, box, ev):
        if ev.button != 3:
            return False
        row = box.get_row_at_y(int(ev.y))
        data = getattr(row, "fm_data", None) if row else None
        if not data:
            return False
        kind, val = data
        menu = Gtk.Menu()

        def add(label, cb):
            it = Gtk.MenuItem(label=label)
            it.connect("activate", lambda *_: cb())
            menu.append(it)
        if kind == "dev":
            if val["mp"]:
                add("Открыть", lambda: self.mount_and_open(val))
                if mounted_safe_to_unmount([val["mp"]]):
                    add("Отключить", lambda: self.unmount(val))
            else:
                add("Подключить", lambda: self.mount_and_open(val))
            if val["rm"]:
                add("Безопасно извлечь", lambda: self.eject(val))
            menu.append(Gtk.SeparatorMenuItem())
            add("Свойства диска", lambda: self.disk_props(val))
            add("Управление дисками…", self.open_disk_manager)
        elif kind == "mark":
            add("Убрать из закладок", lambda: self.toggle_mark(val))
        elif val == TRASH_FILES:
            add("Очистить корзину", self.empty_trash_ask)
        else:
            return False
        menu.show_all()
        menu.popup_at_pointer(ev)
        return True

    # ---------- перетаскивание ----------
    def on_drag_begin(self, view, ctx):
        self.drag_paths = self.selected_paths()
        self.set_drag_icon(ctx)

    def set_drag_icon(self, ctx):
        # за курсором едет только значок файла, а не вся строка списка
        size = 48
        try:
            theme = Gtk.IconTheme.get_default()
            pb = None
            if self.drag_paths:
                info = Gio.File.new_for_path(self.drag_paths[0]).query_info(
                    "standard::icon", Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, None)
                gicon = info.get_icon()
                if gicon is not None:
                    ii = theme.lookup_by_gicon(gicon, size, Gtk.IconLookupFlags.FORCE_SIZE)
                    if ii is not None:
                        pb = ii.load_icon()
            if pb is None:
                pb = theme.load_icon("text-x-generic", size, Gtk.IconLookupFlags.FORCE_SIZE)
        except Exception:
            return
        n = len(self.drag_paths)
        if n > 1:
            try:
                import cairo
                surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size + 14, size + 14)
                cr = cairo.Context(surf)
                Gdk.cairo_set_source_pixbuf(cr, pb, 0, 14)
                cr.paint()
                cr.set_source_rgb(0.66, 0.80, 0.51)
                cr.arc(size - 4, 11, 11, 0, 6.2832)
                cr.fill()
                cr.set_source_rgb(0.06, 0.08, 0.06)
                cr.select_font_face("DejaVu Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
                cr.set_font_size(12)
                txt = str(n) if n < 100 else "99+"
                ext = cr.text_extents(txt)
                cr.move_to(size - 4 - ext.width / 2 - ext.x_bearing, 11 - ext.height / 2 - ext.y_bearing)
                cr.show_text(txt)
                surf.set_device_offset(-(size // 2), -(size // 2))
                Gtk.drag_set_icon_surface(ctx, surf)
                return
            except Exception:
                pass
        Gtk.drag_set_icon_pixbuf(ctx, pb, size // 2, size // 2)

    def on_drag_end(self, view, ctx):
        self.drag_paths = []
        self.stop_scroll()
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)

    def on_drag_get(self, view, ctx, data, info, t):
        paths = self.drag_paths or self.selected_paths()
        data.set_uris([Gio.File.new_for_path(p).get_uri() for p in paths])

    def on_drag_delete(self, view, ctx):
        # файлы переносим сами, строки из списка удалять не нужно
        view.stop_emission_by_name("drag-data-delete")

    def copy_wanted(self):
        if not self.drag_paths:
            return True
        try:
            seat = Gdk.Display.get_default().get_default_seat()
            _, _, _, mask = self.get_window().get_device_position(seat.get_pointer())
            return bool(mask & Gdk.ModifierType.CONTROL_MASK)
        except Exception:
            return False

    def can_drop(self, dest, copy):
        if not dest:
            return False
        paths = self.drag_paths
        if in_trash(dest):
            return bool(paths) and not all(in_trash(p) for p in paths)
        if not os.access(dest, os.W_OK | os.X_OK):
            return False
        rd = os.path.realpath(dest)
        for p in paths:
            rp = os.path.realpath(p)
            if rd == rp or rd.startswith(rp + os.sep):
                return False
        if paths and not copy and all(os.path.realpath(os.path.dirname(p)) == rd for p in paths):
            return False
        return True

    def pick_action(self, ctx, copy):
        want = ACT_COPY if copy else ACT_MOVE
        if ctx.get_actions() & want:
            return want
        return ctx.get_suggested_action() & (ACT_COPY | ACT_MOVE)

    def view_dest(self, view, x, y):
        hit = view.get_dest_row_at_pos(x, y)
        if hit:
            path = hit[0]
            row = self.store[path]
            if row[4] and row[5] not in self.drag_paths:
                return row[5], path
        return self.cwd, None

    def on_view_motion(self, view, ctx, x, y, t):
        dest, path = self.view_dest(view, x, y)
        copy = self.copy_wanted()
        ok = self.can_drop(dest, copy)
        view.set_drag_dest_row(path if ok else None, Gtk.TreeViewDropPosition.INTO_OR_AFTER)
        drag_status(ctx, self.pick_action(ctx, copy) if ok else 0, t)
        self.drag_xy = (x, y)
        self.start_scroll()
        return True

    def on_view_leave(self, view, ctx, t):
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)
        self.stop_scroll()

    def on_view_received(self, view, ctx, x, y, data, info, t):
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)
        self.stop_scroll()
        dest, _ = self.view_dest(view, x, y)
        self.do_drop(uris_to_paths(data), dest, ctx.get_selected_action())

    def side_dest(self, y):
        row = self.side.get_row_at_y(int(y))
        data = getattr(row, "fm_data", None) if row else None
        if not data:
            return None, None
        kind, val = data
        if kind == "dev":
            return (val["mp"], row) if val["mp"] else (None, None)
        if val == TRASH_FILES or os.path.isdir(val):
            return val, row
        return None, None

    def on_side_motion(self, box, ctx, x, y, t):
        dest, row = self.side_dest(y)
        copy = self.copy_wanted()
        ok = self.can_drop(dest, copy)
        if ok and row:
            box.drag_highlight_row(row)
        else:
            box.drag_unhighlight_row()
        drag_status(ctx, self.pick_action(ctx, copy) if ok else 0, t)
        return True

    def on_side_leave(self, box, ctx, t):
        box.drag_unhighlight_row()

    def on_side_received(self, box, ctx, x, y, data, info, t):
        box.drag_unhighlight_row()
        dest, _ = self.side_dest(y)
        self.do_drop(uris_to_paths(data), dest, ctx.get_selected_action())

    def do_drop(self, paths, dest, action):
        if not paths or not dest:
            return
        copy = bool(action & ACT_COPY)
        if not self.can_drop(dest, copy) and self.drag_paths:
            return
        if not in_trash(dest) and not os.access(dest, os.W_OK | os.X_OK):
            self.say("Нет прав на запись: " + dest, True)
            return
        self.run_transfer(paths, dest, not copy)

    def start_scroll(self):
        if not self.scroll_id:
            self.scroll_id = GLib.timeout_add(60, self.autoscroll)

    def stop_scroll(self):
        if self.scroll_id:
            GLib.source_remove(self.scroll_id)
            self.scroll_id = 0

    def autoscroll(self):
        adj = self.view.get_vadjustment()
        y = self.drag_xy[1]
        h = self.view.get_allocated_height()
        step = -18 if y < 45 else (18 if y > h - 35 else 0)
        if step:
            top = max(adj.get_lower(), adj.get_upper() - adj.get_page_size())
            adj.set_value(max(adj.get_lower(), min(top, adj.get_value() + step)))
        return True

    # ---------- чтение папки ----------
    def say(self, text, err=False):
        ctx = self.status.get_style_context()
        if err:
            ctx.add_class("err")
        else:
            ctx.remove_class("err")
        self.status.set_text(text)
        return False

    def read_dir(self, path):
        attrs = ("standard::name,standard::type,standard::size,standard::symbolic-icon,"
                 "standard::icon,time::modified")
        items = []
        en = Gio.File.new_for_path(path).enumerate_children(attrs, Gio.FileQueryInfoFlags.NONE, None)
        while True:
            info = en.next_file(None)
            if info is None:
                break
            name = info.get_name()
            if not self.hidden and name.startswith("."):
                continue
            icon = info.get_symbolic_icon() or info.get_icon()
            items.append(Item(name, os.path.join(path, name),
                              info.get_file_type() == Gio.FileType.DIRECTORY,
                              info.get_size(), info.get_attribute_uint64("time::modified"), icon))
        en.close(None)
        return items

    def sort_items(self, items):
        key, rev = self.sort
        if key == "size":
            kf = lambda i: (i.size, i.name.lower())
        elif key == "date":
            kf = lambda i: (i.mtime, i.name.lower())
        else:
            kf = lambda i: i.name.lower()
        dirs = sorted([i for i in items if i.isdir], key=kf, reverse=rev)
        files = sorted([i for i in items if not i.isdir], key=kf, reverse=rev)
        return dirs + files

    def fill(self):
        q = self.ftext.lower()
        items = [i for i in self.items if q in i.name.lower()] if q else self.items
        self.sizes = {i.path: i.size for i in items if not i.isdir}
        self.store.clear()
        for it in self.sort_items(items):
            self.store.append([it.icon, it.name, "" if it.isdir else human(it.size),
                               time.strftime("%d.%m.%Y %H:%M", time.localtime(it.mtime)), it.isdir, it.path])

    def on_filter(self, entry):
        self.ftext = entry.get_text().strip()
        self.fill()
        self.update_status()

    def load(self, path, push=True, select=None):
        path = os.path.realpath(os.path.expanduser(path))
        try:
            items = self.read_dir(path)
        except GLib.Error as e:
            self.say(f"Нет доступа: {path} ({e.message})", True)
            return False
        if push and self.cwd and self.cwd != path:
            self.hist.append(self.cwd)
            self.fwd = []
        if self.ftext and path != self.cwd:
            self.ftext = ""
            self.filter.handler_block(self.filter_id)
            self.filter.set_text("")
            self.filter.handler_unblock(self.filter_id)
        self.cwd = path
        self.items = items
        self.fill()
        shown = path.replace(HOME, "~", 1) if path.startswith(HOME) else path
        self.entry.set_text(shown)
        self.set_title(os.path.basename(path) or "/")
        self.b_back.set_sensitive(bool(self.hist))
        self.b_fwd.set_sensitive(bool(self.fwd))
        self.b_up.set_sensitive(path != "/")
        self.sync_side()
        if select:
            self.select_name(select)
        self.update_status()
        self.view.grab_focus()
        return False

    def reload(self, select=None):
        self.load(self.cwd, push=False, select=select)
        self.build_side()

    def select_name(self, name):
        for row in self.store:
            if row[1] == name:
                sel = self.view.get_selection()
                sel.unselect_all()
                sel.select_path(row.path)
                self.view.scroll_to_cell(row.path, None, False, 0, 0)
                self.view.set_cursor(row.path)
                return

    def update_status(self, *_):
        rows = self.selected_rows()
        total = len(self.store)
        try:
            free = "  ·  свободно " + human(shutil.disk_usage(self.cwd).free)
        except (OSError, TypeError):
            free = ""
        if rows:
            total_size = sum(int(self.sizes.get(self.store[r][5], 0)) for r in rows)
            text = f"Выбрано: {len(rows)} из {total}"
            if total_size:
                text += f"  ·  {human(total_size)}"
        elif self.ftext:
            text = f"Найдено: {total} из {len(self.items)}"
        else:
            text = f"{total} элементов" if total else "Папка пуста"
        self.say(text + free)

    def go_back(self, *_):
        if self.hist:
            self.fwd.append(self.cwd)
            self.load(self.hist.pop(), push=False)

    def go_forward(self, *_):
        if self.fwd:
            self.hist.append(self.cwd)
            self.load(self.fwd.pop(), push=False)

    def go_up(self, *_):
        parent = os.path.dirname(self.cwd)
        if parent != self.cwd:
            self.load(parent, select=os.path.basename(self.cwd))

    def on_entry(self, entry):
        p = os.path.expanduser(entry.get_text().strip())
        if os.path.isdir(p):
            self.load(p)
        elif os.path.exists(p):
            self.load(os.path.dirname(p), select=os.path.basename(p))
        else:
            self.say("Нет такого пути: " + p, True)
        self.view.grab_focus()

    def on_hidden_toggled(self, btn):
        self.hidden = btn.get_active()
        self.reload()

    def on_header(self, col, key):
        k, rev = self.sort
        self.sort = (key, (not rev) if k == key else False)
        for c, kk in ((self.name_col, "name"), (self.size_col, "size"), (self.date_col, "date")):
            c.set_sort_indicator(kk == self.sort[0])
            c.set_sort_order(Gtk.SortType.DESCENDING if self.sort[1] else Gtk.SortType.ASCENDING)
        self.reload()

    def on_row_activated(self, view, path, col):
        row = self.store[path]
        if row[4]:
            self.load(row[5])
        else:
            self.open_path(row[5])

    def open_path(self, path):
        if path.lower().endswith((".pkg.tar.zst", ".pkg.tar.xz")) and shutil.which("pkg-install"):
            subprocess.Popen(["pkg-install", path], start_new_session=True)
            self.say("Устанавливаю: " + os.path.basename(path))
            return
        ok = False
        try:
            ok = Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
        except GLib.Error:
            ok = False
        if ok:
            return
        ctype, _ = Gio.content_type_guess(path, None)
        try:
            if Gio.content_type_is_a(ctype, "text/plain") and shutil.which("nano"):
                subprocess.Popen(["alacritty", "-e", "nano", path], start_new_session=True)
            else:
                subprocess.Popen(["firefox", path], start_new_session=True)
        except Exception as e:
            self.say(f"Нечем открыть ({ctype}): {e}", True)

    # ---------- операции с файлами ----------
    def selected_rows(self):
        _, rows = self.view.get_selection().get_selected_rows()
        return rows

    def selected_paths(self):
        return [self.store[r][5] for r in self.selected_rows()]

    def confirm(self, text):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                buttons=Gtk.ButtonsType.YES_NO, text=text)
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.YES

    def copy(self, cut=False):
        paths = self.selected_paths()
        if paths:
            self.clip = (paths, cut)
            self.say(("Вырезано: " if cut else "Скопировано: ") + str(len(paths)))

    def paste(self):
        paths, cut = self.clip
        if not paths:
            self.say("Буфер пуст")
        elif in_trash(self.cwd):
            self.say("В корзину удаляют клавишей Delete", True)
        else:
            self.run_transfer(paths, self.cwd, cut, clear_clip=cut)

    def run_transfer(self, paths, dest, move, clear_clip=False):
        self.say("Перемещаю…" if move else "Копирую…")

        def work():
            done, errs = transfer(paths, dest, move)
            GLib.idle_add(self.after_transfer, done, move, errs, clear_clip)
        threading.Thread(target=work, daemon=True).start()

    def after_transfer(self, done, move, errs, clear_clip):
        if clear_clip:
            self.clip = ([], False)
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0] + (f"  (и ещё {len(errs) - 1})" if len(errs) > 1 else ""), True)
        elif done:
            self.say(("Перемещено: " if move else "Скопировано: ") + str(done))
        return False

    def trash(self, force=False):
        paths = self.selected_paths()
        if not paths:
            return
        perm = force or in_trash(self.cwd)
        if perm and not self.confirm(f"Удалить навсегда ({len(paths)})?"):
            return
        errs = []
        for p in paths:
            try:
                if perm:
                    remove_path(p)
                    drop_trashinfo(p)
                else:
                    Gio.File.new_for_path(p).trash(None)
            except Exception as e:
                errs.append(err_text(e))
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)

    def restore_selected(self):
        n, errs = 0, []
        for p in self.selected_paths():
            try:
                restore(p)
                n += 1
            except Exception as e:
                errs.append(err_text(e))
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)
        elif n:
            self.say("Восстановлено: " + str(n))

    def empty_trash_ask(self):
        if not self.confirm("Очистить корзину насовсем?"):
            return

        def work():
            errs = empty_trash()
            GLib.idle_add(self.after_empty, errs)
        self.say("Чищу корзину…")
        threading.Thread(target=work, daemon=True).start()

    def after_empty(self, errs):
        if self.cwd and in_trash(self.cwd):
            self.reload()
        self.say("Ошибка: " + errs[0] if errs else "Корзина пуста", bool(errs))
        return False

    def start_rename(self):
        rows = self.selected_rows()
        if len(rows) != 1 or in_trash(self.cwd):
            return
        self.name_r.set_property("editable", True)
        self.view.set_cursor(rows[0], self.name_col, True)

    def on_edit_started(self, renderer, editable, path):
        try:
            row = self.store[path]
            n = stem_len(row[1], row[4])
        except Exception:
            return
        if not isinstance(editable, Gtk.Entry):
            return

        def sel():
            if editable.get_mapped():
                editable.select_region(0, n)
            return False
        GLib.idle_add(sel)
        GLib.timeout_add(60, sel)

    def on_edited(self, renderer, path, text):
        renderer.set_property("editable", False)
        old = self.store[path][1]
        text = text.strip()
        if not text or text == old or "/" in text:
            return
        new = os.path.join(self.cwd, text)
        if os.path.lexists(new) and text.lower() != old.lower():
            self.say("Уже есть такое имя: " + text, True)
            return
        try:
            os.rename(os.path.join(self.cwd, old), new)
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=text)

    def new_folder(self):
        if in_trash(self.cwd):
            return
        path = unique(self.cwd, "Новая папка")
        try:
            os.mkdir(path)
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=os.path.basename(path))
        self.start_rename()

    def new_file(self):
        if in_trash(self.cwd):
            return
        path = unique(self.cwd, "Новый файл.txt")
        try:
            open(path, "x").close()
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=os.path.basename(path))
        self.start_rename()

    def copy_path(self):
        text = "\n".join(self.selected_paths() or [self.cwd])
        try:
            subprocess.run(["wl-copy"], input=text.encode(), check=True, timeout=3)
        except Exception:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
        self.say("Путь скопирован")

    def open_terminal(self, path=None):
        path = path if path and os.path.isdir(path) else self.cwd
        try:
            subprocess.Popen(["alacritty", "--working-directory", path], start_new_session=True)
        except OSError as e:
            self.say("Не запустился alacritty: " + str(e), True)

    def toggle_mark(self, path):
        path = os.path.realpath(path)
        if path in self.marks:
            self.marks.remove(path)
        else:
            self.marks.append(path)
        save_marks(self.marks)
        self.build_side()

    def select_all(self):
        self.view.get_selection().select_all()

    def properties(self):
        paths = self.selected_paths() or [self.cwd]
        dlg = Gtk.Dialog(title="Свойства", transient_for=self, modal=True)
        dlg.add_button("Закрыть", Gtk.ResponseType.CLOSE)
        grid = Gtk.Grid(column_spacing=16, row_spacing=6, margin=16)
        dlg.get_content_area().add(grid)
        state = {"row": 0}

        def add(title, text):
            k = Gtk.Label(label=title, xalign=0)
            k.get_style_context().add_class("dim")
            v = Gtk.Label(label=text, xalign=0)
            v.set_selectable(True)
            v.set_line_wrap(True)
            v.set_max_width_chars(48)
            grid.attach(k, 0, state["row"], 1, 1)
            grid.attach(v, 1, state["row"], 1, 1)
            state["row"] += 1
            return v
        if len(paths) == 1:
            p = paths[0]
            try:
                st = os.lstat(p)
            except OSError as e:
                dlg.destroy()
                self.say("Ошибка: " + (e.strerror or str(e)), True)
                return
            add("Имя", os.path.basename(p) or "/")
            if stat.S_ISLNK(st.st_mode):
                kind = "Ссылка → " + os.readlink(p)
            elif stat.S_ISDIR(st.st_mode):
                kind = "Папка"
            else:
                ctype, _ = Gio.content_type_guess(p, None)
                kind = Gio.content_type_get_description(ctype) or ctype
            add("Тип", kind)
            add("Где", os.path.dirname(p) or "/")
            add("Изменён", time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(st.st_mtime)))
            try:
                owner = pwd.getpwuid(st.st_uid).pw_name
            except KeyError:
                owner = str(st.st_uid)
            add("Права", f"{stat.filemode(st.st_mode)}   {owner}")
        else:
            add("Выбрано", f"{len(paths)} объектов")
        size_lbl = add("Размер", "считаю…")
        stop = threading.Event()
        top_dirs = sum(1 for p in paths if is_real_dir(p))

        def work():
            size, files, dirs = tree_stats(paths, stop)
            if stop.is_set():
                return
            text = human(size)
            if top_dirs or files > len(paths):
                text += f"   ·   файлов: {files}, папок: {max(dirs - top_dirs, 0)}"
            GLib.idle_add(size_lbl.set_text, text)
        threading.Thread(target=work, daemon=True).start()
        dlg.show_all()
        dlg.run()
        stop.set()
        dlg.destroy()

    # ---------- мышь и клавиши ----------
    def open_with_menu(self, path):
        ctype, _ = Gio.content_type_guess(path, None)
        apps = [a for a in Gio.AppInfo.get_all_for_type(ctype) if a.should_show()]
        if not apps:
            apps = [a for a in Gio.AppInfo.get_all() if a.should_show()]
        if not apps:
            return None
        sub = Gtk.Menu()
        for a in apps[:14]:
            it = Gtk.MenuItem(label=a.get_display_name())
            it.connect("activate", lambda w, a=a: self.launch_with(a, path))
            sub.append(it)
        return sub

    def launch_with(self, app, path):
        try:
            app.launch([Gio.File.new_for_path(path)], None)
        except GLib.Error as e:
            self.say("Не удалось открыть: " + e.message, True)

    def duplicate(self):
        paths = self.selected_paths()
        if paths:
            self.run_transfer(paths, self.cwd, False)

    def transfer_to(self, move):
        paths = self.selected_paths()
        if not paths:
            return
        dlg = Gtk.FileChooserDialog(title="Переместить в…" if move else "Копировать в…", transient_for=self,
                                    action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_button("Отмена", Gtk.ResponseType.CANCEL)
        dlg.add_button("Выбрать", Gtk.ResponseType.OK)
        dlg.set_current_folder(self.cwd)
        resp = dlg.run()
        dest = dlg.get_filename()
        dlg.destroy()
        if resp != Gtk.ResponseType.OK or not dest:
            return
        if not os.access(dest, os.W_OK | os.X_OK):
            self.say("Нет прав на запись: " + dest, True)
            return
        self.run_transfer(paths, dest, move)

    def compress(self):
        paths = self.selected_paths()
        if not paths:
            return
        name = (os.path.basename(paths[0]) if len(paths) == 1 else "archive") + ".zip"
        dest = unique(self.cwd, name)
        self.say("Сжимаю…")

        def work():
            errs = make_zip(paths, dest)
            GLib.idle_add(self.after_pack, dest, errs, "Создан архив: ")
        threading.Thread(target=work, daemon=True).start()

    def extract(self):
        paths = self.selected_paths()
        if len(paths) != 1:
            return
        src = paths[0]
        stem = re.sub(r"(\.tar\.(gz|bz2|xz)|\.tgz|\.tbz2|\.txz|\.tar|\.zip)$", "", os.path.basename(src), flags=re.I)
        dest = unique(self.cwd, stem or "archive")
        self.say("Распаковываю…")

        def work():
            errs = extract_archive(src, dest)
            GLib.idle_add(self.after_pack, dest, errs, "Распаковано в: ")
        threading.Thread(target=work, daemon=True).start()

    def after_pack(self, dest, errs, prefix):
        self.reload(select=os.path.basename(dest))
        if errs:
            self.say("Ошибка: " + errs[0] + (f"  (и ещё {len(errs) - 1})" if len(errs) > 1 else ""), True)
        else:
            self.say(prefix + os.path.basename(dest))
        return False

    def invert_selection(self):
        sel = self.view.get_selection()
        for row in self.store:
            if sel.path_is_selected(row.path):
                sel.unselect_path(row.path)
            else:
                sel.select_path(row.path)

    def new_window(self):
        try:
            subprocess.Popen([sys.executable, os.path.abspath(sys.argv[0]), self.cwd], start_new_session=True)
        except OSError as e:
            self.say("Не удалось открыть окно: " + err_text(e), True)

    def on_view_click(self, view, ev):
        if ev.button == 1 and ev.type == Gdk.EventType.BUTTON_PRESS:
            # рамка выделения - только с пустого места, иначе строку можно тащить
            view.set_rubber_banding(view.get_path_at_pos(int(ev.x), int(ev.y)) is None)
            return False
        if ev.button != 3:
            return False
        hit = view.get_path_at_pos(int(ev.x), int(ev.y))
        sel = view.get_selection()
        if hit:
            if not sel.path_is_selected(hit[0]):
                sel.unselect_all()
                sel.select_path(hit[0])
        else:
            sel.unselect_all()
        menu = Gtk.Menu()

        def add(label, cb, enabled=True):
            it = Gtk.MenuItem(label=label)
            it.set_sensitive(enabled)
            it.connect("activate", lambda *_: cb())
            menu.append(it)

        def sep():
            menu.append(Gtk.SeparatorMenuItem())
        rows = self.selected_rows()
        has, one = bool(rows), len(rows) == 1
        one_dir = one and self.store[rows[0]][4]
        one_path = self.store[rows[0]][5] if one else None
        in_tr = in_trash(self.cwd)
        if one:
            add("Открыть", lambda: self.on_row_activated(view, self.selected_rows()[0], None))
        if one and not one_dir:
            sub = self.open_with_menu(one_path)
            if sub is not None:
                mi = Gtk.MenuItem(label="Открыть с помощью")
                mi.set_submenu(sub)
                menu.append(mi)
        if one_dir:
            add("Открыть в терминале", lambda: self.open_terminal(one_path))
            marked = os.path.realpath(one_path) in self.marks
            add("Убрать из закладок" if marked else "Добавить в закладки", lambda: self.toggle_mark(one_path))
        if one:
            sep()
        add("Копировать", lambda: self.copy(False), has)
        add("Вырезать", lambda: self.copy(True), has)
        add("Вставить", self.paste, bool(self.clip[0]) and not in_tr)
        sep()
        if in_tr:
            add("Восстановить", self.restore_selected, has)
            add("Удалить навсегда", self.trash, has)
            add("Очистить корзину", self.empty_trash_ask)
        else:
            add("Переименовать", self.start_rename, one)
            add("В корзину", self.trash, has)
            add("Удалить навсегда", lambda: self.trash(True), has)
        sep()
        add("Копировать путь", self.copy_path)
        if not in_tr:
            add("Создать копию", self.duplicate, has)
            add("Копировать в…", lambda: self.transfer_to(False), has)
            add("Переместить в…", lambda: self.transfer_to(True), has)
            add("Сжать в zip", self.compress, has)
            if one and not one_dir and one_path.lower().endswith(ARCHIVE_EXT):
                add("Распаковать сюда", self.extract)
            add("Новая папка", self.new_folder)
            add("Новый файл", self.new_file)
        sep()
        add("Выделить всё", self.select_all)
        add("Инвертировать выделение", self.invert_selection)
        add("Новое окно", self.new_window)
        add("Терминал здесь", self.open_terminal)
        add("Свойства", self.properties)
        menu.show_all()
        menu.popup_at_pointer(ev)
        return True

    def on_key(self, win, ev):
        key = Gdk.keyval_name(ev.keyval)
        ctrl = bool(ev.state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(ev.state & Gdk.ModifierType.SHIFT_MASK)
        alt = bool(ev.state & Gdk.ModifierType.MOD1_MASK)
        typing = isinstance(self.get_focus(), Gtk.Entry)
        if ctrl and key in ("q", "Q", "w", "W"):
            self.destroy()
            return True
        if ctrl and key in ("l", "L"):
            self.entry.grab_focus()
            return True
        if ctrl and key in ("f", "F"):
            self.filter.grab_focus()
            return True
        if key == "Escape" and typing:
            if self.get_focus() is self.filter:
                self.filter.set_text("")
            self.view.grab_focus()
            return True
        if typing:
            return False
        if alt and key == "Left":
            self.go_back()
        elif alt and key == "Right":
            self.go_forward()
        elif alt and key in ("Return", "KP_Enter"):
            self.properties()
        elif (alt and key == "Up") or key == "BackSpace":
            self.go_up()
        elif key == "F5":
            self.reload()
        elif key == "F2":
            self.start_rename()
        elif key == "F4":
            self.open_terminal()
        elif key == "Delete":
            self.trash(shift)
        elif ctrl and shift and key in ("n", "N"):
            self.new_folder()
        elif ctrl and key in ("a", "A"):
            self.select_all()
        elif ctrl and key in ("i", "I"):
            self.invert_selection()
        elif ctrl and key in ("n", "N"):
            self.new_window()
        elif ctrl and key in ("d", "D"):
            self.toggle_mark(self.cwd)
        elif ctrl and key in ("c", "C"):
            self.copy(False)
        elif ctrl and key in ("x", "X"):
            self.copy(True)
        elif ctrl and key in ("v", "V"):
            self.paste()
        elif ctrl and key in ("h", "H"):
            self.b_hidden.set_active(not self.b_hidden.get_active())
        else:
            return False
        return True


def main():
    GLib.set_prgname("files")
    GLib.set_application_name("Files")
    start, select = HOME, None
    if len(sys.argv) > 1:
        p = os.path.abspath(os.path.expanduser(sys.argv[1]))
        if os.path.isdir(p):
            start = p
        elif os.path.exists(p):
            start, select = os.path.dirname(p), os.path.basename(p)
    win = FilesWindow(start, select)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/files

# ---------- очистка метаданных (фото и файлы, на базе mat2) ----------
cat > /usr/local/bin/meta-clean <<'EOF'
#!/usr/bin/python3
import os
import re
import shutil
import subprocess
import sys
import threading
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

CSS = b"""
* { font-family: "DejaVu Sans Mono", monospace; font-size: 11px; }
window { background-color: rgba(15,20,16,0.88); color: #e4ebe2; }
window.dialog, window.messagedialog { background-color: rgb(20,27,22); }
.bar { padding: 8px 10px 4px 10px; }
.title { font-size: 14px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 14px; box-shadow: none;
padding: 3px 12px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(169,204,130,0.16); }
button.main { background-color: rgba(125,148,96,0.40); border-color: #a9cc82; }
button.main:hover { background-color: rgba(125,148,96,0.60); }
button:disabled { opacity: 0.45; }
checkbutton { color: #e4ebe2; }
treeview.view { background-color: transparent; color: #e4ebe2; }
treeview.view:hover { background-color: rgba(169,204,130,0.08); }
treeview.view:selected { background-color: rgba(169,204,130,0.28); color: #ffffff; }
treeview.view.dnd { border: 1px solid rgba(169,204,130,0.80); }
treeview header button { background-color: transparent; border: none; border-radius: 0;
border-bottom: 1px solid rgba(169,204,130,0.18); color: #8a9a82; padding: 3px 8px; }
scrolledwindow, viewport { background-color: transparent; }
textview, textview text { background-color: rgba(169,204,130,0.05); color: #e4ebe2; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar { background: transparent; border: none; }
.status { color: #8a9a82; padding: 3px 14px 8px 14px; }
.err { color: #d98b7d; }
.dim { color: #8a9a82; }
.hint { color: #75846d; padding: 0 14px 6px 14px; }
"""
OK_C, BAD_C, WORK_C, DIM_C = "#a9cc82", "#d98b7d", "#d8b76c", "#e4ebe2"


def mat2_cmd(*extra):
    cmd = ["mat2"]
    if not shutil.which("bwrap"):
        cmd.append("--no-sandbox")
    return cmd + list(extra)


def first_line(text, default):
    for ln in (text or "").splitlines():
        ln = ln.strip()
        if ln:
            return re.sub(r"^\[[-+!]\]\s*", "", ln)
    return default


class Cleaner(Gtk.Window):
    def __init__(self, paths):
        super().__init__(title="Очистка метаданных")
        self.set_default_size(780, 520)
        self.set_decorated(False)
        self.busy = False
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        for rule in re.findall(rb"[^{}]+\{[^{}]*\}", CSS):
            prov = Gtk.CssProvider()
            try:
                prov.load_from_data(rule)
            except GLib.Error:
                continue
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        bar.get_style_context().add_class("bar")
        title = Gtk.Label(label="Очистка метаданных", xalign=0)
        title.get_style_context().add_class("title")
        bar.pack_start(title, True, True, 6)
        b_close = Gtk.Button(label="Закрыть")
        b_close.connect("clicked", lambda *_: self.destroy())
        bar.pack_start(b_close, False, False, 0)
        root.pack_start(bar, False, False, 0)
        hint = Gtk.Label(label="Перетащи сюда фото и файлы (или нажми «Добавить»). Уберутся EXIF, GPS, автор, "
                               "программа и прочие скрытые данные.", xalign=0)
        hint.get_style_context().add_class("hint")
        hint.set_line_wrap(True)
        root.pack_start(hint, False, False, 0)
        # путь, имя, папка, состояние, цвет
        self.store = Gtk.ListStore(str, str, str, str, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        self.view.set_rubber_banding(True)
        for title, idx, expand, dim in (("Файл", 1, True, False), ("Папка", 2, True, True), ("Состояние", 3, False, False)):
            r = Gtk.CellRendererText()
            r.set_property("ellipsize", Pango.EllipsizeMode.MIDDLE if dim else Pango.EllipsizeMode.END)
            if dim:
                r.set_property("foreground", "#8a9a82")
                col = Gtk.TreeViewColumn(title, r, text=idx)
            elif idx == 3:
                col = Gtk.TreeViewColumn(title, r, text=idx, foreground=4)
                col.set_min_width(220)
            else:
                col = Gtk.TreeViewColumn(title, r, text=idx)
            col.set_expand(expand)
            col.set_resizable(True)
            self.view.append_column(col)
        self.view.drag_dest_set(Gtk.DestDefaults.ALL, [Gtk.TargetEntry.new("text/uri-list", 0, 0)],
                                Gdk.DragAction.COPY)
        self.view.connect("drag-data-received", self.on_drop)
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.view)
        root.pack_start(scroll, True, True, 0)
        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        btns.get_style_context().add_class("bar")
        self.b_add = self.button(btns, "Добавить…", self.add_dialog)
        self.b_show = self.button(btns, "Показать метаданные", self.show_meta)
        self.b_rm = self.button(btns, "Убрать из списка", self.remove_selected)
        self.chk = Gtk.CheckButton(label="заменять оригиналы")
        self.chk.set_tooltip_text("Выключено: рядом создаётся копия «имя.cleaned.расширение»")
        btns.pack_start(self.chk, False, False, 8)
        self.b_clean = Gtk.Button(label="Очистить")
        self.b_clean.get_style_context().add_class("main")
        self.b_clean.connect("clicked", lambda *_: self.clean())
        btns.pack_end(self.b_clean, False, False, 0)
        root.pack_start(btns, False, False, 0)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        root.pack_start(self.status, False, False, 0)
        self.connect("key-press-event", self.on_key)
        if not shutil.which("mat2"):
            self.say("Не найден mat2. Установи: sudo pacman -S mat2", True)
        else:
            self.say("Список пуст")
        self.add_paths(paths)

    def button(self, box, text, cb):
        b = Gtk.Button(label=text)
        b.connect("clicked", lambda *_: cb())
        box.pack_start(b, False, False, 0)
        return b

    def say(self, text, err=False):
        ctx = self.status.get_style_context()
        if err:
            ctx.add_class("err")
        else:
            ctx.remove_class("err")
        self.status.set_text(text)
        return False

    def on_key(self, win, ev):
        key = Gdk.keyval_name(ev.keyval)
        ctrl = bool(ev.state & Gdk.ModifierType.CONTROL_MASK)
        if ctrl and key in ("q", "Q", "w", "W"):
            self.destroy()
        elif ctrl and key in ("o", "O"):
            self.add_dialog()
        elif key == "Delete":
            self.remove_selected()
        elif ctrl and key in ("a", "A"):
            self.view.get_selection().select_all()
        else:
            return False
        return True

    # ---------- список ----------
    def have(self):
        return {r[0] for r in self.store}

    def add_paths(self, paths):
        have, added = self.have(), 0
        todo = []
        for p in paths:
            p = os.path.abspath(p)
            if os.path.isdir(p):
                for r, ds, fs in os.walk(p):
                    ds[:] = [d for d in ds if not d.startswith(".")]
                    todo.extend(os.path.join(r, f) for f in sorted(fs) if not f.startswith("."))
            elif os.path.isfile(p):
                todo.append(p)
        for p in todo:
            if p in have:
                continue
            have.add(p)
            self.store.append([p, os.path.basename(p), os.path.dirname(p), "ожидает", DIM_C])
            added += 1
        if added:
            self.say(f"В списке: {len(self.store)}")
        return added

    def on_drop(self, view, ctx, x, y, data, info, t):
        paths = []
        for u in data.get_uris() or []:
            p = Gio.File.new_for_uri(u).get_path()
            if p:
                paths.append(p)
        self.add_paths(paths)

    def add_dialog(self):
        dlg = Gtk.FileChooserDialog(title="Выбери файлы", transient_for=self, action=Gtk.FileChooserAction.OPEN)
        dlg.set_select_multiple(True)
        dlg.add_button("Отмена", Gtk.ResponseType.CANCEL)
        dlg.add_button("Добавить", Gtk.ResponseType.OK)
        resp = dlg.run()
        names = dlg.get_filenames()
        dlg.destroy()
        if resp == Gtk.ResponseType.OK:
            self.add_paths(names)

    def remove_selected(self):
        _, rows = self.view.get_selection().get_selected_rows()
        refs = [Gtk.TreeRowReference.new(self.store, r) for r in rows]
        for ref in refs:
            p = ref.get_path()
            if p is not None:
                self.store.remove(self.store.get_iter(p))
        self.say(f"В списке: {len(self.store)}" if len(self.store) else "Список пуст")

    def selected_or_all(self):
        _, rows = self.view.get_selection().get_selected_rows()
        if rows:
            return [self.store[r][0] for r in rows]
        return [r[0] for r in self.store]

    def set_state(self, path, text, color):
        for row in self.store:
            if row[0] == path:
                row[3], row[4] = text, color
                break
        return False

    # ---------- метаданные ----------
    def show_meta(self):
        paths = self.selected_or_all()
        if not paths:
            self.say("Сначала добавь файл", True)
            return
        path = paths[0]
        dlg = Gtk.Dialog(title="Метаданные", transient_for=self, modal=True)
        dlg.add_button("Закрыть", Gtk.ResponseType.CLOSE)
        dlg.set_default_size(620, 380)
        head = Gtk.Label(label=os.path.basename(path), xalign=0, margin=10)
        head.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        view = Gtk.TextView()
        view.set_editable(False)
        view.set_cursor_visible(False)
        view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        view.set_left_margin(10)
        view.set_top_margin(8)
        view.get_buffer().set_text("читаю…")
        sc = Gtk.ScrolledWindow()
        sc.add(view)
        box = dlg.get_content_area()
        box.pack_start(head, False, False, 0)
        box.pack_start(sc, True, True, 0)

        def work():
            try:
                r = subprocess.run(mat2_cmd("--show", path), capture_output=True, text=True, timeout=60)
                text = (r.stdout + ("\n" + r.stderr if r.stderr.strip() else "")).strip() or "Метаданных нет"
            except Exception as e:
                text = "Ошибка: " + str(e)
            GLib.idle_add(view.get_buffer().set_text, text)
        threading.Thread(target=work, daemon=True).start()
        dlg.show_all()
        dlg.run()
        dlg.destroy()

    # ---------- чистка ----------
    def clean(self):
        if self.busy:
            return
        if not shutil.which("mat2"):
            self.say("Не найден mat2. Установи: sudo pacman -S mat2", True)
            return
        paths = self.selected_or_all()
        if not paths:
            self.say("Сначала добавь файлы", True)
            return
        inplace = self.chk.get_active()
        if inplace:
            dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
                                    buttons=Gtk.ButtonsType.YES_NO,
                                    text=f"Заменить оригиналы очищенными версиями ({len(paths)})?\n"
                                         "Вернуть исходные метаданные будет нельзя.")
            resp = dlg.run()
            dlg.destroy()
            if resp != Gtk.ResponseType.YES:
                return
        self.busy = True
        self.b_clean.set_sensitive(False)
        self.say("Чищу…")

        def work():
            ok = bad = 0
            for p in paths:
                GLib.idle_add(self.set_state, p, "чищу…", WORK_C)
                good, text = self.run_one(p, inplace)
                if good:
                    ok += 1
                    GLib.idle_add(self.set_state, p, text, OK_C)
                else:
                    bad += 1
                    GLib.idle_add(self.set_state, p, "ошибка: " + text, BAD_C)
            GLib.idle_add(self.finish, ok, bad)
        threading.Thread(target=work, daemon=True).start()

    def run_one(self, path, inplace):
        cmd = mat2_cmd("--inplace", path) if inplace else mat2_cmd(path)
        base, ext = os.path.splitext(path)
        target = f"{base}.cleaned{ext}"
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        except Exception as e:
            return False, str(e)
        if r.returncode != 0 or (not inplace and not os.path.exists(target)):
            return False, first_line(r.stderr + "\n" + r.stdout, "формат не поддерживается")
        if inplace:
            return True, "готово (оригинал заменён)"
        return True, "готово → " + os.path.basename(target)

    def finish(self, ok, bad):
        self.busy = False
        self.b_clean.set_sensitive(True)
        if bad:
            self.say(f"Очищено: {ok}, не удалось: {bad}", True)
        else:
            self.say(f"Очищено файлов: {ok}")
        return False


def main():
    GLib.set_prgname("meta-clean")
    GLib.set_application_name("meta-clean")
    paths = [os.path.expanduser(a) for a in sys.argv[1:]]
    win = Cleaner(paths)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/meta-clean
cat > /usr/share/applications/meta-clean.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Очистка метаданных
Comment=Удалить метаданные из фото и файлов
Exec=/usr/local/bin/meta-clean %F
Icon=edit-clear-all
Terminal=false
Categories=Utility;
StartupWMClass=meta-clean
EOF

# ---------- меню питания ----------
cat > /usr/local/bin/power-menu <<'EOF'
#!/usr/bin/python3
import os
import re
import subprocess
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "power-menu.pid")
CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(4,7,5,0.60); }
.card { background-color: rgba(15,20,16,0.85); border: 1px solid rgba(169,204,130,0.45);
border-radius: 20px; padding: 22px 24px 14px 24px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 16px; box-shadow: none; padding: 0; }
button:hover, button:focus { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button.danger { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
button.danger:hover, button.danger:focus { background-color: rgba(217,139,125,0.20); border-color: #d98b7d; }
.icon { font-size: 30px; }
.name { font-size: 11px; }
.key { color: #8a9a82; font-size: 9px; }
.hint { color: #75846d; font-size: 9px; }
"""

ITEMS = (
    ("\uf011", "Выключить", "P", "poweroff", True),
    ("\uf021", "Перезагрузить", "R", "reboot", False),
    ("\uf186", "Сон", "S", "suspend", False),
    ("\uf08b", "Выйти", "E", "exit", False),
)


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if b"power-menu" in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def logout():
    # сначала обычная команда Hyprland, потом вариант для Lua-конфига, в конце - через logind
    for args in (["hyprctl", "dispatch", "exit"], ["hyprctl", "dispatch", "hl.dsp.exit()"]):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=3)
            if r.returncode == 0 and r.stdout.strip().lower().startswith("ok"):
                return
        except Exception:
            pass
    sid = os.environ.get("XDG_SESSION_ID")
    try:
        if sid:
            subprocess.Popen(["loginctl", "terminate-session", sid], start_new_session=True)
        else:
            subprocess.Popen(["loginctl", "terminate-user", os.environ.get("USER", "")], start_new_session=True)
    except Exception:
        pass


FA_FONT = "FontAwesome"


class Glyph(Gtk.DrawingArea):
    # иконка рисуется по центру реального контура глифа, а не по рамке строки,
    # поэтому боковые отступы шрифта не сдвигают её вправо
    def __init__(self, text, size, w=56, h=44):
        super().__init__()
        self.text, self.size = text, size
        self.set_size_request(w, h)
        self.set_halign(Gtk.Align.CENTER)
        self.get_style_context().add_class("icon")
        self.connect("draw", self.on_draw)

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        layout = widget.create_pango_layout(self.text)
        fd = Pango.FontDescription()
        fd.set_family(FA_FONT + ",Symbols Nerd Font Mono,Symbols Nerd Font")
        fd.set_absolute_size(self.size * Pango.SCALE)
        layout.set_font_description(fd)
        ink, _logical = layout.get_pixel_extents()
        x = round((alloc.width - ink.width) / 2 - ink.x)
        y = round((alloc.height - ink.height) / 2 - ink.y)
        Gtk.render_layout(widget.get_style_context(), cr, x, y, layout)
        return False


class PowerMenu(Gtk.Window):
    def __init__(self):
        super().__init__(title="power-menu")
        self.set_decorated(False)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        for rule in re.findall(rb"[^{}]+\{[^{}]*\}", CSS):
            prov = Gtk.CssProvider()
            try:
                prov.load_from_data(rule)
            except GLib.Error:
                continue
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        hold = Gtk.EventBox()
        hold.set_visible_window(False)
        hold.set_halign(Gtk.Align.CENTER)
        hold.set_valign(Gtk.Align.CENTER)
        hold.connect("button-press-event", lambda w, e: True)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card.get_style_context().add_class("card")
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.buttons = []
        self.keys = {}
        for icon, name, key, cmd, danger in ITEMS:
            b = Gtk.Button()
            b.set_size_request(132, 112)
            if danger:
                b.get_style_context().add_class("danger")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            col.set_valign(Gtk.Align.CENTER)
            col.pack_start(Glyph(icon, 30), False, False, 0)
            for text, cls in ((name, "name"), (key, "key")):
                lab = Gtk.Label(label=text)
                lab.set_halign(Gtk.Align.CENTER)
                lab.get_style_context().add_class(cls)
                col.pack_start(lab, False, False, 0)
            b.add(col)
            b.connect("clicked", lambda w, c=cmd: self.run(c))
            row.pack_start(b, False, False, 0)
            self.buttons.append(b)
            self.keys[key.lower()] = cmd
        hint = Gtk.Label(label="← →  выбор    Enter  подтвердить    Esc  закрыть")
        hint.get_style_context().add_class("hint")
        card.pack_start(row, False, False, 0)
        card.pack_start(hint, False, False, 0)
        hold.add(card)
        bg.add(hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        self.fullscreen()

    def focus_step(self, d):
        cur = self.get_focus()
        i = self.buttons.index(cur) if cur in self.buttons else -1
        self.buttons[(i + d) % len(self.buttons)].grab_focus()

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
        elif k in ("Left", "Up", "ISO_Left_Tab"):
            self.focus_step(-1)
        elif k in ("Right", "Down", "Tab"):
            self.focus_step(1)
        elif k.lower() in self.keys:
            self.run(self.keys[k.lower()])
        else:
            return False
        return True

    def run(self, cmd):
        self.hide()
        if cmd == "exit":
            logout()
        else:
            subprocess.Popen(["systemctl", cmd], start_new_session=True)
        self.quit()

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def main():
    GLib.set_prgname("power-menu")
    GLib.set_application_name("power-menu")
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = PowerMenu()
    w.connect("destroy", on_destroy)
    w.show_all()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    w.buttons[0].grab_focus()
    Gtk.main()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/power-menu

# ---------- меню производительности (профили питания) ----------
cat > /usr/local/bin/performance-menu <<'EOF'
#!/usr/bin/python3
import json
import os
import re
import subprocess
import threading
import time
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell
except (ValueError, ImportError):
    GtkLayerShell = None

BAR_GAP = 38  # отступ сверху: высота waybar + небольшой зазор

NAME = "performance-menu"
LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), NAME + ".pid")
FA_FONT = "FontAwesome"
BASE_CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(4,7,5,0.60); }
window.popup { background-color: rgba(0,0,0,0); }
.pcard { padding: 14px 16px 12px 16px; border-radius: 16px; }
.card { background-color: rgba(15,20,16,0.90); border: 1px solid rgba(169,204,130,0.45);
border-radius: 20px; padding: 20px 24px 14px 24px; }
.title { color: #e4ebe2; font-size: 14px; }
.sub { color: #8a9a82; font-size: 10px; }
.sect { color: #8a9a82; font-size: 9px; }
.name { color: #e4ebe2; font-size: 11px; }
.pct { color: #a8b8a0; font-size: 10px; }
.err { color: #d98b7d; font-size: 10px; }
.ok { color: #a9cc82; font-size: 10px; }
.hint { color: #75846d; font-size: 9px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover, button:focus { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button.off { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none; padding: 3px 10px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
scale trough { background-color: rgba(169,204,130,0.18); background-image: none; border: none;
border-radius: 4px; min-height: 6px; }
scale highlight { background-color: #a9cc82; background-image: none; border: none; border-radius: 4px; }
scale slider { background-color: #e4ebe2; background-image: none; border: none; box-shadow: none;
border-radius: 50%; min-width: 16px; min-height: 16px; margin: -5px; }
scale.muted highlight { background-color: #75846d; }
scale.muted slider { background-color: #a8b8a0; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; margin: 0; }
scrollbar { background: transparent; border: none; }
"""


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if NAME.encode() in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def apply_css(screen, css):
    for rule in re.findall(rb"[^{}]+\{[^{}]*\}", css):
        prov = Gtk.CssProvider()
        try:
            prov.load_from_data(rule)
        except GLib.Error:
            continue
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def label(text, cls=None, xalign=0.5, chars=None):
    lab = Gtk.Label(label=text, xalign=xalign)
    if cls:
        lab.get_style_context().add_class(cls)
    if chars:
        lab.set_width_chars(chars)
    return lab


class Glyph(Gtk.DrawingArea):
    # иконка рисуется по центру реального контура глифа, а не по рамке строки,
    # поэтому боковые отступы шрифта не сдвигают её вправо
    def __init__(self, text, size, w=40, h=30, cls=None):
        super().__init__()
        self.text, self.size = text, size
        self.set_size_request(w, h)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)
        ctx = self.get_style_context()
        ctx.add_class("icon")
        if cls:
            ctx.add_class(cls)
        self.connect("draw", self.on_draw)

    def set_text(self, text):
        self.text = text
        self.queue_draw()

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        layout = widget.create_pango_layout(self.text)
        fd = Pango.FontDescription()
        fd.set_family(FA_FONT + ",Symbols Nerd Font Mono,Symbols Nerd Font")
        fd.set_absolute_size(self.size * Pango.SCALE)
        layout.set_font_description(fd)
        ink, _logical = layout.get_pixel_extents()
        x = round((alloc.width - ink.width) / 2 - ink.x)
        y = round((alloc.height - ink.height) / 2 - ink.y)
        Gtk.render_layout(widget.get_style_context(), cr, x, y, layout)
        return False


def sh(args, timeout=3, env=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None


def fire(args):
    threading.Thread(target=sh, args=(args,), daemon=True).start()


def use_layer(win):
    """Делает окно слоем поверх всего (layer-shell). False - если не получилось."""
    if GtkLayerShell is None:
        return False
    try:
        if not GtkLayerShell.is_supported():
            return False
        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_namespace(win, NAME)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(win, edge, True)
        GtkLayerShell.set_exclusive_zone(win, -1)
        if hasattr(GtkLayerShell, "KeyboardMode"):
            GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        else:
            GtkLayerShell.set_keyboard_interactivity(win, True)
        return True
    except Exception:
        return False


def pointer_x():
    """X курсора внутри его монитора и ширина монитора (логические пиксели)."""
    try:
        r = sh(["hyprctl", "cursorpos", "-j"], 2)
        try:
            cx = float(json.loads(r.stdout)["x"])
        except ValueError:
            cx = float(re.findall(r"-?\d+", r.stdout)[0])
        mons = json.loads(sh(["hyprctl", "monitors", "-j"], 2).stdout)
        for m in mons:
            sc = float(m.get("scale", 1)) or 1.0
            w = m["width"] / sc
            if m["x"] <= cx < m["x"] + w:
                return cx - m["x"], w
    except Exception:
        pass
    return None, None


def screen_width():
    try:
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        return mon.get_geometry().width
    except Exception:
        return 1920


class Overlay(Gtk.Window):
    def __init__(self, extra_css=b"", popup=True):
        super().__init__(title=NAME)
        self.set_decorated(False)
        self.is_popup = popup
        self.layer = popup and use_layer(self)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        apply_css(screen, BASE_CSS + extra_css)
        if self.layer:
            self.get_style_context().add_class("popup")
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        self.hold = Gtk.EventBox()
        self.hold.set_visible_window(False)
        self.hold.set_halign(Gtk.Align.CENTER)
        self.hold.set_valign(Gtk.Align.CENTER)
        self.hold.connect("button-press-event", lambda w, e: True)
        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        ctx = self.card.get_style_context()
        ctx.add_class("card")
        if self.layer:
            ctx.add_class("pcard")
        self.hold.add(self.card)
        bg.add(self.hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        if not self.layer:
            self.fullscreen()

    def place_card(self):
        """Всплывающее окно: под иконкой, на которую нажали (по позиции курсора)."""
        if not self.layer:
            return
        cx, width = pointer_x()
        if cx is None:
            width = screen_width()
            cx = width - 150
        self.anchor_cx, self.mon_w = cx, width
        self.hold.set_halign(Gtk.Align.START)
        self.hold.set_valign(Gtk.Align.START)
        self.hold.set_margin_top(BAR_GAP)
        self.fit_card(self.card.get_preferred_width()[1])
        # если содержимое потом стало шире (список сетей и т.п.) - сдвигаем обратно в экран
        self.card.connect("size-allocate", lambda w, a: GLib.idle_add(self.fit_card, a.width))

    def fit_card(self, cw):
        x = int(max(8, min(self.anchor_cx - cw / 2, self.mon_w - cw - 8)))
        if x != self.hold.get_margin_start():
            self.hold.set_margin_start(x)

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
            return True
        return self.key(k, ev)

    def key(self, name, ev):
        return False

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def run(cls):
    GLib.set_prgname(NAME)
    GLib.set_application_name(NAME)
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = cls()
    w.connect("destroy", on_destroy)
    w.show_all()      # сначала показываем: у скрытых виджетов ширина считается как 0
    w.place_card()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    first = getattr(w, "first", None)
    if first is not None:
        first.grab_focus()
    Gtk.main()


EXTRA_CSS = b"""
button.tile { border-radius: 14px; padding: 0; }
button.tile.active { background-color: rgba(125,148,96,0.32); border-color: #a9cc82; }
button.tile:disabled { opacity: 0.35; }
.tile-icon { color: #a9cc82; }
button.perf .icon { color: #d8b76c; }
.desc { color: #8a9a82; font-size: 9px; }
.key { color: #75846d; font-size: 9px; }
"""
PROFILES = (
    ("power-saver", "\uf06c", "Энергосбережение", "тише, дольше работа", "1", False),
    ("balanced", "\uf24e", "Баланс", "на каждый день", "2", False),
    ("performance", "\uf0e7", "Производительность", "максимум мощности", "3", True),
)


def ppd(*args):
    return subprocess.run(["powerprofilesctl", *args], capture_output=True, text=True, timeout=5)


def state():
    # (текущий профиль, множество доступных профилей); при сбое (None, пусто)
    try:
        cur = ppd("get")
        lst = ppd("list")
        if cur.returncode != 0 or lst.returncode != 0:
            return None, set()
        names = set(re.findall(r"^\s*\*?\s*([a-z-]+):\s*$", lst.stdout, re.M))
        return cur.stdout.strip(), names
    except Exception:
        return None, set()


class PerfMenu(Overlay):
    def __init__(self):
        super().__init__(EXTRA_CSS)
        self.first = None
        self.keys = {}
        self.buttons = []
        cur, avail = state()
        card = self.card
        card.set_spacing(10)
        card.pack_start(label("Профиль питания", "title", xalign=0), False, False, 0)
        self.sub = label("выбери режим работы процессора" if cur else "служба power-profiles-daemon не отвечает",
                         "sub" if cur else "err", xalign=0)
        card.pack_start(self.sub, False, False, 0)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for prof, icon, name, desc, key, perf in PROFILES:
            b = Gtk.Button()
            b.set_size_request(148, 104)
            ctx = b.get_style_context()
            ctx.add_class("tile")
            if perf:
                ctx.add_class("perf")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            col.set_valign(Gtk.Align.CENTER)
            is_cur = prof == cur
            col.pack_start(Glyph(icon, 24, 40, 34), False, False, 0)
            col.pack_start(label(name, "name"), False, False, 0)
            col.pack_start(label(desc, "desc"), False, False, 0)
            col.pack_start(label(key + ("  ·  сейчас" if is_cur else ""), "key"), False, False, 0)
            b.add(col)
            if is_cur:
                ctx.add_class("active")
                self.first = b
            if prof not in avail:
                b.set_sensitive(False)
            else:
                self.keys[key] = prof
            b.connect("clicked", lambda w, p=prof: self.choose(p))
            row.pack_start(b, False, False, 0)
            self.buttons.append((b, prof))
        card.pack_start(row, False, False, 0)
        if self.first is None:
            for b, prof in self.buttons:
                if prof in avail:
                    self.first = b
                    break

    def live(self):
        return [b for b, _ in self.buttons if b.get_sensitive()]

    def step_focus(self, d):
        lst = self.live()
        if not lst:
            return
        cur = self.get_focus()
        i = lst.index(cur) if cur in lst else -1
        lst[(i + d) % len(lst)].grab_focus()

    def key(self, name, ev):
        if name in ("Left", "Up", "ISO_Left_Tab"):
            self.step_focus(-1)
        elif name in ("Right", "Down", "Tab"):
            self.step_focus(1)
        elif name in self.keys:
            self.choose(self.keys[name])
        else:
            return False
        return True

    def choose(self, prof):
        try:
            ok = ppd("set", prof).returncode == 0
        except Exception:
            ok = False
        if not ok:
            ctx = self.sub.get_style_context()
            ctx.remove_class("sub")
            ctx.add_class("err")
            self.sub.set_text("не удалось переключить профиль")
            return
        self.quit()


if __name__ == "__main__":
    run(PerfMenu)
EOF
chmod 755 /usr/local/bin/performance-menu

# ---------- меню звука, сети, календарь на год ----------
cat > /usr/local/bin/audio-menu <<'EOF'
#!/usr/bin/python3
import json
import os
import re
import subprocess
import threading
import time
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell
except (ValueError, ImportError):
    GtkLayerShell = None

BAR_GAP = 38  # отступ сверху: высота waybar + небольшой зазор

NAME = "audio-menu"
LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), NAME + ".pid")
FA_FONT = "FontAwesome"
BASE_CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(4,7,5,0.60); }
window.popup { background-color: rgba(0,0,0,0); }
.pcard { padding: 14px 16px 12px 16px; border-radius: 16px; }
.card { background-color: rgba(15,20,16,0.90); border: 1px solid rgba(169,204,130,0.45);
border-radius: 20px; padding: 20px 24px 14px 24px; }
.title { color: #e4ebe2; font-size: 14px; }
.sub { color: #8a9a82; font-size: 10px; }
.sect { color: #8a9a82; font-size: 9px; }
.name { color: #e4ebe2; font-size: 11px; }
.pct { color: #a8b8a0; font-size: 10px; }
.err { color: #d98b7d; font-size: 10px; }
.ok { color: #a9cc82; font-size: 10px; }
.hint { color: #75846d; font-size: 9px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover, button:focus { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button.off { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none; padding: 3px 10px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
scale trough { background-color: rgba(169,204,130,0.18); background-image: none; border: none;
border-radius: 4px; min-height: 6px; }
scale highlight { background-color: #a9cc82; background-image: none; border: none; border-radius: 4px; }
scale slider { background-color: #e4ebe2; background-image: none; border: none; box-shadow: none;
border-radius: 50%; min-width: 16px; min-height: 16px; margin: -5px; }
scale.muted highlight { background-color: #75846d; }
scale.muted slider { background-color: #a8b8a0; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; margin: 0; }
scrollbar { background: transparent; border: none; }
"""


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if NAME.encode() in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def apply_css(screen, css):
    for rule in re.findall(rb"[^{}]+\{[^{}]*\}", css):
        prov = Gtk.CssProvider()
        try:
            prov.load_from_data(rule)
        except GLib.Error:
            continue
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def label(text, cls=None, xalign=0.5, chars=None):
    lab = Gtk.Label(label=text, xalign=xalign)
    if cls:
        lab.get_style_context().add_class(cls)
    if chars:
        lab.set_width_chars(chars)
    return lab


class Glyph(Gtk.DrawingArea):
    # иконка рисуется по центру реального контура глифа, а не по рамке строки,
    # поэтому боковые отступы шрифта не сдвигают её вправо
    def __init__(self, text, size, w=40, h=30, cls=None):
        super().__init__()
        self.text, self.size = text, size
        self.set_size_request(w, h)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)
        ctx = self.get_style_context()
        ctx.add_class("icon")
        if cls:
            ctx.add_class(cls)
        self.connect("draw", self.on_draw)

    def set_text(self, text):
        self.text = text
        self.queue_draw()

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        layout = widget.create_pango_layout(self.text)
        fd = Pango.FontDescription()
        fd.set_family(FA_FONT + ",Symbols Nerd Font Mono,Symbols Nerd Font")
        fd.set_absolute_size(self.size * Pango.SCALE)
        layout.set_font_description(fd)
        ink, _logical = layout.get_pixel_extents()
        x = round((alloc.width - ink.width) / 2 - ink.x)
        y = round((alloc.height - ink.height) / 2 - ink.y)
        Gtk.render_layout(widget.get_style_context(), cr, x, y, layout)
        return False


def sh(args, timeout=3, env=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None


def fire(args):
    threading.Thread(target=sh, args=(args,), daemon=True).start()


def use_layer(win):
    """Делает окно слоем поверх всего (layer-shell). False - если не получилось."""
    if GtkLayerShell is None:
        return False
    try:
        if not GtkLayerShell.is_supported():
            return False
        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_namespace(win, NAME)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(win, edge, True)
        GtkLayerShell.set_exclusive_zone(win, -1)
        if hasattr(GtkLayerShell, "KeyboardMode"):
            GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        else:
            GtkLayerShell.set_keyboard_interactivity(win, True)
        return True
    except Exception:
        return False


def pointer_x():
    """X курсора внутри его монитора и ширина монитора (логические пиксели)."""
    try:
        r = sh(["hyprctl", "cursorpos", "-j"], 2)
        try:
            cx = float(json.loads(r.stdout)["x"])
        except ValueError:
            cx = float(re.findall(r"-?\d+", r.stdout)[0])
        mons = json.loads(sh(["hyprctl", "monitors", "-j"], 2).stdout)
        for m in mons:
            sc = float(m.get("scale", 1)) or 1.0
            w = m["width"] / sc
            if m["x"] <= cx < m["x"] + w:
                return cx - m["x"], w
    except Exception:
        pass
    return None, None


def screen_width():
    try:
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        return mon.get_geometry().width
    except Exception:
        return 1920


class Overlay(Gtk.Window):
    def __init__(self, extra_css=b"", popup=True):
        super().__init__(title=NAME)
        self.set_decorated(False)
        self.is_popup = popup
        self.layer = popup and use_layer(self)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        apply_css(screen, BASE_CSS + extra_css)
        if self.layer:
            self.get_style_context().add_class("popup")
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        self.hold = Gtk.EventBox()
        self.hold.set_visible_window(False)
        self.hold.set_halign(Gtk.Align.CENTER)
        self.hold.set_valign(Gtk.Align.CENTER)
        self.hold.connect("button-press-event", lambda w, e: True)
        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        ctx = self.card.get_style_context()
        ctx.add_class("card")
        if self.layer:
            ctx.add_class("pcard")
        self.hold.add(self.card)
        bg.add(self.hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        if not self.layer:
            self.fullscreen()

    def place_card(self):
        """Всплывающее окно: под иконкой, на которую нажали (по позиции курсора)."""
        if not self.layer:
            return
        cx, width = pointer_x()
        if cx is None:
            width = screen_width()
            cx = width - 150
        self.anchor_cx, self.mon_w = cx, width
        self.hold.set_halign(Gtk.Align.START)
        self.hold.set_valign(Gtk.Align.START)
        self.hold.set_margin_top(BAR_GAP)
        self.fit_card(self.card.get_preferred_width()[1])
        # если содержимое потом стало шире (список сетей и т.п.) - сдвигаем обратно в экран
        self.card.connect("size-allocate", lambda w, a: GLib.idle_add(self.fit_card, a.width))

    def fit_card(self, cw):
        x = int(max(8, min(self.anchor_cx - cw / 2, self.mon_w - cw - 8)))
        if x != self.hold.get_margin_start():
            self.hold.set_margin_start(x)

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
            return True
        return self.key(k, ev)

    def key(self, name, ev):
        return False

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def run(cls):
    GLib.set_prgname(NAME)
    GLib.set_application_name(NAME)
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = cls()
    w.connect("destroy", on_destroy)
    w.show_all()      # сначала показываем: у скрытых виджетов ширина считается как 0
    w.place_card()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    first = getattr(w, "first", None)
    if first is not None:
        first.grab_focus()
    Gtk.main()


EXTRA_CSS = b"""
.row-name { color: #e4ebe2; font-size: 11px; }
"""
SINK = "@DEFAULT_AUDIO_SINK@"
SOURCE = "@DEFAULT_AUDIO_SOURCE@"
ICON_SPK = ("\uf028", "\uf026")
ICON_MIC = ("\uf130", "\uf131")


def wp_state(target):
    r = sh(["wpctl", "get-volume", target])
    if not r or r.returncode != 0:
        return None
    m = re.search(r"Volume:\s*([0-9.]+)", r.stdout)
    if not m:
        return None
    return min(100, round(float(m.group(1)) * 100)), "[MUTED]" in r.stdout


def app_streams():
    r = sh(["pactl", "--format=json", "list", "sink-inputs"])
    if not r or r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return []
    out = []
    for s in data:
        props = s.get("properties") or {}
        name = (props.get("application.name") or props.get("application.process.binary")
                or props.get("media.name") or "Приложение")
        vols = []
        for v in (s.get("volume") or {}).values():
            try:
                vols.append(int(str(v.get("value_percent", "0")).rstrip("%")))
            except ValueError:
                pass
        out.append({"id": s.get("index"), "name": str(name), "vol": max(vols) if vols else 0,
                    "mute": bool(s.get("mute"))})
    return out


class VolRow(Gtk.Box):
    def __init__(self, title, vol, muted, icons, on_vol, on_mute):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.icons, self.muted, self.on_vol, self.on_mute = icons, muted, on_vol, on_mute
        self.pending = 0
        self.btn = Gtk.Button()
        self.glyph = Glyph(icons[1] if muted else icons[0], 15, 24, 22)
        self.btn.add(self.glyph)
        self.btn.set_size_request(42, 32)
        self.btn.set_valign(Gtk.Align.CENTER)
        self.btn.connect("clicked", self.on_click)
        name = label(title, "row-name", xalign=0, chars=11)
        name.set_max_width_chars(11)
        name.set_ellipsize(Pango.EllipsizeMode.END)
        self.scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        self.scale.set_draw_value(False)
        self.scale.set_hexpand(True)
        self.scale.set_size_request(150, -1)
        self.scale.set_value(min(vol, 100))
        self.pct = label(f"{vol}%", "pct", xalign=1, chars=4)
        self.scale.connect("value-changed", self.changed)
        self.pack_start(self.btn, False, False, 0)
        self.pack_start(name, False, False, 0)
        self.pack_start(self.scale, True, True, 0)
        self.pack_start(self.pct, False, False, 0)
        self.paint()

    def paint(self):
        self.glyph.set_text(self.icons[1] if self.muted else self.icons[0])
        for w, cls in ((self.btn, "off"), (self.scale, "muted")):
            ctx = w.get_style_context()
            if self.muted:
                ctx.add_class(cls)
            else:
                ctx.remove_class(cls)

    def changed(self, scale):
        v = int(scale.get_value())
        self.pct.set_text(f"{v}%")
        if self.pending:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(70, self.push, v)

    def push(self, v):
        self.pending = 0
        self.on_vol(v)
        return False

    def on_click(self, *_):
        self.on_mute()
        self.muted = not self.muted
        self.paint()


class AudioMenu(Overlay):
    def __init__(self):
        super().__init__(EXTRA_CSS)
        self.first = None
        card = self.card
        card.set_spacing(10)
        card.pack_start(label("Звук", "title", xalign=0), False, False, 0)

        card.pack_start(label("ВЫВОД", "sect", xalign=0), False, False, 0)
        st = wp_state(SINK)
        if st:
            row = VolRow("Динамики", st[0], st[1], ICON_SPK,
                         lambda v: fire(["wpctl", "set-volume", SINK, f"{v / 100:.2f}"]),
                         lambda: fire(["wpctl", "set-mute", SINK, "toggle"]))
            self.first = row.scale
            card.pack_start(row, False, False, 0)
        else:
            card.pack_start(label("устройство вывода не найдено", "err", xalign=0), False, False, 0)

        card.pack_start(label("МИКРОФОН", "sect", xalign=0), False, False, 6)
        st = wp_state(SOURCE)
        if st:
            row = VolRow("Микрофон", st[0], st[1], ICON_MIC,
                         lambda v: fire(["wpctl", "set-volume", SOURCE, f"{v / 100:.2f}"]),
                         lambda: fire(["wpctl", "set-mute", SOURCE, "toggle"]))
            if self.first is None:
                self.first = row.scale
            card.pack_start(row, False, False, 0)
        else:
            card.pack_start(label("микрофон не найден", "sub", xalign=0), False, False, 0)

        card.pack_start(label("ПРИЛОЖЕНИЯ", "sect", xalign=0), False, False, 6)
        apps = app_streams()
        if apps:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            for a in apps:
                sid = str(a["id"])
                box.pack_start(VolRow(a["name"], a["vol"], a["mute"], ICON_SPK,
                                      lambda v, sid=sid: fire(["pactl", "set-sink-input-volume", sid, f"{v}%"]),
                                      lambda sid=sid: fire(["pactl", "set-sink-input-mute", sid, "toggle"])),
                               False, False, 0)
            sc = Gtk.ScrolledWindow()
            sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            sc.set_propagate_natural_height(True)
            sc.set_max_content_height(240)
            sc.add(box)
            card.pack_start(sc, False, False, 0)
        else:
            card.pack_start(label("сейчас ни одно приложение не играет", "sub", xalign=0), False, False, 0)



if __name__ == "__main__":
    run(AudioMenu)
EOF
chmod 755 /usr/local/bin/audio-menu

cat > /usr/local/bin/network-menu <<'EOF'
#!/usr/bin/python3
import json
import os
import re
import subprocess
import threading
import time
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell
except (ValueError, ImportError):
    GtkLayerShell = None

BAR_GAP = 38  # отступ сверху: высота waybar + небольшой зазор

NAME = "network-menu"
LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), NAME + ".pid")
FA_FONT = "FontAwesome"
BASE_CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(4,7,5,0.60); }
window.popup { background-color: rgba(0,0,0,0); }
.pcard { padding: 14px 16px 12px 16px; border-radius: 16px; }
.card { background-color: rgba(15,20,16,0.90); border: 1px solid rgba(169,204,130,0.45);
border-radius: 20px; padding: 20px 24px 14px 24px; }
.title { color: #e4ebe2; font-size: 14px; }
.sub { color: #8a9a82; font-size: 10px; }
.sect { color: #8a9a82; font-size: 9px; }
.name { color: #e4ebe2; font-size: 11px; }
.pct { color: #a8b8a0; font-size: 10px; }
.err { color: #d98b7d; font-size: 10px; }
.ok { color: #a9cc82; font-size: 10px; }
.hint { color: #75846d; font-size: 9px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover, button:focus { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button.off { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none; padding: 3px 10px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
scale trough { background-color: rgba(169,204,130,0.18); background-image: none; border: none;
border-radius: 4px; min-height: 6px; }
scale highlight { background-color: #a9cc82; background-image: none; border: none; border-radius: 4px; }
scale slider { background-color: #e4ebe2; background-image: none; border: none; box-shadow: none;
border-radius: 50%; min-width: 16px; min-height: 16px; margin: -5px; }
scale.muted highlight { background-color: #75846d; }
scale.muted slider { background-color: #a8b8a0; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; margin: 0; }
scrollbar { background: transparent; border: none; }
"""


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if NAME.encode() in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def apply_css(screen, css):
    for rule in re.findall(rb"[^{}]+\{[^{}]*\}", css):
        prov = Gtk.CssProvider()
        try:
            prov.load_from_data(rule)
        except GLib.Error:
            continue
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def label(text, cls=None, xalign=0.5, chars=None):
    lab = Gtk.Label(label=text, xalign=xalign)
    if cls:
        lab.get_style_context().add_class(cls)
    if chars:
        lab.set_width_chars(chars)
    return lab


class Glyph(Gtk.DrawingArea):
    # иконка рисуется по центру реального контура глифа, а не по рамке строки,
    # поэтому боковые отступы шрифта не сдвигают её вправо
    def __init__(self, text, size, w=40, h=30, cls=None):
        super().__init__()
        self.text, self.size = text, size
        self.set_size_request(w, h)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)
        ctx = self.get_style_context()
        ctx.add_class("icon")
        if cls:
            ctx.add_class(cls)
        self.connect("draw", self.on_draw)

    def set_text(self, text):
        self.text = text
        self.queue_draw()

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        layout = widget.create_pango_layout(self.text)
        fd = Pango.FontDescription()
        fd.set_family(FA_FONT + ",Symbols Nerd Font Mono,Symbols Nerd Font")
        fd.set_absolute_size(self.size * Pango.SCALE)
        layout.set_font_description(fd)
        ink, _logical = layout.get_pixel_extents()
        x = round((alloc.width - ink.width) / 2 - ink.x)
        y = round((alloc.height - ink.height) / 2 - ink.y)
        Gtk.render_layout(widget.get_style_context(), cr, x, y, layout)
        return False


def sh(args, timeout=3, env=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None


def fire(args):
    threading.Thread(target=sh, args=(args,), daemon=True).start()


def use_layer(win):
    """Делает окно слоем поверх всего (layer-shell). False - если не получилось."""
    if GtkLayerShell is None:
        return False
    try:
        if not GtkLayerShell.is_supported():
            return False
        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_namespace(win, NAME)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(win, edge, True)
        GtkLayerShell.set_exclusive_zone(win, -1)
        if hasattr(GtkLayerShell, "KeyboardMode"):
            GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        else:
            GtkLayerShell.set_keyboard_interactivity(win, True)
        return True
    except Exception:
        return False


def pointer_x():
    """X курсора внутри его монитора и ширина монитора (логические пиксели)."""
    try:
        r = sh(["hyprctl", "cursorpos", "-j"], 2)
        try:
            cx = float(json.loads(r.stdout)["x"])
        except ValueError:
            cx = float(re.findall(r"-?\d+", r.stdout)[0])
        mons = json.loads(sh(["hyprctl", "monitors", "-j"], 2).stdout)
        for m in mons:
            sc = float(m.get("scale", 1)) or 1.0
            w = m["width"] / sc
            if m["x"] <= cx < m["x"] + w:
                return cx - m["x"], w
    except Exception:
        pass
    return None, None


def screen_width():
    try:
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        return mon.get_geometry().width
    except Exception:
        return 1920


class Overlay(Gtk.Window):
    def __init__(self, extra_css=b"", popup=True):
        super().__init__(title=NAME)
        self.set_decorated(False)
        self.is_popup = popup
        self.layer = popup and use_layer(self)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        apply_css(screen, BASE_CSS + extra_css)
        if self.layer:
            self.get_style_context().add_class("popup")
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        self.hold = Gtk.EventBox()
        self.hold.set_visible_window(False)
        self.hold.set_halign(Gtk.Align.CENTER)
        self.hold.set_valign(Gtk.Align.CENTER)
        self.hold.connect("button-press-event", lambda w, e: True)
        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        ctx = self.card.get_style_context()
        ctx.add_class("card")
        if self.layer:
            ctx.add_class("pcard")
        self.hold.add(self.card)
        bg.add(self.hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        if not self.layer:
            self.fullscreen()

    def place_card(self):
        """Всплывающее окно: под иконкой, на которую нажали (по позиции курсора)."""
        if not self.layer:
            return
        cx, width = pointer_x()
        if cx is None:
            width = screen_width()
            cx = width - 150
        self.anchor_cx, self.mon_w = cx, width
        self.hold.set_halign(Gtk.Align.START)
        self.hold.set_valign(Gtk.Align.START)
        self.hold.set_margin_top(BAR_GAP)
        self.fit_card(self.card.get_preferred_width()[1])
        # если содержимое потом стало шире (список сетей и т.п.) - сдвигаем обратно в экран
        self.card.connect("size-allocate", lambda w, a: GLib.idle_add(self.fit_card, a.width))

    def fit_card(self, cw):
        x = int(max(8, min(self.anchor_cx - cw / 2, self.mon_w - cw - 8)))
        if x != self.hold.get_margin_start():
            self.hold.set_margin_start(x)

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
            return True
        return self.key(k, ev)

    def key(self, name, ev):
        return False

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def run(cls):
    GLib.set_prgname(NAME)
    GLib.set_application_name(NAME)
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = cls()
    w.connect("destroy", on_destroy)
    w.show_all()      # сначала показываем: у скрытых виджетов ширина считается как 0
    w.place_card()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    first = getattr(w, "first", None)
    if first is not None:
        first.grab_focus()
    Gtk.main()


EXTRA_CSS = b"""
.wifi-list { background-color: transparent; }
.wifi-list row { padding: 6px 8px; margin: 1px 0; border-radius: 9px; background-color: transparent; }
.wifi-list row:hover { background-color: rgba(169,204,130,0.12); }
.wifi-list row:focus { background-color: rgba(169,204,130,0.18); }
.wifi-list row.active { background-color: rgba(125,148,96,0.26); }
.icon.weak { color: #75846d; }
.icon.mid { color: #a8b8a0; }
.icon.good { color: #a9cc82; }
.icon.lock { color: #8a9a82; }
.icon.mark { color: #a9cc82; }
.status-card { background-color: rgba(169,204,130,0.06); border: 1px solid rgba(169,204,130,0.20);
border-radius: 12px; padding: 8px 12px; }
.big { color: #e4ebe2; font-size: 12px; }
button.tool { padding: 2px 6px; border-radius: 9px; }
"""
ENV = dict(os.environ, LC_ALL="C", LANG="C")
WIFI, LOCK_I, CHECK, PLUG, REFRESH = "\uf1eb", "\uf023", "\uf00c", "\uf1e6", "\uf021"


def nm_run(args, timeout=15):
    try:
        r = subprocess.run(["nmcli"] + args, capture_output=True, text=True, timeout=timeout, env=ENV)
    except FileNotFoundError:
        return 127, "", "nmcli не найден (нужен NetworkManager)"
    except subprocess.TimeoutExpired:
        return 124, "", "время ожидания истекло"
    except Exception as e:
        return 1, "", str(e)
    return r.returncode, r.stdout, r.stderr.strip()


def split_nm(line):
    out, cur, i = [], "", 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line):
            cur += line[i + 1]
            i += 2
            continue
        if c == ":":
            out.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    out.append(cur)
    return out


def friendly(err):
    e = (err or "").strip().splitlines()
    text = e[-1] if e else "неизвестная ошибка"
    low = text.lower()
    if "no network with ssid" in low:
        return "Сеть не найдена, обнови список"
    if "secrets were required" in low or "password" in low or "802-1x" in low:
        return "Неверный пароль или нужна авторизация"
    if "timeout" in low or ("time" in low and "expired" in low):
        return "Не удалось подключиться за отведённое время"
    return text


def gather():
    info = {"ok": True, "radio": True, "active": [], "wifi": [], "saved": set(), "err": "", "wdev": ""}
    rc, out, err = nm_run(["-t", "-f", "RUNNING", "general"], 5)
    if rc != 0 or out.strip() != "running":
        info["ok"] = False
        info["err"] = err or "NetworkManager не запущен"
        return info
    _, out, _ = nm_run(["radio", "wifi"], 5)
    info["radio"] = out.strip() == "enabled"
    _, out, _ = nm_run(["-t", "-f", "NAME,TYPE", "connection", "show"], 8)
    for line in out.splitlines():
        f = split_nm(line)
        if len(f) >= 2 and f[1] == "802-11-wireless":
            info["saved"].add(f[0])
    wifi = []
    if info["radio"]:
        _, out, _ = nm_run(["-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "device", "wifi", "list"], 20)
        best = {}
        for line in out.splitlines():
            f = split_nm(line)
            if len(f) < 4 or not f[3]:
                continue
            ssid = f[3]
            try:
                sig = int(f[1])
            except ValueError:
                sig = 0
            item = {"ssid": ssid, "signal": sig, "secured": f[2] not in ("", "--"), "active": f[0] == "*"}
            old = best.get(ssid)
            if old is None or item["active"] or (not old["active"] and sig > old["signal"]):
                best[ssid] = item
        wifi = sorted(best.values(), key=lambda i: (not i["active"], -i["signal"], i["ssid"].lower()))
    info["wifi"] = wifi
    _, out, _ = nm_run(["-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], 8)
    for line in out.splitlines():
        f = split_nm(line)
        if len(f) < 4:
            continue
        dev, typ, state, conn = f[0], f[1], f[2], f[3]
        if typ == "wifi" and not info["wdev"]:
            info["wdev"] = dev
        if state != "connected" or typ not in ("wifi", "ethernet"):
            continue
        ip = ""
        _, o2, _ = nm_run(["-t", "-f", "IP4.ADDRESS", "device", "show", dev], 5)
        for l2 in o2.splitlines():
            p = split_nm(l2)
            if len(p) >= 2 and p[1]:
                ip = p[1].split("/")[0]
                break
        sig = next((w["signal"] for w in wifi if w["active"]), None) if typ == "wifi" else None
        info["active"].append({"dev": dev, "type": typ, "name": conn, "ip": ip, "signal": sig})
    return info


class NetMenu(Overlay):
    def __init__(self):
        super().__init__(EXTRA_CSS)
        self.first = None
        self.busy = False
        self.info = None
        self.pending = None
        self.skip_switch = False
        self.note = None
        card = self.card
        card.set_spacing(10)
        card.set_size_request(340, -1)

        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        head.pack_start(label("Сеть", "title", xalign=0), True, True, 0)
        head.pack_start(label("Wi-Fi", "sub"), False, False, 0)
        self.switch = Gtk.Switch()
        self.switch.set_valign(Gtk.Align.CENTER)
        self.switch.connect("notify::active", self.on_switch)
        head.pack_start(self.switch, False, False, 0)
        card.pack_start(head, False, False, 0)

        self.status_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.status_box.get_style_context().add_class("status-card")
        card.pack_start(self.status_box, False, False, 0)

        sec = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        sec.pack_start(label("ДОСТУПНЫЕ СЕТИ", "sect", xalign=0), True, True, 0)
        self.b_refresh = Gtk.Button()
        self.b_refresh.get_style_context().add_class("tool")
        self.b_refresh.add(Glyph(REFRESH, 12, 18, 16))
        self.b_refresh.set_tooltip_text("Обновить список")
        self.b_refresh.connect("clicked", lambda *_: self.refresh(True))
        sec.pack_start(self.b_refresh, False, False, 0)
        card.pack_start(sec, False, False, 0)

        self.list = Gtk.ListBox()
        self.list.set_selection_mode(Gtk.SelectionMode.NONE)
        self.list.set_activate_on_single_click(True)
        self.list.get_style_context().add_class("wifi-list")
        self.list.connect("row-activated", self.on_row)
        sc = Gtk.ScrolledWindow()
        sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sc.set_min_content_height(80)
        sc.set_max_content_height(210)
        sc.set_propagate_natural_height(True)
        sc.add(self.list)
        card.pack_start(sc, False, False, 0)

        # ввод пароля (появляется при выборе защищённой сети)
        self.pw_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.pw_title = label("", "name", xalign=0)
        self.pw_title.set_ellipsize(Pango.EllipsizeMode.END)
        self.pw_title.set_max_width_chars(34)
        self.pw_entry = Gtk.Entry()
        self.pw_entry.set_visibility(False)
        self.pw_entry.set_placeholder_text("Пароль")
        self.pw_entry.connect("activate", lambda *_: self.submit_password())
        pw_btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        ok = Gtk.Button(label="Подключить")
        ok.connect("clicked", lambda *_: self.submit_password())
        cancel = Gtk.Button(label="Отмена")
        cancel.connect("clicked", lambda *_: self.hide_password())
        show = Gtk.CheckButton(label="показать")
        show.connect("toggled", lambda b: self.pw_entry.set_visibility(b.get_active()))
        pw_btns.pack_start(ok, False, False, 0)
        pw_btns.pack_start(cancel, False, False, 0)
        pw_btns.pack_end(show, False, False, 0)
        self.pw_box.pack_start(self.pw_title, False, False, 0)
        self.pw_box.pack_start(self.pw_entry, False, False, 0)
        self.pw_box.pack_start(pw_btns, False, False, 0)
        card.pack_start(self.pw_box, False, False, 0)

        self.msg = label("", "sub", xalign=0)
        self.msg.set_line_wrap(True)
        self.msg.set_max_width_chars(44)
        card.pack_start(self.msg, False, False, 0)

        self.b_disc = Gtk.Button(label="Отключиться от Wi-Fi")
        self.b_disc.connect("clicked", lambda *_: self.leave())
        card.pack_start(self.b_disc, False, False, 0)
        self.first = self.list
        GLib.idle_add(self.pw_box.hide)
        GLib.idle_add(self.refresh, False)

    # ---------- сообщения ----------
    def say(self, text, kind="sub"):
        ctx = self.msg.get_style_context()
        for c in ("sub", "err", "ok"):
            ctx.remove_class(c)
        ctx.add_class(kind)
        self.msg.set_text(text)
        return False

    # ---------- обновление ----------
    def refresh(self, rescan=False):
        if self.busy:
            return False
        self.busy = True
        self.say("Ищу сети…" if rescan else "Обновляю…")

        def work():
            if rescan:
                nm_run(["device", "wifi", "rescan"], 10)
                time.sleep(2.5)
            info = gather()
            GLib.idle_add(self.apply, info)
        threading.Thread(target=work, daemon=True).start()
        return False

    def apply(self, info):
        self.busy = False
        self.info = info
        for c in self.status_box.get_children():
            self.status_box.remove(c)
        if not info["ok"]:
            self.status_box.pack_start(label("Нет связи с NetworkManager", "big", xalign=0), False, False, 0)
            self.status_box.pack_start(label(info["err"], "err", xalign=0), False, False, 0)
        elif not info["active"]:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            row.pack_start(Glyph(WIFI, 16, 26, 26, "weak"), False, False, 0)
            row.pack_start(label("Нет подключения", "big", xalign=0), True, True, 0)
            self.status_box.pack_start(row, False, False, 0)
        for a in info["active"]:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            row.pack_start(Glyph(WIFI if a["type"] == "wifi" else PLUG, 16, 26, 26, "good"), False, False, 0)
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
            name = label(a["name"], "big", xalign=0)
            name.set_ellipsize(Pango.EllipsizeMode.END)
            name.set_max_width_chars(28)
            col.pack_start(name, False, False, 0)
            bits = ["Wi-Fi" if a["type"] == "wifi" else "Кабель · " + a["dev"]]
            if a["signal"] is not None:
                bits.append(f"{a['signal']}%")
            if a["ip"]:
                bits.append(a["ip"])
            col.pack_start(label("  ·  ".join(bits), "sub", xalign=0), False, False, 0)
            row.pack_start(col, True, True, 0)
            self.status_box.pack_start(row, False, False, 0)
        self.status_box.show_all()

        self.skip_switch = True
        self.switch.set_active(info["radio"])
        self.skip_switch = False
        self.switch.set_sensitive(info["ok"])

        for c in self.list.get_children():
            self.list.remove(c)
        for w in info["wifi"]:
            self.list.add(self.make_row(w))
        self.list.show_all()
        has_wifi = any(a["type"] == "wifi" for a in info["active"])
        self.b_disc.set_visible(has_wifi)
        self.b_disc.set_no_show_all(not has_wifi)
        if self.note:
            self.say(*self.note)
            self.note = None
        elif not info["ok"]:
            self.say("")
        elif not info["radio"]:
            self.say("Wi-Fi выключен")
        elif not info["wifi"]:
            self.say("Сети не найдены, попробуй обновить")
        else:
            self.say("")
        return False

    def make_row(self, w):
        row = Gtk.ListBoxRow()
        row.ssid, row.secured, row.is_active = w["ssid"], w["secured"], w["active"]
        row.set_tooltip_text(f"{w['ssid']} · {w['signal']}%")
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        s = w["signal"]
        cls = "good" if s >= 60 else ("mid" if s >= 35 else "weak")
        box.pack_start(Glyph(WIFI, 14, 22, 18, cls), False, False, 0)
        name = label(w["ssid"], "name", xalign=0)
        name.set_ellipsize(Pango.EllipsizeMode.END)
        name.set_max_width_chars(26)
        box.pack_start(name, True, True, 0)
        if w["secured"]:
            box.pack_start(Glyph(LOCK_I, 11, 16, 16, "lock"), False, False, 0)
        if w["active"]:
            box.pack_start(Glyph(CHECK, 12, 16, 16, "mark"), False, False, 0)
            row.get_style_context().add_class("active")
        row.add(box)
        return row

    # ---------- действия ----------
    def on_switch(self, sw, _p):
        if self.skip_switch:
            return
        state = "on" if sw.get_active() else "off"
        self.say("Включаю Wi-Fi…" if state == "on" else "Выключаю Wi-Fi…")

        def work():
            nm_run(["radio", "wifi", state], 10)
            time.sleep(1.5 if state == "on" else 0.3)
            GLib.idle_add(self.after_toggle)
        threading.Thread(target=work, daemon=True).start()

    def after_toggle(self):
        self.busy = False
        self.refresh(False)
        return False

    def on_row(self, box, row):
        if self.busy or row.is_active:
            return
        ssid = row.ssid
        if ssid in (self.info or {}).get("saved", set()):
            self.join(ssid, None, True)
        elif not row.secured:
            self.join(ssid, None, False)
        else:
            self.show_password(ssid)

    def show_password(self, ssid):
        self.pending = ssid
        self.pw_title.set_text(f"Пароль для «{ssid}»")
        self.pw_entry.set_text("")
        self.pw_box.show_all()
        self.pw_entry.grab_focus()

    def hide_password(self):
        self.pending = None
        self.pw_box.hide()
        self.list.grab_focus()

    def submit_password(self):
        pw = self.pw_entry.get_text()
        ssid = self.pending
        if not ssid or not pw:
            return
        self.pw_box.hide()
        self.join(ssid, pw, False)

    def join(self, ssid, password, saved):
        if self.busy:
            return
        self.busy = True
        self.say(f"Подключаюсь к «{ssid}»…")

        def work():
            if password:
                rc, _, err = nm_run(["device", "wifi", "connect", ssid, "password", password], 45)
                if rc != 0:
                    nm_run(["connection", "delete", "id", ssid], 8)  # не оставлять битый профиль
            elif saved:
                rc, _, err = nm_run(["connection", "up", "id", ssid], 45)
            else:
                rc, _, err = nm_run(["device", "wifi", "connect", ssid], 45)
                if rc != 0:
                    nm_run(["connection", "delete", "id", ssid], 8)
            GLib.idle_add(self.after_join, ssid, rc, err, saved)
        threading.Thread(target=work, daemon=True).start()

    def after_join(self, ssid, rc, err, saved):
        self.busy = False
        if rc == 0:
            self.note = (f"Подключено: {ssid}", "ok")
        else:
            text = friendly(err)
            if saved and "пароль" in text.lower():
                self.show_password(ssid)
            self.note = (f"{ssid}: {text}", "err")
        self.refresh(False)
        return False

    def leave(self):
        if self.busy or not self.info:
            return
        dev = next((a["dev"] for a in self.info["active"] if a["type"] == "wifi"), "")
        if not dev:
            return
        self.busy = True
        self.say("Отключаюсь…")

        def work():
            rc, _, err = nm_run(["device", "disconnect", dev], 15)
            GLib.idle_add(self.after_leave, rc, err)
        threading.Thread(target=work, daemon=True).start()

    def after_leave(self, rc, err):
        self.busy = False
        if rc != 0:
            self.note = (friendly(err), "err")
        self.refresh(False)
        return False


if __name__ == "__main__":
    run(NetMenu)
EOF
chmod 755 /usr/local/bin/network-menu

cat > /usr/local/bin/year-calendar <<'EOF'
#!/usr/bin/python3
import json
import os
import re
import subprocess
import threading
import time
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

try:
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import GtkLayerShell
except (ValueError, ImportError):
    GtkLayerShell = None

BAR_GAP = 38  # отступ сверху: высота waybar + небольшой зазор

NAME = "year-calendar"
LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), NAME + ".pid")
FA_FONT = "FontAwesome"
BASE_CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(4,7,5,0.60); }
window.popup { background-color: rgba(0,0,0,0); }
.pcard { padding: 14px 16px 12px 16px; border-radius: 16px; }
.card { background-color: rgba(15,20,16,0.90); border: 1px solid rgba(169,204,130,0.45);
border-radius: 20px; padding: 20px 24px 14px 24px; }
.title { color: #e4ebe2; font-size: 14px; }
.sub { color: #8a9a82; font-size: 10px; }
.sect { color: #8a9a82; font-size: 9px; }
.name { color: #e4ebe2; font-size: 11px; }
.pct { color: #a8b8a0; font-size: 10px; }
.err { color: #d98b7d; font-size: 10px; }
.ok { color: #a9cc82; font-size: 10px; }
.hint { color: #75846d; font-size: 9px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover, button:focus { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button.off { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none; padding: 3px 10px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
scale trough { background-color: rgba(169,204,130,0.18); background-image: none; border: none;
border-radius: 4px; min-height: 6px; }
scale highlight { background-color: #a9cc82; background-image: none; border: none; border-radius: 4px; }
scale slider { background-color: #e4ebe2; background-image: none; border: none; box-shadow: none;
border-radius: 50%; min-width: 16px; min-height: 16px; margin: -5px; }
scale.muted highlight { background-color: #75846d; }
scale.muted slider { background-color: #a8b8a0; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; margin: 0; }
scrollbar { background: transparent; border: none; }
"""


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if NAME.encode() in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def apply_css(screen, css):
    for rule in re.findall(rb"[^{}]+\{[^{}]*\}", css):
        prov = Gtk.CssProvider()
        try:
            prov.load_from_data(rule)
        except GLib.Error:
            continue
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def label(text, cls=None, xalign=0.5, chars=None):
    lab = Gtk.Label(label=text, xalign=xalign)
    if cls:
        lab.get_style_context().add_class(cls)
    if chars:
        lab.set_width_chars(chars)
    return lab


class Glyph(Gtk.DrawingArea):
    # иконка рисуется по центру реального контура глифа, а не по рамке строки,
    # поэтому боковые отступы шрифта не сдвигают её вправо
    def __init__(self, text, size, w=40, h=30, cls=None):
        super().__init__()
        self.text, self.size = text, size
        self.set_size_request(w, h)
        self.set_halign(Gtk.Align.CENTER)
        self.set_valign(Gtk.Align.CENTER)
        ctx = self.get_style_context()
        ctx.add_class("icon")
        if cls:
            ctx.add_class(cls)
        self.connect("draw", self.on_draw)

    def set_text(self, text):
        self.text = text
        self.queue_draw()

    def on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        layout = widget.create_pango_layout(self.text)
        fd = Pango.FontDescription()
        fd.set_family(FA_FONT + ",Symbols Nerd Font Mono,Symbols Nerd Font")
        fd.set_absolute_size(self.size * Pango.SCALE)
        layout.set_font_description(fd)
        ink, _logical = layout.get_pixel_extents()
        x = round((alloc.width - ink.width) / 2 - ink.x)
        y = round((alloc.height - ink.height) / 2 - ink.y)
        Gtk.render_layout(widget.get_style_context(), cr, x, y, layout)
        return False


def sh(args, timeout=3, env=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None


def fire(args):
    threading.Thread(target=sh, args=(args,), daemon=True).start()


def use_layer(win):
    """Делает окно слоем поверх всего (layer-shell). False - если не получилось."""
    if GtkLayerShell is None:
        return False
    try:
        if not GtkLayerShell.is_supported():
            return False
        GtkLayerShell.init_for_window(win)
        GtkLayerShell.set_namespace(win, NAME)
        GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY)
        for edge in (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.BOTTOM,
                     GtkLayerShell.Edge.LEFT, GtkLayerShell.Edge.RIGHT):
            GtkLayerShell.set_anchor(win, edge, True)
        GtkLayerShell.set_exclusive_zone(win, -1)
        if hasattr(GtkLayerShell, "KeyboardMode"):
            GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE)
        else:
            GtkLayerShell.set_keyboard_interactivity(win, True)
        return True
    except Exception:
        return False


def pointer_x():
    """X курсора внутри его монитора и ширина монитора (логические пиксели)."""
    try:
        r = sh(["hyprctl", "cursorpos", "-j"], 2)
        try:
            cx = float(json.loads(r.stdout)["x"])
        except ValueError:
            cx = float(re.findall(r"-?\d+", r.stdout)[0])
        mons = json.loads(sh(["hyprctl", "monitors", "-j"], 2).stdout)
        for m in mons:
            sc = float(m.get("scale", 1)) or 1.0
            w = m["width"] / sc
            if m["x"] <= cx < m["x"] + w:
                return cx - m["x"], w
    except Exception:
        pass
    return None, None


def screen_width():
    try:
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        return mon.get_geometry().width
    except Exception:
        return 1920


class Overlay(Gtk.Window):
    def __init__(self, extra_css=b"", popup=True):
        super().__init__(title=NAME)
        self.set_decorated(False)
        self.is_popup = popup
        self.layer = popup and use_layer(self)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        apply_css(screen, BASE_CSS + extra_css)
        if self.layer:
            self.get_style_context().add_class("popup")
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        self.hold = Gtk.EventBox()
        self.hold.set_visible_window(False)
        self.hold.set_halign(Gtk.Align.CENTER)
        self.hold.set_valign(Gtk.Align.CENTER)
        self.hold.connect("button-press-event", lambda w, e: True)
        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        ctx = self.card.get_style_context()
        ctx.add_class("card")
        if self.layer:
            ctx.add_class("pcard")
        self.hold.add(self.card)
        bg.add(self.hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        if not self.layer:
            self.fullscreen()

    def place_card(self):
        """Всплывающее окно: под иконкой, на которую нажали (по позиции курсора)."""
        if not self.layer:
            return
        cx, width = pointer_x()
        if cx is None:
            width = screen_width()
            cx = width - 150
        self.anchor_cx, self.mon_w = cx, width
        self.hold.set_halign(Gtk.Align.START)
        self.hold.set_valign(Gtk.Align.START)
        self.hold.set_margin_top(BAR_GAP)
        self.fit_card(self.card.get_preferred_width()[1])
        # если содержимое потом стало шире (список сетей и т.п.) - сдвигаем обратно в экран
        self.card.connect("size-allocate", lambda w, a: GLib.idle_add(self.fit_card, a.width))

    def fit_card(self, cw):
        x = int(max(8, min(self.anchor_cx - cw / 2, self.mon_w - cw - 8)))
        if x != self.hold.get_margin_start():
            self.hold.set_margin_start(x)

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
            return True
        return self.key(k, ev)

    def key(self, name, ev):
        return False

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def run(cls):
    GLib.set_prgname(NAME)
    GLib.set_application_name(NAME)
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = cls()
    w.connect("destroy", on_destroy)
    w.show_all()      # сначала показываем: у скрытых виджетов ширина считается как 0
    w.place_card()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    first = getattr(w, "first", None)
    if first is not None:
        first.grab_focus()
    Gtk.main()


import calendar
import datetime

EXTRA_CSS = b"""
.ycard { padding: 18px 24px 14px 24px; }
.year { color: #e4ebe2; font-size: 20px; }
.mon { background-color: rgba(169,204,130,0.04); border: 1px solid rgba(169,204,130,0.15);
border-radius: 14px; padding: 8px 10px 8px 10px; }
.mon.cur { border-color: rgba(169,204,130,0.55); background-color: rgba(169,204,130,0.08); }
.mtitle { color: #a9cc82; font-size: 12px; }
.mon.cur .mtitle { color: #c4dfa0; }
.wd { color: #8a9a82; font-size: 9px; }
.wd.we { color: #b07d74; }
.day { color: #e4ebe2; font-size: 11px; border-radius: 11px; }
.day.we { color: #d98b7d; }
.day.today { background-color: #a9cc82; color: #0f1410; }
button.nav { padding: 2px 8px; }
"""
MONTHS = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
          "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"]
WEEKDAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
LEFT, RIGHT = "\uf053", "\uf054"


def screen_height():
    try:
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        return mon.get_geometry().height
    except Exception:
        return 1080


class YearCal(Overlay):
    def __init__(self):
        super().__init__(EXTRA_CSS, popup=False)
        self.first = None
        self.today = datetime.date.today()
        self.year = self.today.year
        tall = screen_height() >= 900
        self.dw, self.dh = (28, 22) if tall else (24, 18)
        card = self.card
        card.get_style_context().add_class("ycard")
        card.set_spacing(12)
        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.b_prev = self.nav_button(LEFT, -1)
        self.b_next = self.nav_button(RIGHT, 1)
        self.year_lbl = label("", "year")
        today_btn = Gtk.Button(label="Сегодня")
        today_btn.connect("clicked", lambda *_: self.go_today())
        head.pack_start(self.b_prev, False, False, 0)
        head.pack_start(self.year_lbl, False, False, 6)
        head.pack_start(self.b_next, False, False, 0)
        head.pack_end(today_btn, False, False, 0)
        card.pack_start(head, False, False, 0)
        self.holder = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        card.pack_start(self.holder, False, False, 0)
        card.pack_start(label("← →  год    Home  сегодня    Esc  закрыть", "hint"), False, False, 0)
        self.first = today_btn
        self.render_year()

    def nav_button(self, glyph, step):
        b = Gtk.Button()
        b.get_style_context().add_class("nav")
        b.add(Glyph(glyph, 13, 22, 22))
        b.connect("clicked", lambda *_: self.shift(step))
        return b

    def shift(self, step):
        y = self.year + step
        if 1 <= y <= 9998:
            self.year = y
            self.render_year()

    def go_today(self):
        self.year = self.today.year
        self.render_year()

    def key(self, name, ev):
        if name in ("Left", "Page_Up", "Up"):
            self.shift(-1)
        elif name in ("Right", "Page_Down", "Down"):
            self.shift(1)
        elif name == "Home":
            self.go_today()
        else:
            return False
        return True

    def render_year(self):
        for c in self.holder.get_children():
            self.holder.remove(c)
            c.destroy()
        grid = Gtk.Grid()
        grid.set_column_spacing(14)
        grid.set_row_spacing(14)
        grid.set_column_homogeneous(True)
        for m in range(1, 13):
            grid.attach(self.month(m), (m - 1) % 4, (m - 1) // 4, 1, 1)
        self.holder.pack_start(grid, False, False, 0)
        self.year_lbl.set_text(str(self.year))
        self.holder.show_all()

    def month(self, m):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        ctx = box.get_style_context()
        ctx.add_class("mon")
        if (self.year, m) == (self.today.year, self.today.month):
            ctx.add_class("cur")
        box.pack_start(label(MONTHS[m - 1], "mtitle", xalign=0), False, False, 0)
        g = Gtk.Grid()
        g.set_column_spacing(2)
        g.set_row_spacing(2)
        for i, w in enumerate(WEEKDAYS):
            lab = label(w, "wd")
            if i >= 5:
                lab.get_style_context().add_class("we")
            lab.set_size_request(self.dw, 16)
            g.attach(lab, i, 0, 1, 1)
        weeks = calendar.monthcalendar(self.year, m)
        while len(weeks) < 6:
            weeks.append([0] * 7)
        for r, wk in enumerate(weeks):
            for c, d in enumerate(wk):
                lab = label(str(d) if d else "", "day")
                lab.set_size_request(self.dw, self.dh)
                lc = lab.get_style_context()
                if c >= 5:
                    lc.add_class("we")
                if d and datetime.date(self.year, m, d) == self.today:
                    lc.add_class("today")
                g.attach(lab, c, r + 1, 1, 1)
        box.pack_start(g, False, False, 0)
        return box


if __name__ == "__main__":
    run(YearCal)
EOF
chmod 755 /usr/local/bin/year-calendar

cat > /usr/local/bin/volume-click <<'EOF'
#!/bin/sh
# одиночный клик по значку громкости - вкл/выкл звук; быстрый двойной - меню громкости
f="${XDG_RUNTIME_DIR:-/tmp}/volume-click.ts"
now=$(date +%s%N)
if [ -f "$f" ]; then
  prev=$(cat "$f" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ $((now - prev)) -lt 450000000 ]; then
    rm -f "$f"
    exec /usr/local/bin/audio-menu
  fi
fi
echo "$now" > "$f"
sleep 0.45
if [ "$(cat "$f" 2>/dev/null)" = "$now" ]; then
  rm -f "$f"
  wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
fi
EOF
chmod 755 /usr/local/bin/volume-click

cat > /usr/local/bin/performance-status <<'EOF'
#!/usr/bin/python3
import json
import subprocess

INFO = {
    "power-saver": ("\uf06c", "Энергосбережение"),
    "balanced": ("\uf24e", "Баланс"),
    "performance": ("\uf0e7", "Производительность"),
}

try:
    cur = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True, timeout=3).stdout.strip()
except Exception:
    cur = ""

if cur in INFO:
    icon, name = INFO[cur]
    out = {"text": icon, "tooltip": "Профиль питания: " + name, "class": cur}
else:
    out = {"text": "\uf0e7", "tooltip": "Профиль питания: служба недоступна", "class": "unknown"}
print(json.dumps(out, ensure_ascii=False))
EOF
chmod 755 /usr/local/bin/performance-status

# ================= конфиги пользователя =================
# w ФАЙЛ - записать stdin в файл (старую версию один раз сохраняет в .bak)
w() {
  mkdir -p "$(dirname "$1")"
  if [ -f "$1" ] && [ ! -f "$1.bak" ]; then cp -p "$1" "$1.bak"; fi
  cat > "$1"
}
rm -f "$H/.config/hypr/quick-kill.sh"
[ ! -f "$H/.config/hypr/hyprland.conf" ] || mv "$H/.config/hypr/hyprland.conf" "$H/.config/hypr/hyprland.conf.old"

# ---------- Hyprland ----------
w "$H/.config/hypr/hyprland.lua" <<'EOF'
local mod = "SUPER"

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.on("hyprland.start", function()
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
  hl.exec_cmd("sh ~/.config/hypr/wallpaper.sh")
  hl.exec_cmd("waybar")
  hl.exec_cmd("lxqt-policykit-agent")
end)

hl.config({
  input = {
    kb_layout = "us,ru",
    kb_options = "grp:alt_shift_toggle",
    follow_mouse = 1,
    repeat_rate = 40,
    repeat_delay = 250,
    touchpad = { natural_scroll = true },
  },
  general = {
    gaps_in = 6,       -- между окнами
    gaps_out = 14,     -- от краёв экрана до окон
    border_size = 1,
    col = {
      active_border = "rgba(a9cc82ee)",
      inactive_border = "rgba(3a4a33aa)",
    },
    layout = "dwindle",
  },
  dwindle = {
    preserve_split = true,  -- раскладка не «прыгает» при закрытии окон
    force_split = 2,        -- новое окно встаёт справа/снизу, экран делится пополам
  },
  decoration = {
    rounding = 8,
    active_opacity = 1.0,
    inactive_opacity = 0.95,
    blur = { enabled = true, size = 6, passes = 3 },
  },
  animations = { enabled = true },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    on_focus_under_fullscreen = 2,  -- новое окно не прячется за полноэкранным
  },
})

hl.curve("ease", { type = "bezier", points = { {0.22, 1}, {0.36, 1} } })
hl.animation({ leaf = "windows",    enabled = true, speed = 5, bezier = "ease", style = "slide" })
hl.animation({ leaf = "fade",       enabled = true, speed = 5, bezier = "ease" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "ease", style = "slide" })

hl.bind(mod .. " + Return", hl.dsp.exec_cmd("alacritty -e sh ~/.config/fastfetch/show.sh"))
hl.bind(mod .. " + D", hl.dsp.exec_cmd("/usr/local/bin/launcher.sh"))
hl.bind(mod .. " + B", hl.dsp.exec_cmd("firefox"))
hl.bind(mod .. " + E", hl.dsp.exec_cmd("/usr/local/bin/files"))
hl.bind(mod .. " + W", hl.dsp.exec_cmd("sh ~/.config/hypr/wallpaper.sh next"))
hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + Q", hl.dsp.window.close(), { repeating = true })
hl.bind(mod .. " + SHIFT + Escape", hl.dsp.exec_cmd("/usr/local/bin/power-menu"))
hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))

for _, d in ipairs({ "left", "right", "up", "down" }) do
  hl.bind(mod .. " + " .. d, hl.dsp.focus({ direction = d }))
  hl.bind(mod .. " + SHIFT + " .. d, hl.dsp.window.move({ direction = d }))
end

hl.bind(mod .. " + CTRL + left",  hl.dsp.window.resize({ x = -40, y = 0,  relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + right", hl.dsp.window.resize({ x = 40,  y = 0,  relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + up",    hl.dsp.window.resize({ x = 0,   y = -40, relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + down",  hl.dsp.window.resize({ x = 0,   y = 40,  relative = true }), { repeating = true })

hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

for i = 1, 5 do
  hl.bind(mod .. " + " .. i, hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mod .. " + Tab", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mod .. " + Space", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))
hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { locked = true, repeating = true })

hl.window_rule({ name = "float-wofi", match = { class = "^(wofi)$" }, float = true })
hl.window_rule({ name = "float-power-menu", match = { class = "^(power-menu)$" }, float = true })
hl.window_rule({ name = "float-performance-menu", match = { class = "^(performance-menu)$" }, float = true })
hl.window_rule({ name = "float-audio-menu", match = { class = "^(audio-menu)$" }, float = true })
hl.window_rule({ name = "float-network-menu", match = { class = "^(network-menu)$" }, float = true })
hl.window_rule({ name = "float-year-calendar", match = { class = "^(year-calendar)$" }, float = true })
hl.window_rule({ name = "float-meta-clean", match = { class = "^(meta-clean)$" }, float = true })
EOF

# ---------- alacritty ----------
w "$H/.config/alacritty/alacritty.toml" <<'EOF'
[window]
decorations = "none"
opacity = 0.65

[colors.primary]
background = "#0a0e0a"
foreground = "#dfe8d8"

[font]
size = 11.0
EOF

# ---------- cava (запуск только из терминала: cava) ----------
w "$H/.config/cava/config" <<'EOF'
[general]
bar_width = 2
bar_spacing = 1

[color]
gradient = 1
gradient_count = 4
gradient_color_1 = '#2c3d22'
gradient_color_2 = '#4a6634'
gradient_color_3 = '#6e944f'
gradient_color_4 = '#a9cc82'
EOF

# ---------- waybar: одна тонкая полоса сверху ----------
w "$H/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 32,
  "spacing": 4,
  "modules-left": ["custom/launcher", "hyprland/workspaces"],
  "modules-center": ["clock#time", "clock#date"],
  "modules-right": ["hyprland/language", "network", "pulseaudio", "backlight", "battery", "custom/performance"],
  "custom/launcher": {
    "format": "◈",
    "tooltip": true,
    "tooltip-format": "Приложения",
    "on-click": "/usr/local/bin/hypr-launcher"
  },
  "hyprland/workspaces": {
    "format": "{name}",
    "on-click": "activate",
    "all-outputs": true,
    "disable-scroll": true,
    "persistent-workspaces": {
      "*": 5
    }
  },
  "clock#time": {
    "format": "󰥔  {:%H:%M}",
    "tooltip": true,
    "tooltip-format": "<tt><small>{calendar}</small></tt>",
    "calendar": {
      "mode": "month",
      "mode-mon-col": 3,
      "weeks-pos": "right",
      "on-scroll": 1,
      "format": {
        "months": "<span color='#c4dfa0'><b>{}</b></span>",
        "days": "<span color='#e4ebe2'>{}</span>",
        "weeks": "<span color='#6e944f'>W{}</span>",
        "weekdays": "<span color='#a9cc82'><b>{}</b></span>",
        "today": "<span color='#c4dfa0'><b><u>{}</u></b></span>"
      }
    },
    "actions": {
      "on-click": "mode",
      "on-click-right": "shift_reset",
      "on-scroll-up": "shift_up",
      "on-scroll-down": "shift_down"
    }
  },
  "clock#date": {
    "format": "{:%a %d %b}",
    "tooltip": true,
    "tooltip-format": "<tt><small>{calendar}</small></tt>",
    "calendar": {
      "mode": "month",
      "mode-mon-col": 3,
      "weeks-pos": "right",
      "on-scroll": 1,
      "format": {
        "months": "<span color='#c4dfa0'><b>{}</b></span>",
        "days": "<span color='#e4ebe2'>{}</span>",
        "weeks": "<span color='#6e944f'>W{}</span>",
        "weekdays": "<span color='#a9cc82'><b>{}</b></span>",
        "today": "<span color='#c4dfa0'><b><u>{}</u></b></span>"
      }
    },
    "actions": {
      "on-click-right": "shift_reset",
      "on-scroll-up": "shift_up",
      "on-scroll-down": "shift_down"
    },
    "on-click": "/usr/local/bin/year-calendar"
  },
  "hyprland/language": {
    "format": "󰌌  {short}",
    "tooltip": true
  },
  "network": {
    "format-wifi": "{icon}",
    "format-ethernet": "󰈀",
    "format-linked": "󰈀",
    "format-disconnected": "󰤮",
    "format-disabled": "󰤮",
    "format-icons": ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"],
    "tooltip-format-wifi": "{essid} · {signalStrength}%\n{ipaddr}",
    "tooltip-format-ethernet": "{ifname}\n{ipaddr}",
    "tooltip-format-disconnected": "Нет подключения",
    "interval": 5,
    "on-click": "/usr/local/bin/network-menu"
  },
  "pulseaudio": {
    "format": "{icon}  {volume}%",
    "format-muted": "󰖁  0%",
    "format-icons": {
      "default": ["󰕿", "󰖀", "󰕾"]
    },
    "scroll-step": 5,
    "max-volume": 100,
    "on-click": "/usr/local/bin/volume-click",
    "on-scroll-up": "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+",
    "on-scroll-down": "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
  },
  "backlight": {
    "format": "{icon}  {percent}%",
    "format-icons": ["󰃞", "󰃟", "󰃠"],
    "on-scroll-up": "brightnessctl set 5%+",
    "on-scroll-down": "brightnessctl set 5%-"
  },
  "battery": {
    "format": "{icon}  {capacity}%",
    "format-charging": "󰂄  {capacity}%",
    "format-plugged": "󰚥  {capacity}%",
    "format-icons": ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"],
    "states": {
      "warning": 25,
      "critical": 10
    }
  },
  "custom/performance": {
    "format": "󱐋",
    "tooltip": true,
    "tooltip-format": "Профиль питания",
    "on-click": "/usr/local/bin/performance-menu"
  }
}
EOF

w "$H/.config/waybar/style.css" <<'EOF'
* { font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", "DejaVu Sans", sans-serif; font-size: 11.5px; border: none; min-height: 0; }
window#waybar { background: rgba(15, 20, 16, 0.92); color: #e4ebe2; border-bottom: 1px solid rgba(169, 204, 130, 0.30); }
#custom-launcher { color: #a9cc82; background: transparent; padding: 0 10px 0 12px; margin: 4px 2px; border-radius: 6px; font-size: 13px; }
#custom-launcher:hover { background: rgba(169, 204, 130, 0.18); color: #c4dfa0; }
#workspaces button { color: #a8b8a0; background: transparent; padding: 0 9px; margin: 4px 2px; border-radius: 6px; transition: all 0.2s ease; }
#workspaces button.active { background: #a9cc82; color: #0f1410; font-weight: 700; }
#workspaces button:hover { background: rgba(169, 204, 130, 0.18); color: #e4ebe2; }
#workspaces button.urgent { background: #d98b7d; color: #0f1410; font-weight: 700; }
#clock { color: #e4ebe2; font-size: 13.5px; font-weight: 700; padding: 0 6px; letter-spacing: 0.2px; }
#clock.time { padding: 0 2px 0 14px; }
#clock.date { color: #a8b8a0; font-size: 12.5px; font-weight: 600; padding: 0 12px 0 8px; margin: 4px 2px; border-radius: 6px; }
#clock.date:hover { background: rgba(169, 204, 130, 0.18); color: #e4ebe2; }
#language, #network, #pulseaudio, #backlight, #battery, #custom-performance { background: rgba(169, 204, 130, 0.06); color: #e4ebe2; border: 1px solid rgba(169, 204, 130, 0.25); border-radius: 6px; padding: 0 9px; margin: 4px 2px; }
#language { color: #dfe8d8; }
#pulseaudio.muted { color: #8a9a82; }
#battery.warning { color: #d8b76c; border-color: rgba(216, 183, 108, 0.45); }
#battery.critical { color: #d98b7d; border-color: rgba(217, 139, 125, 0.45); }
#custom-performance { color: #c4dfa0; padding: 0 10px; margin-right: 8px; }
#custom-performance:hover, #language:hover, #network:hover, #pulseaudio:hover, #backlight:hover, #battery:hover { background: rgba(169, 204, 130, 0.18); border-color: rgba(169, 204, 130, 0.55); }
tooltip { background: rgb(20, 27, 22); border: 1px solid rgba(169, 204, 130, 0.45); border-radius: 8px; color: #e4ebe2; padding: 6px 10px; }
tooltip label { color: #e4ebe2; }
#network.disconnected, #network.disabled { color: #d98b7d; }
#network.ethernet { color: #c4dfa0; }
EOF

# ---------- wofi ----------
w "$H/.config/wofi/config" <<'EOF'
width=520
height=330
prompt=Поиск...
allow_images=true
image_size=20
insensitive=true
hide_on_select=true
EOF
w "$H/.config/wofi/style.css" <<'EOF'
window { background-color: rgba(15,20,16,0.88); border: 1px solid rgba(169,204,130,0.40); border-radius: 10px; font-family: "DejaVu Sans Mono"; font-size: 12px; }
#input { background: rgba(169,204,130,0.08); color: #e4ebe2; border: 1px solid rgba(169,204,130,0.25); border-radius: 8px; margin: 6px; }
#entry { padding: 4px 8px; border-radius: 6px; }
#entry:selected { background-color: rgba(169,204,130,0.25); }
#text { color: #e4ebe2; margin-left: 6px; }
EOF

# ---------- GTK, fastfetch, обои ----------
w "$H/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Papirus-Dark
EOF

# Картинка для fastfetch: положи фото в ~/.config/fastfetch/ под именем logo.png (или logo.jpg / logo.jpeg / logo.webp)
w "$H/.config/fastfetch/show.sh" <<'EOF'
#!/bin/sh
D="$HOME/.config/fastfetch"
LOGO=""
for e in png jpg jpeg webp PNG JPG JPEG WEBP; do
  [ -f "$D/logo.$e" ] && { LOGO="$D/logo.$e"; break; }
done
if [ -n "$LOGO" ]; then
  fastfetch --logo "$LOGO" --logo-type chafa --logo-width 30 --logo-height 15
else
  fastfetch --logo none
fi
exec bash
EOF

# обычная команда fastfetch в терминале тоже берёт твоё фото (иначе показывает логотип Arch)
grep -qF 'fastfetch-logo' "$H/.bashrc" 2>/dev/null || cat >> "$H/.bashrc" <<'EOF'
# fastfetch-logo
fastfetch() {
  local d="$HOME/.config/fastfetch" e f=""
  for e in png jpg jpeg webp PNG JPG JPEG WEBP; do
    [ -f "$d/logo.$e" ] && { f="$d/logo.$e"; break; }
  done
  if [ -n "$f" ]; then
    command fastfetch --logo "$f" --logo-type chafa --logo-width 30 --logo-height 15 "$@"
  else
    command fastfetch "$@"
  fi
}
EOF

w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
# Обои: положи картинки в ~/Pictures/wall, Super+W - следующая
D="$HOME/Pictures/wall"; C="$HOME/.cache/wallpaper"
list="$(ls "$D"/*.png "$D"/*.jpg "$D"/*.jpeg "$D"/*.webp 2>/dev/null)"
pkill swaybg 2>/dev/null
[ -n "$list" ] || exec swaybg -c 0f1410
cur="$(cat "$C" 2>/dev/null)"
if [ "$1" = next ]; then
  f="$(printf '%s\n' "$list" | awk -v c="$cur" 'f{print;exit} $0==c{f=1}')"
  [ -n "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
else
  f="$cur"; [ -f "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
fi
mkdir -p "$(dirname "$C")"; printf '%s\n' "$f" > "$C"
exec swaybg -i "$f" -m fill
EOF

# ---------- ярлыки и программы по умолчанию ----------
w "$H/.local/share/applications/cava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=cava
Exec=cava
NoDisplay=true
EOF
w "$H/.local/share/applications/files.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Files
Exec=/usr/local/bin/files %f
Icon=system-file-manager
Terminal=false
NoDisplay=true
Categories=System;FileManager;
MimeType=inode/directory;
StartupWMClass=files
EOF
w "$H/.local/share/applications/pkg-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Установщик пакетов Arch
Exec=/usr/local/bin/pkg-install %f
Terminal=false
NoDisplay=true
MimeType=application/x-zstd-compressed-tar;
EOF
w "$H/.config/mimeapps.list" <<'EOF'
[Default Applications]
inode/directory=files.desktop
image/png=firefox.desktop
image/jpeg=firefox.desktop
image/gif=firefox.desktop
image/webp=firefox.desktop
image/svg+xml=firefox.desktop
application/pdf=firefox.desktop
video/mp4=firefox.desktop
video/webm=firefox.desktop
audio/mpeg=firefox.desktop
audio/ogg=firefox.desktop
audio/flac=firefox.desktop
audio/x-wav=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
EOF

# ---------- bash ----------
grep -qF '38;5;150m' "$H/.bashrc" 2>/dev/null || cat >> "$H/.bashrc" <<'EOF'
PS1='\[\e[38;5;150m\]\u \[\e[38;5;107m\]\w \[\e[0m\]\$ '
EOF
# автозапуск Hyprland на TTY1
if ! grep -qsi 'hyprland' "$H/.bash_profile"; then
  [ -f "$H/.bash_profile" ] || echo '[ -f ~/.bashrc ] && . ~/.bashrc' > "$H/.bash_profile"
  cat >> "$H/.bash_profile" <<'EOF'
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ]; then
  start-hyprland || exec bash
fi
EOF
fi
mkdir -p "$H/Pictures/wall"

# реальное имя Font Awesome (иконки в waybar, меню питания)
FA="$(fc-list : family 2>/dev/null | grep -o 'Font Awesome [0-9]* Free' | head -n1 || true)"
FA="${FA:-Font Awesome 7 Free} Solid"
sed -i "s/FontAwesome/$FA/g" /usr/local/bin/power-menu /usr/local/bin/performance-menu \
  /usr/local/bin/audio-menu /usr/local/bin/network-menu /usr/local/bin/year-calendar \
  "$H/.config/waybar/style.css"

chown -R "$U:$G" "$H/.config" "$H/.local" "$H/Pictures" "$H/.bashrc" "$H/.bash_profile" 2>/dev/null || true
runuser -u "$U" -- env HOME="$H" xdg-user-dirs-update 2>/dev/null || true

# ================= сторонние приложения =================
# fetch URL ФАЙЛ [sums] - скачать; с "sums" сверить SHA256 по SHA256SUMS.txt из того же релиза
fetch() {
  curl -fL --retry 3 -o "$2" "$1" || { rm -f "$2"; return 1; }
  [ "${3:-}" = sums ] || return 0
  local want have
  want="$(curl -fsSL "${1%/*}/SHA256SUMS.txt" 2>/dev/null | grep -F "${1##*/}" | awk '{print $1}' | head -n1 || true)"
  have="$(sha256sum "$2" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "!! контрольная сумма не подтверждена: ${1##*/}"; rm -f "$2"; return 1; }
}
# gh_asset РЕПО РЕГУЛЯРКА [?per_page=30] - ссылка на файл из последнего релиза на GitHub
gh_asset() {
  curl -fsSL "https://api.github.com/repos/$1/releases${3:-/latest}" 2>/dev/null \
    | grep -o 'https://[^"]*' | grep -E "$2" | head -n1 || true
}
# install_pkg ССЫЛКА ИМЯ [sums] - готовый .pkg.tar.zst
install_pkg() {
  local f="/tmp/$2.pkg.tar.zst"
  if ! fetch "$1" "$f" "${3:-}"; then
    echo "!! $2 не скачался ($1)."
    echo "!! Скачай .pkg.tar.zst вручную и открой его двойным щелчком в Files (Super+E)."
    return 0
  fi
  pacman -U --noconfirm "$f" || echo "!! $2 не установился (скрипт продолжает работу)"
  rm -f "$f"
}
# install_appimage ССЫЛКА КОМАНДА НАЗВАНИЕ КАТЕГОРИИ [sums]
install_appimage() {
  local url="$1" bin="$2" title="$3" cats="$4" P="/opt/$2" run icon src
  if [ ! -x "$P/squashfs-root/AppRun" ]; then
    mkdir -p "$P"; rm -rf "$P/squashfs-root"
    if fetch "$url" "$P/app.AppImage" "${5:-}"; then
      chmod 755 "$P/app.AppImage"
      ( cd "$P" && ./app.AppImage --appimage-extract >/dev/null 2>&1 && rm -f app.AppImage ) || true
    fi
  fi
  chmod -R a+rX "$P" 2>/dev/null || true
  [ ! -f "$P/squashfs-root/chrome-sandbox" ] || { chown root:root "$P/squashfs-root/chrome-sandbox"; chmod 4755 "$P/squashfs-root/chrome-sandbox"; }
  if [ -x "$P/squashfs-root/AppRun" ]; then run="$P/squashfs-root/AppRun"
  elif [ -x "$P/app.AppImage" ]; then run="$P/app.AppImage --appimage-extract-and-run"
  else echo "!! $title не поставился: нет доступа к сайту/GitHub. Включи VPN (Happ) и запусти install.sh ещё раз."; return 0; fi
  printf '#!/bin/sh\n%sexec %s "$@"\n' "${APPENV:-}" "$run" > "/usr/local/bin/$bin"
  chmod 755 "/usr/local/bin/$bin"
  # иконка: сначала .DirIcon (официальная иконка AppImage), потом из usr/share/icons, потом любая png в корне
  src=""
  if [ -f "$P/squashfs-root/.DirIcon" ] && [ "$(head -c 4 "$P/squashfs-root/.DirIcon" 2>/dev/null | tail -c 3)" = PNG ]; then
    src="$P/squashfs-root/.DirIcon"
  fi
  [ -n "$src" ] || src="$(find "$P/squashfs-root/usr/share/icons" -name '*.png' 2>/dev/null | sort -V | tail -n1 || true)"
  [ -n "$src" ] || src="$(find "$P/squashfs-root" -maxdepth 1 -name '*.png' 2>/dev/null | head -n1 || true)"
  icon=application-x-executable
  if [ -n "$src" ] && [ -f "$src" ]; then
    install -Dm644 "$src" "/usr/share/icons/hicolor/256x256/apps/$bin.png"
    icon="$bin"
  fi
  cat > "/usr/share/applications/$bin.desktop" <<DESK_EOF
[Desktop Entry]
Type=Application
Name=$title
Exec=$bin
Icon=$icon
Terminal=false
Categories=$cats
DESK_EOF
  echo "ok: $title"
}
install_photocraft() {
  local u
  u="$(gh_asset storytold/photocraft 'x86_64.*\.pkg\.tar\.zst$')"
  if [ -n "$u" ]; then install_pkg "$u" photocraft sums; return 0; fi
  u="$(gh_asset storytold/photocraft 'x86_64.*\.AppImage$')"
  if [ -n "$u" ]; then install_appimage "$u" photocraft PhotoCraft "Graphics;" sums; return 0; fi
  echo "!! PhotoCraft: не нашёл сборку. Скачай её (Linux x86_64) со страницы"
  echo "!! https://github.com/storytold/photocraft/releases"
}
install_limusic() {
  local u
  u="$(gh_asset SimoHypers/limusic '(x86_64|amd64).*\.AppImage$')"
  if [ -n "$u" ]; then APPENV='export WEBKIT_DISABLE_DMABUF_RENDERER=1
' install_appimage "$u" limusic Limusic "AudioVideo;Audio;Player;"
  else echo "!! Limusic: не нашёл AppImage на https://github.com/SimoHypers/limusic/releases"; fi
}
install_pkg https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.linux.x64.pkg.tar.zst happ
install_photocraft
install_appimage https://download.onlyoffice.com/install/desktop/editors/linux/DesktopEditors-x86_64.AppImage onlyoffice "ONLYOFFICE" "Office;"
install_limusic
# OpenCode больше не нужен: убрать, если уже стоит
rm -rf /opt/opencode /usr/local/bin/opencode /usr/share/applications/opencode.desktop /usr/share/icons/hicolor/256x256/apps/opencode.png
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

# ================= wofi: в лаунчере только твои приложения =================
allow="$( { for p in steam telegram-desktop happ firefox photocraft; do pacman -Ql "$p" 2>/dev/null; done \
  | awk '{print $2}' | grep '^/usr/share/applications/.*\.desktop$' | while read -r f; do basename "$f"; done
  printf '%s\n' onlyoffice.desktop photocraft.desktop limusic.desktop meta-clean.desktop; } )"
mkdir -p "$H/.local/share/applications"
for f in /usr/share/applications/*.desktop; do
  [ -e "$f" ] || continue
  b="${f##*/}"; t="$H/.local/share/applications/$b"
  if printf '%s\n' "$allow" | grep -qxF "$b"; then
    { [ ! -f "$t" ] || ! grep -q '^# hidden-by-install' "$t"; } || rm -f "$t"
    continue
  fi
  { [ ! -e "$t" ] || grep -q '^# hidden-by-install' "$t"; } || continue
  { echo '# hidden-by-install'
    awk '/^NoDisplay=/{next} {print} !d && /^\[Desktop Entry\]/{print "NoDisplay=true"; d=1}' "$f"; } > "$t"
done
chown -R "$U:$G" "$H/.local" 2>/dev/null || true
rm -f "$H/.cache/wofi-drun"

# ================= чистка =================
echo "=== Чистка мусора ==="
orph="$(pacman -Qdtq 2>/dev/null || true)"
[ -z "$orph" ] || pacman -Rns --noconfirm $orph || true
pacman -Sc --noconfirm >/dev/null 2>&1 || true
journalctl --vacuum-size=50M >/dev/null 2>&1 || true
rm -f /tmp/*.pkg.tar.zst
rm -rf "$H/.cache/thumbnails"

echo
echo "Готово. ПЕРЕЗАГРУЗИСЬ (reboot). После входа на TTY1 Hyprland запустится сам."
echo "NVIDIA: драйверы удалены, nouveau/nvidia заблокированы, карта отключена при загрузке - работает только Intel."
echo "Профили питания: кнопка справа в waybar (энергосбережение / баланс / производительность)."
echo "Обои: положи картинки в ~/Pictures/wall (светлые аниме-обои дадут вид как на фото)."
echo "Визуализатор: открой терминал и набери  cava"
echo
echo "Горячие клавиши:"
echo "  Super+Enter       - терминал с fastfetch"
echo "  Super+D           - лаунчер (повторное нажатие закрывает)"
echo "  Super+E           - файлы"
echo "  Super+B           - Firefox"
echo "  Super+W           - следующие обои"
echo "  Super+V           - окно: плавающее / тайлинг"
echo "  Super+F           - полный экран"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть окно"
echo "  Super+Shift+Q     - зажми и води курсором: окна под ним закрываются подряд"
echo "  Super+Shift+S     - скриншот области в буфер"
