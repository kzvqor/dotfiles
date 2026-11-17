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
  alacritty waybar wofi swaybg hyprsunset \
  pipewire pipewire-pulse wireplumber \
  brightnessctl grim slurp wl-clipboard \
  ttf-dejavu ttf-font-awesome noto-fonts-emoji papirus-icon-theme adwaita-icon-theme lxqt-policykit ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
  python-gobject python-cairo gtk3 mesa vulkan-intel power-profiles-daemon libpulse networkmanager gtk-layer-shell udisks2 xdg-utils xdg-user-dirs \
  fastfetch chafa cava nano curl \
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


def list_devices():
    try:
        out = subprocess.run(["lsblk", "-J", "-o", "NAME,LABEL,SIZE,FSTYPE,MOUNTPOINT,PATH"],
                             capture_output=True, text=True, timeout=5).stdout
        data = json.loads(out)
    except Exception:
        return []
    res = []

    def walk(nodes):
        for n in nodes:
            mp = n.get("mountpoint") or next((m for m in (n.get("mountpoints") or []) if m), None)
            fs = n.get("fstype")
            if fs and fs not in SKIP_FS and (not mp or mp.startswith(("/media", "/run/media", "/mnt"))):
                res.append(dict(path=n.get("path"), label=n.get("label") or n.get("name"),
                                size=n.get("size") or "", fstype=fs, mp=mp))
            walk(n.get("children") or [])
    walk(data.get("blockdevices", []))
    return res


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
        self.view.connect("drag-begin", self.on_drag_begin)
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
        if self.devs:
            self.side.add(self.side_section("ДИСКИ"))
            for d in self.devs:
                label = d["label"] + (f"  {d['size']}" if d["size"] else "")
                self.side.add(self.side_row("drive-removable-media-symbolic", label, ("dev", d)))
        self.side.show_all()
        self.sync_side()

    def sync_side(self):
        self.side.unselect_all()
        if not self.cwd:
            return
        for row in self.side.get_children():
            data = getattr(row, "fm_data", None)
            if data and data[0] in ("dir", "mark") and os.path.realpath(data[1]) == self.cwd:
                self.side.select_row(row)
                break

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
                add("Отключить", lambda: self.unmount(val))
            else:
                add("Подключить", lambda: self.mount_and_open(val))
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

# ---------- общий модуль для всплывающих меню (звук, сеть, профили, календарь) ----------
mkdir -p /usr/local/lib/hypr-menus
cat > /usr/local/lib/hypr-menus/hyprmenu.py <<'EOF'
# Общий код всплывающих меню: тема, иконки-глифы, окно-слой, одиночный запуск
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
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
NAME = "hyprmenu"
LOCK = os.path.join(RUNTIME, NAME + ".pid")
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


def init(name):
    """Имя меню: от него зависят класс окна, файл блокировки и namespace слоя."""
    global NAME, LOCK
    NAME = name
    LOCK = os.path.join(RUNTIME, name + ".pid")


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
        nat = self.card.get_preferred_width()[1]
        cx, width = pointer_x()
        if cx is None:
            width = screen_width()
            cx = width - nat / 2 - 12
        x = max(8, min(cx - nat / 2, width - nat - 8))
        self.hold.set_halign(Gtk.Align.START)
        self.hold.set_valign(Gtk.Align.START)
        self.hold.set_margin_start(int(x))
        self.hold.set_margin_top(BAR_GAP)

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
    w.place_card()
    w.show_all()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    first = getattr(w, "first", None)
    if first is not None:
        first.grab_focus()
    Gtk.main()
EOF
chmod 644 /usr/local/lib/hypr-menus/hyprmenu.py

# ---------- меню производительности (профили питания) ----------
cat > /usr/local/bin/performance-menu <<'EOF'
#!/usr/bin/python3
import sys
sys.path.insert(0, "/usr/local/lib/hypr-menus")
import hyprmenu
hyprmenu.init("performance-menu")
from hyprmenu import *  # noqa: E402,F401,F403

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
        sh(["pkill", "-RTMIN+8", "waybar"], 2)  # обновить значок в панели сразу
        self.quit()


if __name__ == "__main__":
    run(PerfMenu)
EOF
chmod 755 /usr/local/bin/performance-menu

# ---------- меню звука ----------
cat > /usr/local/bin/audio-menu <<'EOF'
#!/usr/bin/python3
import sys
sys.path.insert(0, "/usr/local/lib/hypr-menus")
import hyprmenu
hyprmenu.init("audio-menu")
from hyprmenu import *  # noqa: E402,F401,F403

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

# ---------- меню сети ----------
cat > /usr/local/bin/network-menu <<'EOF'
#!/usr/bin/python3
import sys
sys.path.insert(0, "/usr/local/lib/hypr-menus")
import hyprmenu
hyprmenu.init("network-menu")
from hyprmenu import *  # noqa: E402,F401,F403

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

# ---------- календарь на год ----------
cat > /usr/local/bin/year-calendar <<'EOF'
#!/usr/bin/python3
import sys
sys.path.insert(0, "/usr/local/lib/hypr-menus")
import hyprmenu
hyprmenu.init("year-calendar")
from hyprmenu import *  # noqa: E402,F401,F403
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
# значок профиля питания для waybar (обновляется сигналом RTMIN+8)
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

# ---------- приложение «Настройки» (Super+Shift+I), в лаунчер не добавляется ----------
cat > /usr/local/bin/hypr-settings <<'SETTINGS_EOF'
#!/usr/bin/python3
# Настройки (Super+Shift+I): лёгкое приложение настроек для Hyprland
import getpass
import glob
import json
import math
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import threading
import time
import wave
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango

try:
    import cairo
    ROUND_CAP = cairo.LINE_CAP_ROUND
except ImportError:
    ROUND_CAP = 1

NAME = "hypr-settings"
HOME = os.path.realpath(os.path.expanduser("~"))
RUN = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
LOCK = os.path.join(RUN, NAME + ".pid")
BEEP = os.path.join(RUN, NAME + "-beep.wav")
STATE = os.path.join(HOME, ".config", NAME, "state.json")
LUA = os.path.join(HOME, ".config", "hypr", "settings.lua")
WALL = os.path.join(HOME, "Pictures", "wall")
WALL_CUR = os.path.join(HOME, ".cache", "wallpaper")
WALL_MODE = os.path.join(HOME, ".config", "hypr", "wallpaper-mode")
WALL_SH = os.path.join(HOME, ".config", "hypr", "wallpaper.sh")
THUMBS = os.path.join(HOME, ".cache", NAME, "thumbs")
TRASH = os.path.join(HOME, ".local", "share", "Trash")
IMG_EXT = (".png", ".jpg", ".jpeg", ".webp")
THW, THH = 200, 116
V, H = Gtk.Orientation.VERTICAL, Gtk.Orientation.HORIZONTAL
CENTER = Gtk.Align.CENTER
C_ENV = dict(os.environ, LC_ALL="C", LANG="C")

DEFAULTS = {
    "gaps_in": 6, "gaps_out": 14, "border_size": 1, "rounding": 8,
    "blur": True, "animations": True, "inactive_opacity": 0.95, "accent": "a9cc82",
    "repeat_rate": 40, "repeat_delay": 250, "sensitivity": 0.0, "natural_scroll": True,
    "kb_toggle": "grp:alt_shift_toggle", "night_temp": 4500, "scales": {}, "game": None,
}
KEYWORDS = {
    "gaps_in": "general:gaps_in", "gaps_out": "general:gaps_out",
    "border_size": "general:border_size", "accent": "general:col.active_border",
    "rounding": "decoration:rounding", "inactive_opacity": "decoration:inactive_opacity",
    "blur": "decoration:blur:enabled", "animations": "animations:enabled",
    "repeat_rate": "input:repeat_rate", "repeat_delay": "input:repeat_delay",
    "sensitivity": "input:sensitivity", "natural_scroll": "input:touchpad:natural_scroll",
    "kb_toggle": "input:kb_options",
}
ACCENTS = (("a9cc82", "Олива"), ("8fbf9f", "Шалфей"), ("9fd8c4", "Мята"), ("8fb8d8", "Небо"),
           ("b4a7d6", "Лаванда"), ("d98b9b", "Роза"), ("e0a88c", "Персик"), ("d8b76c", "Песок"),
           ("e4ebe2", "Туман"))
BG_COLORS = ("0f1410", "1b2418", "2c3d22", "20262e", "2a2230", "2e2a22", "101010")
PRESETS = (
    ("Компактно", dict(gaps_in=2, gaps_out=4, rounding=4, border_size=1)),
    ("Стандарт", dict(gaps_in=6, gaps_out=14, rounding=8, border_size=1, blur=True,
                      animations=True, inactive_opacity=0.95)),
    ("Воздушно", dict(gaps_in=10, gaps_out=26, rounding=14, border_size=2)),
    ("Минимум нагрузки", dict(blur=False, animations=False, inactive_opacity=1.0, gaps_in=4, gaps_out=8)),
)
GAME = dict(gaps_in=0, gaps_out=0, rounding=0, border_size=1, blur=False, animations=False, inactive_opacity=1.0)
PROFILES = (
    ("power-saver", "power-profile-power-saver-symbolic", "Экономия", "тише и дольше"),
    ("balanced", "power-profile-balanced-symbolic", "Баланс", "на каждый день"),
    ("performance", "power-profile-performance-symbolic", "Мощность", "максимум скорости"),
)
KB_TOGGLES = (("grp:alt_shift_toggle", "Alt + Shift"), ("grp:ctrl_shift_toggle", "Ctrl + Shift"),
              ("grp:caps_toggle", "Caps Lock"), ("", "Только Super + Space"))
STATUS_RU = {"Charging": "заряжается", "Discharging": "разряжается", "Full": "заряжена полностью",
             "Not charging": "не заряжается", "Unknown": "неизвестно"}
HOTKEYS = (
    ("Super+Enter", "Терминал с fastfetch"), ("Super+D", "Лаунчер приложений"),
    ("Super+E", "Файлы"), ("Super+B", "Firefox"), ("Super+Shift+I", "Настройки"),
    ("Super+W", "Следующие обои"), ("Super+V", "Плавающее окно / тайлинг"),
    ("Super+F", "Полный экран"), ("Super+Q", "Закрыть окно"),
    ("Super+Shift+Q", "Держать и водить мышью - закрывать окна под курсором"),
    ("Super+Shift+Esc", "Меню питания"), ("Super+Shift+S", "Скриншот области в буфер"),
    ("Super+Space", "Сменить раскладку"), ("Super+← ↑ → ↓", "Фокус на соседнее окно"),
    ("Super+Shift+← ↑ → ↓", "Переместить окно"), ("Super+Ctrl+← ↑ → ↓", "Изменить размер окна"),
    ("Super+1…5", "Перейти на рабочий стол"), ("Super+Shift+1…5", "Отправить окно на рабочий стол"),
    ("Super+Tab", "Следующий рабочий стол"), ("Super+Колесо", "Листать рабочие столы"),
    ("Super+ЛКМ", "Двигать окно мышью"), ("Super+ПКМ", "Менять размер окна мышью"),
    ("Ctrl+Tab", "Настройки: следующий раздел"), ("Esc", "Настройки: закрыть"),
)
TIPS = (
    "Super+Shift+S копирует область экрана в буфер - вставляй сразу в Telegram.",
    "Двойной клик по громкости в панели открывает микшер приложений.",
    "Колесо мыши над яркостью или громкостью в панели меняет их без меню.",
    "Клик по дате в панели открывает календарь на весь год.",
    "Положи PNG в ~/.config/fastfetch/logo.png - он появится в терминале.",
    "В Files: Ctrl+H - скрытые файлы, Ctrl+D - закладка, F4 - терминал здесь.",
    "Игровой режим во вкладке «Разное» убирает всё лишнее одним переключателем.",
    "Команда cava в терминале - красивый визуализатор музыки.",
    "Раз в неделю полезно обновлять систему: «Хранилище» → «Обновить».",
    "Профиль «Экономия» заметно продлевает работу ноутбука от батареи.",
    "Окно Настроек можно таскать за заголовок или Super+ЛКМ.",
    "Super+V делает окно плавающим - удобно для калькулятора и плееров.",
)
PAGES = (
    ("overview", "Обзор", "computer-symbolic"),
    ("appearance", "Оформление", "preferences-desktop-appearance-symbolic"),
    ("wallpaper", "Обои", "preferences-desktop-wallpaper-symbolic"),
    ("display", "Экран", "video-display-symbolic"),
    ("sound", "Звук", "audio-speakers-symbolic"),
    ("input", "Клавиатура и мышь", "input-keyboard-symbolic"),
    ("power", "Питание", "battery-good-symbolic"),
    ("network", "Сеть", "network-wireless-symbolic"),
    ("storage", "Хранилище", "drive-harddisk-symbolic"),
    ("keys", "Горячие клавиши", "preferences-desktop-keyboard-shortcuts-symbolic"),
    ("fun", "Разное", "face-smile-big-symbolic"),
)

CSS = b"""
* { font-family: "DejaVu Sans", sans-serif; font-size: 11px; }
window { background-color: rgba(15,20,16,0.90); color: #e4ebe2; }
window.dialog, window.messagedialog, filechooser { background-color: rgb(20,27,22); }
list { background-color: transparent; }
.head { padding: 10px 12px 9px 18px; border-bottom: 1px solid rgba(169,204,130,0.14); }
.logo { color: #a9cc82; font-size: 15px; }
.apptitle { color: #c4dfa0; font-size: 13px; font-weight: bold; }
.crumb { color: #8a9a82; }
button.close { border-radius: 12px; padding: 2px 6px; }
button.close:hover { background-color: rgba(217,139,125,0.25); border-color: #d98b7d; }
.side { background-color: rgba(169,204,130,0.04); border-right: 1px solid rgba(169,204,130,0.12); }
.side row { padding: 8px 12px; margin: 2px 8px; border-radius: 10px; background-color: transparent; }
.side row:hover { background-color: rgba(169,204,130,0.10); }
.side row:selected { background-color: rgba(169,204,130,0.24); color: #ffffff; }
.sidefoot { color: #75846d; font-size: 9px; padding: 8px 18px 10px 18px; }
.page { padding: 18px 28px 28px 28px; }
.ptitle { color: #e4ebe2; font-size: 21px; font-weight: bold; }
.psub { color: #8a9a82; }
.gtitle { color: #8a9a82; font-size: 9px; font-weight: bold; margin: 16px 4px 5px 4px; }
.group { background-color: rgba(169,204,130,0.05); border: 1px solid rgba(169,204,130,0.16);
border-radius: 14px; padding: 2px 16px; }
.srow { padding: 10px 0; }
.krow { padding: 7px 0; border-bottom: 1px solid rgba(169,204,130,0.08); }
.rtitle { color: #e4ebe2; }
.rdesc { color: #8a9a82; font-size: 9px; }
.val { color: #a8b8a0; font-family: "DejaVu Sans Mono", monospace; }
.status { color: #8a9a82; padding: 4px 18px 6px 18px; border-top: 1px solid rgba(169,204,130,0.10); }
.err { color: #d98b7d; }
.ring { color: #e4ebe2; }
.dice { font-size: 46px; color: #c4dfa0; }
.chance { color: #c4dfa0; font-size: 13px; font-weight: bold; }
.tip { color: #c4dfa0; font-size: 12px; font-style: italic; }
.kbd { background-color: rgba(169,204,130,0.10); border: 1px solid rgba(169,204,130,0.30);
border-bottom-width: 2px; border-radius: 6px; padding: 1px 7px; color: #c4dfa0;
font-family: "DejaVu Sans Mono", monospace; font-size: 10px; }
separator { background-color: rgba(169,204,130,0.09); min-height: 1px; min-width: 1px; }
button { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none;
padding: 4px 12px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(169,204,130,0.18); border-color: #a9cc82; }
button:active { background-color: rgba(169,204,130,0.28); }
button.accent { background-color: rgba(169,204,130,0.22); border-color: #a9cc82; }
button.danger { color: #d98b7d; border-color: rgba(217,139,125,0.45); }
button.danger:hover { background-color: rgba(217,139,125,0.20); border-color: #d98b7d; }
button.swatch { padding: 0; border-radius: 16px; border: 2px solid rgba(0,0,0,0); min-width: 28px; min-height: 28px; }
button.swatch.on { border-color: #ffffff; }
button.tile { padding: 12px 8px; border-radius: 14px; }
button.tile.on { background-color: rgba(125,148,96,0.34); border-color: #a9cc82; }
button.wall { padding: 3px; border-radius: 12px; border: 2px solid rgba(169,204,130,0.12); }
button.wall.on { border-color: #a9cc82; background-color: rgba(169,204,130,0.20); }
flowboxchild { padding: 0; background-color: transparent; }
entry { background-image: none; background-color: rgba(169,204,130,0.06); color: #e4ebe2;
border: 1px solid rgba(169,204,130,0.25); border-radius: 12px; box-shadow: none; padding: 4px 12px; min-height: 0; }
entry:focus { border-color: #a9cc82; }
switch { background-image: none; background-color: rgba(169,204,130,0.12);
border: 1px solid rgba(169,204,130,0.28); border-radius: 14px; }
switch:checked { background-color: #7d9460; border-color: #a9cc82; }
switch slider { background-image: none; background-color: #e4ebe2; border: none; box-shadow: none;
border-radius: 50%; min-width: 18px; min-height: 18px; }
scale trough { background-color: rgba(169,204,130,0.18); background-image: none; border: none;
border-radius: 4px; min-height: 6px; }
scale highlight { background-color: #a9cc82; background-image: none; border: none; border-radius: 4px; }
scale slider { background-color: #e4ebe2; background-image: none; border: none; box-shadow: none;
border-radius: 50%; min-width: 16px; min-height: 16px; margin: -5px; }
progressbar trough { background-color: rgba(169,204,130,0.14); background-image: none; border: none;
border-radius: 4px; min-height: 7px; }
progressbar progress { background-color: #a9cc82; background-image: none; border: none;
border-radius: 4px; min-height: 7px; }
progressbar.warn progress { background-color: #d8b76c; }
progressbar.crit progress { background-color: #d98b7d; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar { background: transparent; border: none; }
scrollbar slider { background-color: rgba(169,204,130,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; }
menu, .menu { background-color: rgb(20,27,22); color: #e4ebe2; border: 1px solid rgba(169,204,130,0.30); border-radius: 8px; padding: 4px; }
menuitem { padding: 4px 10px; border-radius: 6px; }
menuitem:hover { background-color: rgba(169,204,130,0.18); }
tooltip { background-color: rgb(20,27,22); border: 1px solid rgba(169,204,130,0.40); border-radius: 8px; }
"""


# ================= утилиты =================
def apply_css(screen, css):
    for rule in re.findall(rb"[^{}]+\{[^{}]*\}", css):
        prov = Gtk.CssProvider()
        try:
            prov.load_from_data(rule)
        except GLib.Error:
            continue
        Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def tint(widget, color):
    prov = Gtk.CssProvider()
    prov.load_from_data(f"button {{ background-color: #{color}; }} button:hover {{ background-color: #{color}; }}".encode())
    widget.get_style_context().add_provider(prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)


def sh(args, timeout=4, env=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception:
        return None


def out(args, timeout=4, env=None):
    r = sh(args, timeout, env)
    return r.stdout.strip() if r and r.returncode == 0 else ""


def fire(args):
    threading.Thread(target=sh, args=(args,), daemon=True).start()


def spawn(args):
    try:
        subprocess.Popen(args, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError:
        return False


def in_terminal(cmd, title="Терминал"):
    spawn(["alacritty", "--title", title, "-e", "sh", "-c",
           cmd + '; echo; printf "Готово. Нажми Enter, чтобы закрыть..."; read _'])


def bg(work, done=None):
    def run():
        res = work()
        if done is not None:
            def fin():
                done(res)
                return False
            GLib.idle_add(fin)
    threading.Thread(target=run, daemon=True).start()


def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def human(n):
    units = ("Б", "КБ", "МБ", "ГБ", "ТБ")
    n = float(n)
    for i, u in enumerate(units):
        if n < 1024 or i == len(units) - 1:
            return f"{n:.0f} {u}" if i == 0 else f"{n:.1f} {u}"
        n /= 1024


def fmt_dur(sec):
    sec = int(sec)
    d, sec = divmod(sec, 86400)
    h, sec = divmod(sec, 3600)
    parts = []
    if d:
        parts.append(f"{d} д")
    if h:
        parts.append(f"{h} ч")
    parts.append(f"{sec // 60} мин")
    return " ".join(parts)


def unique(dest_dir, name):
    base, ext = os.path.splitext(name)
    cand, i = name, 1
    while os.path.lexists(os.path.join(dest_dir, cand)):
        cand = f"{base} ({i}){ext}"
        i += 1
    return os.path.join(dest_dir, cand)


def dir_size(path):
    total, stack = 0, [path]
    while stack:
        p = stack.pop()
        try:
            with os.scandir(p) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def lbl(text, cls=None, xalign=0.0, wrap=False):
    lab = Gtk.Label(label=text, xalign=xalign)
    if cls:
        for c in cls.split():
            lab.get_style_context().add_class(c)
    if wrap:
        lab.set_line_wrap(True)
    return lab


def lvl(frac, warn=0.75, crit=0.9):
    return 2 if frac >= crit else (1 if frac >= warn else 0)


def no_wheel(widget):
    # колесо мыши листает страницу, а не крутит ползунок/список
    def on_scroll(w, e):
        w.stop_emission_by_name("scroll-event")
        return False
    widget.connect("scroll-event", on_scroll)


def greeting():
    h = time.localtime().tm_hour
    return "Доброй ночи" if h < 5 else "Доброе утро" if h < 12 else "Добрый день" if h < 18 else "Добрый вечер"


def ppd_set(prof):
    r = sh(["powerprofilesctl", "set", prof], 5)
    sh(["pkill", "-RTMIN+8", "waybar"], 2)  # обновить значок в панели
    return bool(r and r.returncode == 0)


# ================= сведения о системе =================
def meminfo():
    d = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        parts = v.split()
        if parts:
            try:
                d[k] = int(parts[0]) * 1024
            except ValueError:
                pass
    return d


def battery():
    for b in sorted(glob.glob("/sys/class/power_supply/BAT*")):
        cap = read(b + "/capacity")
        if not cap.isdigit():
            continue

        def num(n):
            try:
                return int(read(os.path.join(b, n)))
            except ValueError:
                return None
        full = num("energy_full") or num("charge_full")
        design = num("energy_full_design") or num("charge_full_design")
        now = num("energy_now") or num("charge_now")
        rate = num("power_now") or num("current_now")
        status = read(b + "/status")
        eta = None
        if rate and now is not None and full:
            if status == "Discharging":
                eta = now / rate
            elif status == "Charging":
                eta = max(full - now, 0) / rate
            if eta is not None and eta > 48:
                eta = None
        return {"cap": int(cap), "status": status, "eta": eta, "cycles": num("cycle_count"),
                "health": round(full * 100 / design) if full and design else None}
    return None


def temperature():
    best = None
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        try:
            v = int(read(z + "/temp")) / 1000
        except ValueError:
            continue
        if read(z + "/type") == "x86_pkg_temp":
            return v
        if v > 0 and (best is None or v > best):
            best = v
    return best


def os_name():
    for line in read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip('"')
    return "Linux"


def cpu_model():
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            return re.sub(r"\s+", " ", line.split(":", 1)[1]).strip() + f" · {os.cpu_count()} потоков"
    return f"{os.cpu_count()} потоков"


def gpu_name():
    vendors = {"0x8086": "Intel", "0x1002": "AMD", "0x10de": "NVIDIA"}
    found = []
    for card in sorted(glob.glob("/sys/class/drm/card[0-9]")):
        v = read(card + "/device/vendor")
        drv = ""
        for line in read(card + "/device/uevent").splitlines():
            if line.startswith("DRIVER="):
                drv = line[7:]
        name = vendors.get(v, v or "?") + (f" ({drv})" if drv else "")
        if name not in found:
            found.append(name)
    return ", ".join(found) or "-"


def hypr_version():
    try:
        d = json.loads(out(["hyprctl", "version", "-j"]))
        return str(d.get("tag") or d.get("version") or "?")
    except ValueError:
        m = re.search(r"Hyprland\s+([\w.\-]+)", out(["hyprctl", "version"]))
        return m.group(1) if m else "?"


def wp_state(target):
    o = out(["wpctl", "get-volume", target])
    m = re.search(r"Volume:\s*([0-9.]+)", o)
    if not m:
        return None
    return min(100, round(float(m.group(1)) * 100)), "[MUTED]" in o


def get_brightness():
    try:
        return int(out(["brightnessctl", "-m", "-c", "backlight"]).split(",")[3].rstrip("%"))
    except (IndexError, ValueError):
        return None


def list_walls():
    try:
        return [os.path.join(WALL, f) for f in sorted(os.listdir(WALL)) if f.lower().endswith(IMG_EXT)]
    except OSError:
        return []


def make_thumb(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    key = re.sub(r"[^\w.-]", "_", os.path.basename(path)) + f"-{int(st.st_mtime)}-{st.st_size}.png"
    tp = os.path.join(THUMBS, key)
    if os.path.exists(tp):
        return tp
    try:
        info = GdkPixbuf.Pixbuf.get_file_info(path)
        fw, fh = info[1], info[2]
        if not info[0] or fw <= 0 or fh <= 0:
            return None
        k = max(THW / fw, THH / fh)
        tw, th = max(THW, int(fw * k + 0.5)), max(THH, int(fh * k + 0.5))
        pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, tw, th, False)
        pb = pb.new_subpixbuf((pb.get_width() - THW) // 2, (pb.get_height() - THH) // 2, THW, THH)
        os.makedirs(THUMBS, exist_ok=True)
        pb.savev(tp, "png", [], [])
        return tp
    except (GLib.Error, TypeError, ValueError):
        return None


def play_beep():
    if not os.path.exists(BEEP):
        rate, frames = 44100, bytearray()
        for f, d in ((784, 0.16), (1047, 0.34)):
            n = int(rate * d)
            for i in range(n):
                env = math.exp(-5 * i / n) * min(1.0, i / 200)
                frames += struct.pack("<h", int(11000 * env * math.sin(2 * math.pi * f * i / rate)))
        try:
            with wave.open(BEEP, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(rate)
                w.writeframes(bytes(frames))
        except OSError:
            return
    if not spawn(["paplay", BEEP]):
        spawn(["pw-play", BEEP])


def logout():
    for args in (["hyprctl", "dispatch", "exit"], ["hyprctl", "dispatch", "hl.dsp.exit()"]):
        r = sh(args, 3)
        if r and r.returncode == 0 and r.stdout.strip().lower().startswith("ok"):
            return
    sid = os.environ.get("XDG_SESSION_ID")
    spawn(["loginctl", "terminate-session", sid] if sid else
          ["loginctl", "terminate-user", os.environ.get("USER", "")])


# ================= сохранение настроек =================
def ok_type(d, v):
    if d is None:
        return v is None or isinstance(v, dict)
    if isinstance(d, bool):
        return isinstance(v, bool)
    if isinstance(d, (int, float)):
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return isinstance(v, type(d))


def load_state():
    st = json.loads(json.dumps(DEFAULTS))
    try:
        with open(STATE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for k, d in DEFAULTS.items():
                if k in data and ok_type(d, data[k]):
                    st[k] = data[k]
    except (OSError, ValueError):
        pass
    return st


def lua_value(v, ind=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return f"{v:g}"
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    inner = ind + "  "
    return "{\n" + "".join(f"{inner}{k} = {lua_value(x, inner)},\n" for k, x in v.items()) + ind + "}"


def lua_config(st):
    # секции пишутся целиком, чтобы ничего не потерялось, даже если Hyprland заменяет таблицу
    cfg = {
        "general": {"gaps_in": st["gaps_in"], "gaps_out": st["gaps_out"], "border_size": st["border_size"],
                    "col": {"active_border": f"rgba({st['accent']}ee)", "inactive_border": "rgba(3a4a33aa)"},
                    "layout": "dwindle"},
        "decoration": {"rounding": st["rounding"], "active_opacity": 1.0,
                       "inactive_opacity": float(st["inactive_opacity"]),
                       "blur": {"enabled": st["blur"], "size": 6, "passes": 3}},
        "animations": {"enabled": st["animations"]},
        "input": {"kb_layout": "us,ru", "kb_options": st["kb_toggle"], "follow_mouse": 1,
                  "repeat_rate": st["repeat_rate"], "repeat_delay": st["repeat_delay"],
                  "sensitivity": float(st["sensitivity"]),
                  "touchpad": {"natural_scroll": st["natural_scroll"]}},
    }
    text = "-- Создано приложением «Настройки» (Super+Shift+I). Ручные правки будут перезаписаны.\n"
    text += "hl.config(" + lua_value(cfg) + ")\n"
    for name, sc in (st.get("scales") or {}).items():
        text += (f"hl.monitor({{ output = {json.dumps(name)}, mode = \"preferred\", "
                 f"position = \"auto\", scale = {float(sc):g} }})\n")
    return text


def save_state(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1)
    os.replace(STATE + ".tmp", STATE)
    os.makedirs(os.path.dirname(LUA), exist_ok=True)
    with open(LUA + ".tmp", "w", encoding="utf-8") as f:
        f.write(lua_config(st))
    os.replace(LUA + ".tmp", LUA)


def live_value(key, v):
    if key == "accent":
        return f"rgba({v}ee)"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


# ================= виджеты =================
class Ring(Gtk.DrawingArea):
    COLORS = ((0.663, 0.800, 0.510), (0.847, 0.718, 0.424), (0.851, 0.545, 0.490))

    def __init__(self, title, size=112):
        super().__init__()
        self.title, self.frac, self.text, self.level = title, 0.0, "…", 0
        self.big = size >= 150
        self.set_size_request(size, size)
        self.get_style_context().add_class("ring")
        self.connect("draw", self.on_draw)

    def set(self, frac, text, level=0):
        self.frac = max(0.0, min(1.0, frac))
        self.text, self.level = text, level
        self.queue_draw()

    def on_draw(self, w, cr):
        a = w.get_allocation()
        cx, cy = a.width / 2, a.height / 2
        r = min(a.width, a.height) / 2 - 8
        cr.set_line_width(8 if self.big else 7)
        cr.set_line_cap(ROUND_CAP)
        cr.set_source_rgba(0.663, 0.800, 0.510, 0.14)
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.stroke()
        if self.frac > 0.002:
            cr.set_source_rgb(*self.COLORS[self.level])
            cr.arc(cx, cy, r, -math.pi / 2, -math.pi / 2 + 2 * math.pi * self.frac)
            cr.stroke()
        lay = w.create_pango_layout("")
        lay.set_alignment(Pango.Alignment.CENTER)
        size = 22000 if self.big else 14000
        lay.set_markup(f"<span size='{size}' weight='bold'>{GLib.markup_escape_text(self.text)}</span>\n"
                       f"<span size='8000' foreground='#8a9a82'>{GLib.markup_escape_text(self.title)}</span>", -1)
        _ink, log = lay.get_pixel_extents()
        Gtk.render_layout(w.get_style_context(), cr, cx - log.width / 2 - log.x, cy - log.height / 2 - log.y, lay)
        return False


# ================= окно =================
class Settings(Gtk.Window):
    def __init__(self):
        super().__init__(title="Настройки")
        self.set_default_size(1020, 680)
        self.set_decorated(False)
        self.st = load_state()
        self.save_id = 0
        self.kw_failed = False
        self.syncing = False
        self.built = {}
        self.widgets = {}
        self.cpu_prev = None
        self.toast_id = 0
        self.wall_btns = []
        self.swatches = []
        self.prof_btns = {}
        self.bat_rows = None
        self.pomo = {"mode": "work", "left": 25 * 60, "run": False, "id": 0}
        screen = self.get_screen()
        vis = screen.get_rgba_visual()
        if vis:
            self.set_visual(vis)
        apply_css(screen, CSS)

        root = Gtk.Box(orientation=V)
        self.add(root)
        head = Gtk.EventBox()
        head.connect("button-press-event", self.on_head_press)
        hb = Gtk.Box(spacing=10)
        hb.get_style_context().add_class("head")
        hb.pack_start(lbl("◈", "logo"), False, False, 0)
        hb.pack_start(lbl("Настройки", "apptitle"), False, False, 0)
        self.crumb = lbl("", "crumb")
        hb.pack_start(self.crumb, False, False, 0)
        close = Gtk.Button()
        close.add(Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.BUTTON))
        close.get_style_context().add_class("close")
        close.set_tooltip_text("Закрыть (Esc)")
        close.connect("clicked", lambda *_: self.destroy())
        hb.pack_end(close, False, False, 0)
        head.add(hb)
        root.pack_start(head, False, False, 0)

        body = Gtk.Box()
        root.pack_start(body, True, True, 0)
        side = Gtk.Box(orientation=V)
        side.get_style_context().add_class("side")
        side.set_size_request(212, -1)
        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        ss = Gtk.ScrolledWindow()
        ss.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        ss.add(self.side)
        side.pack_start(ss, True, True, 6)
        side.pack_start(lbl("Super+Shift+I - открыть / закрыть", "sidefoot"), False, False, 0)
        body.pack_start(side, False, False, 0)
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(140)
        body.pack_start(self.stack, True, True, 0)
        self.status = lbl("Изменения применяются сразу и сохраняются автоматически", "status")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        root.pack_start(self.status, False, False, 0)

        for key, title, icon in PAGES:
            row = Gtk.ListBoxRow()
            box = Gtk.Box(spacing=11)
            img = Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU)
            img.set_pixel_size(16)
            box.pack_start(img, False, False, 0)
            box.pack_start(lbl(title), True, True, 0)
            row.add(box)
            row.key, row.title = key, title
            self.side.add(row)
        self.side.connect("row-selected", self.on_page)
        self.connect("key-press-event", self.on_key)
        self.connect("focus-in-event", lambda *_: self.set_urgency_hint(False))
        self.connect("destroy", self.on_close)
        GLib.timeout_add_seconds(2, self.tick)
        self.side.select_row(self.side.get_row_at_index(0))

    # ---------- общее ----------
    def on_head_press(self, w, ev):
        if ev.button == 1 and ev.type == Gdk.EventType.BUTTON_PRESS:
            self.begin_move_drag(ev.button, int(ev.x_root), int(ev.y_root), ev.time)
        return False

    def on_close(self, *_):
        if self.save_id:
            GLib.source_remove(self.save_id)
            self.save()

    def say(self, text, err=False):
        ctx = self.status.get_style_context()
        (ctx.add_class if err else ctx.remove_class)("err")
        self.status.set_text(text)
        if self.toast_id:
            GLib.source_remove(self.toast_id)
        self.toast_id = GLib.timeout_add_seconds(5, self.clear_say)

    def clear_say(self):
        self.toast_id = 0
        self.status.get_style_context().remove_class("err")
        self.status.set_text("")
        return False

    def confirm(self, text, extra=None):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                buttons=Gtk.ButtonsType.YES_NO, text=text)
        if extra:
            dlg.format_secondary_text(extra)
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.YES

    def keyword(self, key, value):
        def work():
            r = sh(["hyprctl", "keyword", key, value], 3)
            if not r or r.returncode != 0 or not r.stdout.strip().lower().startswith("ok"):
                self.kw_failed = True
        threading.Thread(target=work, daemon=True).start()

    def set(self, key, value):
        self.st[key] = value
        if key in KEYWORDS:
            self.keyword(KEYWORDS[key], live_value(key, value))
        self.queue_save()

    def queue_save(self):
        if self.save_id:
            GLib.source_remove(self.save_id)
        self.save_id = GLib.timeout_add(500, self.save)

    def save(self):
        self.save_id = 0
        try:
            save_state(self.st)
        except OSError as e:
            self.say("Не удалось сохранить: " + str(e), True)
            return False
        if self.kw_failed:
            # живое применение не сработало - перечитываем конфиг Hyprland целиком
            self.kw_failed = False
            fire(["hyprctl", "reload"])
        return False

    def apply_values(self, d):
        self.syncing = True
        for k, v in d.items():
            w = self.widgets.get(k)
            if isinstance(w, Gtk.Switch):
                w.set_active(bool(v))
            elif w is not None and hasattr(w, "scale"):
                w.scale.set_value(v * 100 if k == "inactive_opacity" else v)
        self.syncing = False
        for k, v in d.items():
            self.set(k, v)

    # ---------- навигация ----------
    def on_page(self, box, row):
        if row is None:
            return
        key = row.key
        if key not in self.built:
            content = getattr(self, "build_" + key)()
            sc = Gtk.ScrolledWindow()
            sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            sc.add(content)
            sc.show_all()
            self.stack.add_named(sc, key)
            self.built[key] = sc
        self.stack.set_visible_child_name(key)
        self.crumb.set_text("·  " + row.title)
        self.refresh_page(key)

    def step_page(self, d):
        row = self.side.get_selected_row()
        i = row.get_index() if row else 0
        self.side.select_row(self.side.get_row_at_index((i + d) % len(PAGES)))

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        ctrl = bool(ev.state & Gdk.ModifierType.CONTROL_MASK)
        focus = self.get_focus()
        if k == "Escape":
            if isinstance(focus, Gtk.Entry) and focus.get_text():
                focus.set_text("")
            else:
                self.destroy()
            return True
        if ctrl and k.lower() in ("q", "w"):
            self.destroy()
            return True
        if ctrl and k in ("Tab", "Page_Down"):
            self.step_page(1)
            return True
        if ctrl and k in ("ISO_Left_Tab", "Page_Up"):
            self.step_page(-1)
            return True
        return False

    def tick(self):
        if self.get_visible():
            name = self.stack.get_visible_child_name()
            if name == "overview":
                self.update_overview()
            elif name == "power":
                self.update_power()
        return True

    def refresh_page(self, key):
        if key == "overview":
            self.update_overview()
        elif key == "power":
            self.update_power()
            bg(lambda: out(["powerprofilesctl", "get"]), self.mark_profile)
        elif key == "network":
            self.refresh_net()
        elif key == "storage":
            self.refresh_storage()
        elif key == "wallpaper":
            self.mark_wall(read(WALL_CUR))

    # ---------- строительные блоки ----------
    def page(self, title, sub=""):
        box = Gtk.Box(orientation=V, spacing=4)
        box.get_style_context().add_class("page")
        box.pack_start(lbl(title, "ptitle"), False, False, 0)
        box.sub = lbl(sub, "psub", wrap=True)
        box.pack_start(box.sub, False, False, 0)
        return box

    def group(self, parent, title=None):
        if title:
            parent.pack_start(lbl(title.upper(), "gtitle"), False, False, 0)
        g = Gtk.Box(orientation=V)
        g.get_style_context().add_class("group")
        parent.pack_start(g, False, False, 0)
        return g

    def row(self, g, title, desc=None, widget=None):
        if g.get_children():
            g.pack_start(Gtk.Separator(), False, False, 0)
        r = Gtk.Box(spacing=14)
        r.get_style_context().add_class("srow")
        col = Gtk.Box(orientation=V, spacing=2)
        col.set_valign(CENTER)
        col.pack_start(lbl(title, "rtitle"), False, False, 0)
        if desc:
            d = lbl(desc, "rdesc", wrap=True)
            d.set_max_width_chars(48)
            col.pack_start(d, False, False, 0)
        r.pack_start(col, True, True, 0)
        if widget is not None:
            widget.set_valign(CENTER)
            r.pack_end(widget, False, False, 0)
        g.pack_start(r, False, False, 0)
        return r

    def value_row(self, g, title, desc=None):
        v = lbl("…", "val", xalign=1)
        v.set_ellipsize(Pango.EllipsizeMode.END)
        v.set_max_width_chars(46)
        self.row(g, title, desc, v)
        return v

    def button(self, text, cb, icon=None, cls=None):
        b = Gtk.Button()
        box = Gtk.Box(spacing=6)
        if icon:
            box.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON), False, False, 0)
        b.text_label = Gtk.Label(label=text or "")
        if text:
            box.pack_start(b.text_label, False, False, 0)
        b.add(box)
        if cls:
            for c in cls.split():
                b.get_style_context().add_class(c)
        b.connect("clicked", lambda *_: cb())
        return b

    def slider(self, lo, hi, step, value, fmt, cb, digits=0, width=230):
        box = Gtk.Box(spacing=10)
        sc = Gtk.Scale.new_with_range(H, lo, hi, step)
        sc.set_draw_value(False)
        sc.set_digits(digits)
        sc.set_size_request(width, -1)
        sc.set_value(value)
        no_wheel(sc)
        val = lbl(fmt(value), "val", xalign=1)
        val.set_width_chars(7)
        pend = {"id": 0}

        def norm(x):
            return round(x, digits) if digits else int(round(x))

        def push(x):
            pend["id"] = 0
            cb(x)
            return False

        def changed(s):
            x = norm(s.get_value())
            val.set_text(fmt(x))
            if self.syncing:
                return
            if pend["id"]:
                GLib.source_remove(pend["id"])
            pend["id"] = GLib.timeout_add(110, push, x)
        sc.connect("value-changed", changed)
        box.pack_start(sc, True, True, 0)
        box.pack_start(val, False, False, 0)
        box.scale = sc
        return box

    def add_slider(self, g, key, title, desc, lo, hi, step, fmt, digits=0):
        s = self.slider(lo, hi, step, self.st[key], fmt, lambda v, k=key: self.set(k, v), digits)
        self.widgets[key] = s
        self.row(g, title, desc, s)

    def add_switch(self, g, key, title, desc=None):
        sw = Gtk.Switch()
        sw.set_active(bool(self.st[key]))
        sw.connect("notify::active", lambda w, _p, k=key: None if self.syncing else self.set(k, w.get_active()))
        self.widgets[key] = sw
        self.row(g, title, desc, sw)

    def combo(self, items, active, cb, width=None):
        c = Gtk.ComboBoxText()
        for i, t in items:
            c.append(i, t)
        c.set_active_id(active)
        if width:
            c.set_size_request(width, -1)
            for cell in c.get_cells():
                cell.set_property("ellipsize", Pango.EllipsizeMode.END)
        no_wheel(c)
        c.connect("changed", lambda w: cb(w.get_active_id()) if w.get_active_id() is not None else None)
        return c

    # ================= Обзор =================
    def build_overview(self):
        p = self.page(f"{greeting()}, {getpass.getuser()}",
                      f"{socket.gethostname()}  ·  {os_name()}  ·  {time.strftime('%d.%m.%Y')}")
        rings = Gtk.Box(spacing=14)
        rings.set_homogeneous(True)
        rings.set_margin_top(14)
        rings.set_margin_bottom(4)
        self.r_cpu, self.r_ram = Ring("процессор"), Ring("память")
        self.r_disk, self.r_temp, self.r_bat = Ring("диск /"), Ring("температура"), Ring("батарея")
        for r in (self.r_cpu, self.r_ram, self.r_disk, self.r_temp, self.r_bat):
            rings.pack_start(r, True, True, 0)
        if battery() is None:
            self.r_bat.set_no_show_all(True)
        if temperature() is None:
            self.r_temp.set_no_show_all(True)
        p.pack_start(rings, False, False, 0)

        g = self.group(p, "Система")
        self.ov = {}
        for key, title in (("os", "Система"), ("kernel", "Ядро"), ("cpu", "Процессор"), ("gpu", "Графика"),
                           ("mem", "Память"), ("wm", "Hyprland"), ("pkgs", "Пакеты"), ("up", "Работает без перерыва")):
            self.ov[key] = self.value_row(g, title)
        self.ov["os"].set_text(os_name())
        self.ov["kernel"].set_text(os.uname().release)
        self.ov["cpu"].set_text(cpu_model())
        self.ov["gpu"].set_text(gpu_name())
        bg(hypr_version, self.ov["wm"].set_text)
        bg(lambda: f"{len(out(['pacman', '-Qq'], 10).splitlines())} шт.", self.ov["pkgs"].set_text)

        g = self.group(p, "Быстрые действия")
        fb = Gtk.Box(spacing=8)
        for text, icon, cb in (
                ("Скриншот", "camera-photo-symbolic", self.screenshot),
                ("Терминал", "utilities-terminal-symbolic", lambda: spawn(["alacritty"])),
                ("Файлы", "system-file-manager-symbolic", lambda: spawn(["/usr/local/bin/files"])),
                ("Обновить систему", "software-update-available-symbolic",
                 lambda: in_terminal("sudo pacman -Syu", "Обновление системы"))):
            fb.pack_start(self.button(text, cb, icon), False, False, 0)
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(fb, False, False, 0)
        g.pack_start(r, False, False, 0)
        self.cpu_usage()
        return p

    def cpu_usage(self):
        try:
            nums = [int(x) for x in read("/proc/stat").splitlines()[0].split()[1:]]
        except (IndexError, ValueError):
            return 0.0
        idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
        total = sum(nums)
        prev, self.cpu_prev = self.cpu_prev, (idle, total)
        if not prev or total <= prev[1]:
            return 0.0
        return 1 - (idle - prev[0]) / (total - prev[1])

    def update_overview(self):
        if not hasattr(self, "r_cpu"):
            return
        c = self.cpu_usage()
        self.r_cpu.set(c, f"{c * 100:.0f}%", lvl(c))
        m = meminfo()
        tot, av = m.get("MemTotal", 0), m.get("MemAvailable", 0)
        if tot:
            f = 1 - av / tot
            self.r_ram.set(f, f"{f * 100:.0f}%", lvl(f))
            self.ov["mem"].set_text(f"{human(tot - av)} из {human(tot)}")
        try:
            du = shutil.disk_usage("/")
            f = du.used / du.total
            self.r_disk.set(f, f"{f * 100:.0f}%", lvl(f, 0.8, 0.92))
        except OSError:
            pass
        t = temperature()
        if t is not None:
            self.r_temp.set(t / 100, f"{t:.0f}°", lvl(t / 100, 0.7, 0.85))
        b = battery()
        if b:
            self.r_bat.title = "заряжается" if b["status"] == "Charging" else "батарея"
            self.r_bat.set(b["cap"] / 100, f"{b['cap']}%", 2 if b["cap"] <= 10 else 1 if b["cap"] <= 25 else 0)
        try:
            self.ov["up"].set_text(fmt_dur(float(read("/proc/uptime").split()[0])))
        except (IndexError, ValueError):
            pass

    def screenshot(self):
        d = os.path.join(HOME, "Pictures", "Screenshots")
        spawn(["sh", "-c", f'mkdir -p "{d}"; sleep 0.4; f="{d}/$(date +%F_%H-%M-%S).png"; '
                           'grim -g "$(slurp)" "$f" && wl-copy < "$f"'])
        self.destroy()

    # ================= Оформление =================
    def build_appearance(self):
        p = self.page("Оформление", "Окна, отступы и эффекты. Всё меняется сразу.")
        g = self.group(p, "Цвет рамки активного окна")
        box = Gtk.Box(spacing=10)
        for hexc, name in ACCENTS:
            b = Gtk.Button()
            b.set_tooltip_text(name)
            b.get_style_context().add_class("swatch")
            tint(b, hexc)
            b.connect("clicked", lambda w, c=hexc: self.pick_accent(c))
            self.swatches.append((b, hexc))
            box.pack_start(b, False, False, 0)
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(box, False, False, 0)
        g.pack_start(r, False, False, 0)
        self.mark_accent()

        px = lambda v: f"{v} px"
        g = self.group(p, "Окна")
        self.add_slider(g, "gaps_in", "Отступ между окнами", None, 0, 30, 1, px)
        self.add_slider(g, "gaps_out", "Отступ от краёв экрана", None, 0, 50, 1, px)
        self.add_slider(g, "border_size", "Толщина рамки", None, 0, 6, 1, px)
        self.add_slider(g, "rounding", "Скругление углов", None, 0, 24, 1, px)
        s = self.slider(50, 100, 1, round(self.st["inactive_opacity"] * 100), lambda v: f"{v}%",
                        lambda v: self.set("inactive_opacity", round(v / 100, 2)))
        self.widgets["inactive_opacity"] = s
        self.row(g, "Непрозрачность неактивных окон", "100% - окна совсем не просвечивают", s)

        g = self.group(p, "Эффекты")
        self.add_switch(g, "blur", "Размытие", "Красиво, но расходует видеокарту и батарею")
        self.add_switch(g, "animations", "Анимации", "Плавное появление окон и смена рабочих столов")

        g = self.group(p, "Готовые наборы")
        box = Gtk.Box(spacing=8)
        for name, vals in PRESETS:
            box.pack_start(self.button(name, lambda v=vals, n=name: (self.apply_values(v), self.say("Набор: " + n))),
                           False, False, 0)
        box.pack_end(self.button("Сбросить всё", self.reset_look, "edit-undo-symbolic", "danger"), False, False, 0)
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(box, True, True, 0)
        g.pack_start(r, False, False, 0)
        return p

    def pick_accent(self, c):
        self.set("accent", c)
        self.mark_accent()

    def mark_accent(self):
        for b, c in self.swatches:
            ctx = b.get_style_context()
            (ctx.add_class if c == self.st["accent"] else ctx.remove_class)("on")

    def reset_look(self):
        keys = ("gaps_in", "gaps_out", "border_size", "rounding", "blur", "animations", "inactive_opacity", "accent")
        self.apply_values({k: DEFAULTS[k] for k in keys})
        self.mark_accent()
        self.say("Оформление сброшено")

    # ================= Обои =================
    def build_wallpaper(self):
        p = self.page("Обои", "Картинки из ~/Pictures/wall.  Super+W - следующие.")
        g = self.group(p, "Управление")
        box = Gtk.Box(spacing=8)
        box.pack_start(self.button("Следующие", self.wall_next, "go-next-symbolic"), False, False, 0)
        box.pack_start(self.button("Случайные", self.random_wall, "media-playlist-shuffle-symbolic"), False, False, 0)
        box.pack_start(self.button("Добавить…", self.wall_add, "list-add-symbolic"), False, False, 0)
        box.pack_start(self.button("Папка", lambda: spawn(["/usr/local/bin/files", WALL]), "folder-open-symbolic"),
                       False, False, 0)
        self.row(g, "Действия", None, box)
        mode = read(WALL_MODE) or "fill"
        self.row(g, "Как показывать картинку", None, self.combo(
            (("fill", "Заполнить экран"), ("fit", "Вписать целиком"), ("center", "По центру"),
             ("tile", "Плиткой"), ("stretch", "Растянуть")), mode, self.set_wall_mode))
        colors = Gtk.Box(spacing=8)
        for c in BG_COLORS:
            b = Gtk.Button()
            b.get_style_context().add_class("swatch")
            tint(b, c)
            b.set_tooltip_text("#" + c)
            b.connect("clicked", lambda w, col=c: self.wall_color(col))
            colors.pack_start(b, False, False, 0)
        self.row(g, "Сплошной цвет", "Вместо картинки - самый лёгкий вариант", colors)

        p.pack_start(lbl("КАРТИНКИ", "gtitle"), False, False, 0)
        self.wall_empty = lbl("В папке пока нет картинок - нажми «Добавить…».", "psub")
        self.wall_empty.set_no_show_all(True)
        p.pack_start(self.wall_empty, False, False, 0)
        self.wall_flow = Gtk.FlowBox()
        self.wall_flow.set_selection_mode(Gtk.SelectionMode.NONE)
        self.wall_flow.set_homogeneous(True)
        self.wall_flow.set_min_children_per_line(2)
        self.wall_flow.set_max_children_per_line(6)
        self.wall_flow.set_column_spacing(10)
        self.wall_flow.set_row_spacing(10)
        p.pack_start(self.wall_flow, False, False, 0)
        self.load_walls()
        return p

    def load_walls(self):
        for c in self.wall_flow.get_children():
            self.wall_flow.remove(c)
        files = list_walls()
        self.wall_empty.set_visible(not files)
        self.wall_btns, jobs = [], []
        for path in files:
            b = Gtk.Button()
            b.get_style_context().add_class("wall")
            b.set_tooltip_text(os.path.basename(path))
            img = Gtk.Image.new_from_icon_name("image-x-generic-symbolic", Gtk.IconSize.DIALOG)
            img.set_size_request(THW, THH)
            b.add(img)
            b.connect("clicked", lambda w, pth=path: self.wall_set(pth))
            self.wall_flow.add(b)
            self.wall_btns.append((b, path))
            jobs.append((img, path))
        self.mark_wall(read(WALL_CUR))
        self.wall_flow.show_all()

        def set_img(img, t):
            img.set_from_file(t)
            return False

        def work():
            for img, path in jobs:
                t = make_thumb(path)
                if t:
                    GLib.idle_add(set_img, img, t)
        threading.Thread(target=work, daemon=True).start()

    def mark_wall(self, cur):
        for b, pth in self.wall_btns:
            ctx = b.get_style_context()
            (ctx.add_class if pth == cur else ctx.remove_class)("on")

    def write_cur(self, text):
        try:
            os.makedirs(os.path.dirname(WALL_CUR), exist_ok=True)
            with open(WALL_CUR, "w", encoding="utf-8") as f:
                f.write(text + "\n")
            return True
        except OSError as e:
            self.say("Ошибка: " + str(e), True)
            return False

    def wall_set(self, path):
        if self.write_cur(path):
            spawn(["sh", WALL_SH])
            self.mark_wall(path)

    def wall_color(self, c):
        if self.write_cur("color:" + c):
            spawn(["sh", WALL_SH])
            self.mark_wall("")

    def wall_next(self):
        spawn(["sh", WALL_SH, "next"])
        GLib.timeout_add(500, lambda: self.mark_wall(read(WALL_CUR)) and False)

    def random_wall(self):
        files = list_walls()
        if not files:
            self.say("В ~/Pictures/wall нет картинок", True)
            return
        cur = read(WALL_CUR)
        choice = [f for f in files if f != cur] or files
        self.wall_set(random.choice(choice))

    def set_wall_mode(self, mode):
        try:
            with open(WALL_MODE, "w") as f:
                f.write(mode + "\n")
        except OSError:
            return
        spawn(["sh", WALL_SH])

    def wall_add(self):
        dlg = Gtk.FileChooserDialog(title="Выбери картинки", transient_for=self, action=Gtk.FileChooserAction.OPEN)
        dlg.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Добавить", Gtk.ResponseType.ACCEPT)
        dlg.set_select_multiple(True)
        flt = Gtk.FileFilter()
        flt.set_name("Картинки")
        for e in IMG_EXT:
            flt.add_pattern("*" + e)
            flt.add_pattern("*" + e.upper())
        dlg.add_filter(flt)
        start = os.path.join(HOME, "Downloads")
        dlg.set_current_folder(start if os.path.isdir(start) else HOME)
        files = dlg.get_filenames() if dlg.run() == Gtk.ResponseType.ACCEPT else []
        dlg.destroy()
        if not files:
            return
        os.makedirs(WALL, exist_ok=True)
        n = 0
        for f in files:
            try:
                shutil.copy2(f, unique(WALL, os.path.basename(f)))
                n += 1
            except OSError as e:
                self.say("Ошибка: " + str(e), True)
        if n:
            self.say(f"Добавлено картинок: {n}")
        self.load_walls()

    # ================= Экран =================
    def build_display(self):
        p = self.page("Экран", "Яркость, ночной свет и масштаб")
        g = self.group(p, "Яркость")
        b = get_brightness()
        if b is None:
            self.row(g, "Яркость", "Подсветка не найдена (у внешних мониторов меняется кнопками на мониторе)")
        else:
            self.row(g, "Яркость экрана", None, self.slider(
                1, 100, 1, b, lambda v: f"{v}%",
                lambda v: fire(["brightnessctl", "-c", "backlight", "set", f"{v}%"])))

        g = self.group(p, "Ночной свет")
        if shutil.which("hyprsunset"):
            sw = Gtk.Switch()
            sw.set_active(bool(out(["pgrep", "-x", "hyprsunset"])))
            sw.connect("notify::active", lambda w, _p: self.night(w.get_active()))
            self.night_sw = sw
            self.row(g, "Тёплые цвета", "Меньше синего света вечером. Действует до выхода из сеанса", sw)
            self.row(g, "Теплота", "Меньше - теплее", self.slider(
                2500, 6000, 100, self.st["night_temp"], lambda v: f"{v} K", self.night_temp))
        else:
            self.row(g, "Тёплые цвета", "Нужен маленький пакет hyprsunset",
                     self.button("Установить", lambda: in_terminal("sudo pacman -S --needed hyprsunset",
                                                                   "Установка hyprsunset"), "list-add-symbolic"))

        g = self.group(p, "Мониторы")
        try:
            mons = json.loads(out(["hyprctl", "monitors", "-j"]) or "[]")
        except ValueError:
            mons = []
        if not mons:
            self.row(g, "Мониторы", "Не удалось получить список от Hyprland")
        for m in mons:
            name = m.get("name", "?")
            sc = float(m.get("scale", 1) or 1)
            items = [("1", "100%"), ("1.25", "125%"), ("1.5", "150%"), ("2", "200%")]
            cur = f"{sc:g}"
            if cur not in [i for i, _ in items]:
                items.append((cur, f"{sc * 100:.0f}%"))
            desc = f"{m.get('width', '?')}×{m.get('height', '?')} @ {float(m.get('refreshRate', 0)):.0f} Гц"
            if m.get("description"):
                desc += " · " + m["description"]
            self.row(g, name, desc, self.combo(items, cur, lambda s, n=name: self.set_scale(n, s)))
        return p

    def night(self, on):
        if on:
            spawn(["hyprsunset", "-t", str(self.st["night_temp"])])
            self.say("Ночной свет включён")
        else:
            fire(["pkill", "-x", "hyprsunset"])

    def night_temp(self, v):
        self.st["night_temp"] = v
        self.queue_save()
        if not getattr(self, "night_sw", None) or not self.night_sw.get_active():
            return

        def work():
            r = sh(["hyprctl", "hyprsunset", "temperature", str(v)], 3)
            if not r or r.returncode != 0 or "ok" not in r.stdout.lower():
                sh(["pkill", "-x", "hyprsunset"])
                time.sleep(0.3)
                spawn(["hyprsunset", "-t", str(v)])
        threading.Thread(target=work, daemon=True).start()

    def set_scale(self, name, s):
        self.st.setdefault("scales", {})[name] = float(s)
        self.keyword("monitor", f"{name},preferred,auto,{s}")
        self.queue_save()
        self.say(f"Масштаб {name}: {float(s) * 100:.0f}%")

    # ================= Звук =================
    def build_sound(self):
        p = self.page("Звук", "Громкость, устройства и проверка")
        for target, title, kind in (("@DEFAULT_AUDIO_SINK@", "Вывод", "sink"),
                                    ("@DEFAULT_AUDIO_SOURCE@", "Микрофон", "source")):
            g = self.group(p, title)
            st = wp_state(target)
            if not st:
                self.row(g, "Устройство не найдено", "Проверь, что запущены pipewire и wireplumber")
                continue
            self.row(g, "Громкость", None, self.slider(
                0, 100, 1, st[0], lambda v: f"{v}%",
                lambda v, t=target: fire(["wpctl", "set-volume", t, f"{v / 100:.2f}"])))
            sw = Gtk.Switch()
            sw.set_active(st[1])
            sw.connect("notify::active",
                       lambda w, _p, t=target: fire(["wpctl", "set-mute", t, "1" if w.get_active() else "0"]))
            self.row(g, "Выключить", None, sw)
            c = self.device_combo(kind)
            if c:
                self.row(g, "Устройство", None, c)
        g = self.group(p, "Проверка")
        self.row(g, "Тестовый звонок", "Короткий сигнал через текущий вывод",
                 self.button("Проиграть", play_beep, "media-playback-start-symbolic"))
        self.row(g, "Микшер приложений", "Громкость каждой программы отдельно",
                 self.button("Открыть", lambda: spawn(["/usr/local/bin/audio-menu"]), "view-list-symbolic"))
        return p

    def device_combo(self, kind):
        r = sh(["pactl", "--format=json", "list", kind + "s"])
        try:
            devs = json.loads(r.stdout) if r and r.returncode == 0 else []
        except ValueError:
            devs = []
        devs = [d for d in devs if d.get("name") and not str(d["name"]).endswith(".monitor")]
        if not devs:
            return None
        default = out(["pactl", "get-default-" + kind])
        items = [(d["name"], d.get("description") or d["name"]) for d in devs]
        return self.combo(items, default, lambda n: fire(["pactl", "set-default-" + kind, n]), width=270)

    # ================= Клавиатура и мышь =================
    def build_input(self):
        p = self.page("Клавиатура и мышь", "Раскладки: English и Русский")
        g = self.group(p, "Клавиатура")
        self.row(g, "Смена раскладки", "Super+Space работает всегда", self.combo(
            KB_TOGGLES, self.st["kb_toggle"], lambda v: self.set("kb_toggle", v)))
        self.add_slider(g, "repeat_rate", "Скорость автоповтора", "Сколько символов в секунду при удержании клавиши",
                        10, 80, 1, lambda v: f"{v}/с")
        self.add_slider(g, "repeat_delay", "Задержка автоповтора", "Через сколько начинается повтор",
                        150, 800, 10, lambda v: f"{v} мс")
        test = Gtk.Entry()
        test.set_placeholder_text("Попробуй печатать здесь…")
        test.set_width_chars(28)
        self.row(g, "Проверка", None, test)
        g = self.group(p, "Мышь и тачпад")
        self.add_slider(g, "sensitivity", "Чувствительность", "0 - как в системе по умолчанию",
                        -1, 1, 0.05, lambda v: f"{v:+.2f}", digits=2)
        self.add_switch(g, "natural_scroll", "Естественная прокрутка тачпада", "Контент едет за пальцами, как на телефоне")
        return p

    # ================= Питание =================
    def build_power(self):
        p = self.page("Питание", "Профиль работы, батарея и сеанс")
        g = self.group(p, "Профиль питания")
        tiles = Gtk.Box(spacing=10)
        tiles.set_homogeneous(True)
        for prof, icon, name, desc in PROFILES:
            b = Gtk.Button()
            b.get_style_context().add_class("tile")
            col = Gtk.Box(orientation=V, spacing=4)
            img = Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.DND)
            img.set_pixel_size(26)
            col.pack_start(img, False, False, 0)
            col.pack_start(lbl(name, "rtitle", xalign=0.5), False, False, 0)
            col.pack_start(lbl(desc, "rdesc", xalign=0.5), False, False, 0)
            b.add(col)
            b.connect("clicked", lambda w, pr=prof: self.set_profile(pr))
            tiles.pack_start(b, True, True, 0)
            self.prof_btns[prof] = b
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(tiles, True, True, 0)
        g.pack_start(r, False, False, 0)

        if battery():
            g = self.group(p, "Батарея")
            self.bat_rows = {}
            for key, title, desc in (("cap", "Заряд", None), ("status", "Состояние", None),
                                     ("eta", "Осталось", "Примерно, по текущему расходу"),
                                     ("health", "Здоровье", "Ёмкость относительно новой батареи"),
                                     ("cycles", "Циклов зарядки", None)):
                self.bat_rows[key] = self.value_row(g, title, desc)

        g = self.group(p, "Сеанс")
        box = Gtk.Box(spacing=8)
        for text, icon, act, cls in (("Сон", "weather-clear-night-symbolic", "suspend", None),
                                     ("Выйти", "system-log-out-symbolic", "exit", None),
                                     ("Перезагрузка", "system-reboot-symbolic", "reboot", None),
                                     ("Выключение", "system-shutdown-symbolic", "poweroff", "danger")):
            box.pack_start(self.button(text, lambda a=act: self.session(a), icon, cls), False, False, 0)
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(box, False, False, 0)
        g.pack_start(r, False, False, 0)
        return p

    def mark_profile(self, cur):
        for prof, b in self.prof_btns.items():
            ctx = b.get_style_context()
            (ctx.add_class if prof == cur else ctx.remove_class)("on")

    def set_profile(self, prof):
        def done(ok):
            if ok:
                self.mark_profile(prof)
                self.say("Профиль: " + dict((p[0], p[2]) for p in PROFILES)[prof])
            else:
                self.say("Не удалось переключить профиль (служба power-profiles-daemon?)", True)
        bg(lambda: ppd_set(prof), done)

    def update_power(self):
        if not self.bat_rows:
            return
        b = battery()
        if not b:
            return
        r = self.bat_rows
        r["cap"].set_text(f"{b['cap']}%")
        r["status"].set_text(STATUS_RU.get(b["status"], b["status"] or "-"))
        r["eta"].set_text(fmt_dur(b["eta"] * 3600) if b["eta"] else "-")
        r["health"].set_text(f"{b['health']}%" if b["health"] else "-")
        r["cycles"].set_text(str(b["cycles"]) if b["cycles"] else "-")

    def session(self, act):
        names = {"reboot": "Перезагрузить компьютер?", "poweroff": "Выключить компьютер?", "exit": "Выйти из сеанса?"}
        if act in names and not self.confirm(names[act], "Несохранённая работа в программах пропадёт."):
            return
        if act == "exit":
            logout()
        else:
            spawn(["systemctl", act])
        self.destroy()

    # ================= Сеть =================
    def build_network(self):
        p = self.page("Сеть", "Подключение, Wi-Fi и проверка связи")
        g = self.group(p, "Состояние")
        self.net_name = self.value_row(g, "Подключение")
        self.net_ip = self.value_row(g, "IP-адрес")
        self.net_dev = self.value_row(g, "Устройство")
        self.value_row(g, "Имя компьютера").set_text(socket.gethostname())
        g = self.group(p, "Wi-Fi")
        self.wifi_guard = False
        self.wifi_sw = Gtk.Switch()
        self.wifi_sw.connect("notify::active", self.on_wifi)
        self.row(g, "Wi-Fi", "Включить или выключить беспроводной модуль", self.wifi_sw)
        self.row(g, "Сети поблизости", "Откроется меню Wi-Fi из панели",
                 self.button("Выбрать сеть…", lambda: spawn(["/usr/local/bin/network-menu"]), "network-wireless-symbolic"))
        g = self.group(p, "Проверка")
        self.ping_lbl = lbl("-", "val", xalign=1)
        box = Gtk.Box(spacing=12)
        box.pack_start(self.ping_lbl, False, False, 0)
        box.pack_start(self.button("Проверить", self.ping, "emblem-synchronizing-symbolic"), False, False, 0)
        self.row(g, "Связь с интернетом", "Пинг до 1.1.1.1", box)
        return p

    def refresh_net(self):
        def work():
            info = {"name": "Нет подключения", "ip": "-", "dev": "-", "radio": None}
            o = out(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"], 5, C_ENV)
            for line in o.splitlines():
                f = [x.replace("\\:", ":") for x in re.split(r"(?<!\\):", line)]
                if len(f) >= 4 and f[2] == "connected" and f[1] in ("wifi", "ethernet"):
                    info["name"] = f[3] + ("  (Wi-Fi)" if f[1] == "wifi" else "  (кабель)")
                    info["dev"] = f[0]
                    for l2 in out(["nmcli", "-t", "-f", "IP4.ADDRESS", "device", "show", f[0]], 5, C_ENV).splitlines():
                        parts = l2.split(":", 1)
                        if len(parts) == 2 and parts[1]:
                            info["ip"] = parts[1].split("/")[0]
                            break
                    break
            radio = out(["nmcli", "radio", "wifi"], 5, C_ENV)
            info["radio"] = (radio == "enabled") if radio else None
            return info

        def done(info):
            self.net_name.set_text(info["name"])
            self.net_ip.set_text(info["ip"])
            self.net_dev.set_text(info["dev"])
            self.wifi_guard = True
            self.wifi_sw.set_active(bool(info["radio"]))
            self.wifi_guard = False
            self.wifi_sw.set_sensitive(info["radio"] is not None)
        bg(work, done)

    def on_wifi(self, sw, _p):
        if self.wifi_guard:
            return
        fire(["nmcli", "radio", "wifi", "on" if sw.get_active() else "off"])
        self.say("Включаю Wi-Fi…" if sw.get_active() else "Wi-Fi выключен")
        GLib.timeout_add(2500, lambda: self.refresh_net() and False)

    def ping(self):
        self.ping_lbl.set_text("проверяю…")

        def work():
            r = sh(["ping", "-c", "3", "-W", "2", "1.1.1.1"], 12, C_ENV)
            if r is None:
                return "ping недоступен"
            m = re.search(r"= [\d.]+/([\d.]+)/", r.stdout)
            if r.returncode == 0 and m:
                return f"есть, {float(m.group(1)):.0f} мс"
            return "нет связи"
        bg(work, self.ping_lbl.set_text)

    # ================= Хранилище =================
    def build_storage(self):
        p = self.page("Хранилище", "Место на дисках и уборка")
        g = self.group(p, "Диски")
        mounts = [("/", "Система")]
        try:
            if os.stat(HOME).st_dev != os.stat("/").st_dev:
                mounts.append((HOME, "Домашняя папка"))
        except OSError:
            pass
        for line in read("/proc/mounts").splitlines():
            parts = line.split()
            if len(parts) > 1 and parts[1].startswith(("/run/media/", "/media/")):
                mp = parts[1].replace("\\040", " ")
                mounts.append((mp, os.path.basename(mp)))
        for path, title in mounts:
            self.disk_row(g, path, title)

        g = self.group(p, "Что занимает место")
        self.sizes = []
        for title, path in (("Кэш программ", os.path.join(HOME, ".cache")), ("Корзина", TRASH),
                            ("Загрузки", os.path.join(HOME, "Downloads")), ("Кэш pacman", "/var/cache/pacman/pkg")):
            self.sizes.append((self.value_row(g, title, path.replace(HOME, "~", 1)), path))

        g = self.group(p, "Уборка")
        for title, desc, text, cb, cls in (
                ("Кэш программ", "Миниатюры, кэш браузера и т.п. Пересоздаётся сам", "Очистить", self.clean_cache, None),
                ("Корзина", "Удалить всё из корзины навсегда", "Очистить", self.empty_trash, "danger"),
                ("Кэш pacman", "Старые версии скачанных пакетов", "Очистить",
                 lambda: in_terminal("sudo pacman -Sc", "Кэш pacman"), None),
                ("Ненужные пакеты", "Зависимости, которые больше ничему не нужны", "Найти и удалить",
                 lambda: in_terminal('o="$(pacman -Qdtq)"; if [ -n "$o" ]; then sudo pacman -Rns $o; '
                                     'else echo "Лишних пакетов нет"; fi', "Ненужные пакеты"), None),
                ("Системный журнал", "Ужать логи до 50 МБ", "Ужать",
                 lambda: in_terminal("sudo journalctl --vacuum-size=50M", "Журнал"), None),
                ("Обновление системы", "Arch - rolling: обновляйся регулярно", "Обновить",
                 lambda: in_terminal("sudo pacman -Syu", "Обновление системы"), "accent")):
            self.row(g, title, desc, self.button(text, cb, cls=cls))
        return p

    def disk_row(self, g, path, title):
        try:
            du = shutil.disk_usage(path)
        except OSError:
            return
        f = du.used / du.total if du.total else 0
        box = Gtk.Box(orientation=V, spacing=4)
        box.set_size_request(300, -1)
        bar = Gtk.ProgressBar()
        bar.set_fraction(f)
        if f > 0.9:
            bar.get_style_context().add_class("crit")
        elif f > 0.75:
            bar.get_style_context().add_class("warn")
        box.pack_start(bar, False, False, 0)
        box.pack_start(lbl(f"{human(du.used)} из {human(du.total)}  ·  свободно {human(du.free)}", "rdesc", xalign=1),
                       False, False, 0)
        self.row(g, title, path.replace(HOME, "~", 1), box)

    def refresh_storage(self):
        for v, _ in self.sizes:
            v.set_text("считаю…")

        def work():
            return [dir_size(path) if os.path.isdir(path) else 0 for _, path in self.sizes]

        def done(res):
            for (v, _), n in zip(self.sizes, res):
                v.set_text(human(n))
        bg(work, done)

    def clean_cache(self):
        if not self.confirm("Очистить кэш программ (~/.cache)?",
                            "Программы пересоздадут его сами, первые запуски могут быть чуть медленнее. "
                            "Лучше закрыть браузер перед очисткой."):
            return
        keep = {"wallpaper", NAME}

        def work():
            base = os.path.join(HOME, ".cache")
            freed = 0
            try:
                names = os.listdir(base)
            except OSError:
                return 0
            for n in names:
                if n in keep:
                    continue
                pth = os.path.join(base, n)
                try:
                    if os.path.isdir(pth) and not os.path.islink(pth):
                        size = dir_size(pth)
                        shutil.rmtree(pth, ignore_errors=True)
                    else:
                        size = os.lstat(pth).st_size
                        os.remove(pth)
                    freed += size
                except OSError:
                    pass
            return freed
        self.say("Чищу кэш…")
        bg(work, lambda n: (self.say("Освобождено: " + human(n)), self.refresh_storage()))

    def empty_trash(self):
        if not self.confirm("Очистить корзину насовсем?"):
            return

        def work():
            for d in ("files", "info"):
                base = os.path.join(TRASH, d)
                try:
                    names = os.listdir(base)
                except OSError:
                    continue
                for n in names:
                    pth = os.path.join(base, n)
                    try:
                        if os.path.isdir(pth) and not os.path.islink(pth):
                            shutil.rmtree(pth)
                        else:
                            os.remove(pth)
                    except OSError:
                        pass
        bg(work, lambda _r: (self.say("Корзина пуста"), self.refresh_storage()))

    # ================= Горячие клавиши =================
    def build_keys(self):
        p = self.page("Горячие клавиши", "Super - клавиша с логотипом Windows")
        e = Gtk.SearchEntry()
        e.set_placeholder_text("Найти действие или клавишу…")
        e.set_margin_top(10)
        e.set_margin_bottom(6)
        p.pack_start(e, False, False, 0)
        g = Gtk.Box(orientation=V)
        g.get_style_context().add_class("group")
        p.pack_start(g, False, False, 0)
        rows = []
        for keys, desc in HOTKEYS:
            r = Gtk.Box(spacing=12)
            r.get_style_context().add_class("krow")
            kb = Gtk.Box(spacing=4)
            kb.set_size_request(250, -1)
            for i, part in enumerate(keys.split("+")):
                if i:
                    kb.pack_start(lbl("+", "rdesc"), False, False, 0)
                kb.pack_start(lbl(part, "kbd", xalign=0.5), False, False, 0)
            r.pack_start(kb, False, False, 0)
            r.pack_start(lbl(desc, "rtitle", wrap=True), True, True, 0)
            g.pack_start(r, False, False, 0)
            rows.append((r, (keys + " " + desc).lower()))

        def filt(entry):
            q = entry.get_text().strip().lower()
            for r, t in rows:
                r.set_visible(q in t)
        e.connect("search-changed", filt)
        return p

    # ================= Разное =================
    def build_fun(self):
        p = self.page("Разное", "Полезные мелочи и немного веселья")
        g = self.group(p, "Режимы")
        sw = Gtk.Switch()
        sw.set_active(bool(self.st.get("game")))
        sw.connect("notify::active", lambda w, _p: self.toggle_game(w.get_active()))
        self.row(g, "Игровой режим", "Без отступов, размытия и анимаций + профиль «Мощность». "
                                     "Выключишь - всё вернётся как было", sw)
        self.row(g, "Панель сверху", "Спрятать или вернуть waybar",
                 self.button("Скрыть / показать", lambda: fire(["pkill", "-SIGUSR1", "-x", "waybar"]), "view-conceal-symbolic"))

        g = self.group(p, "Помидор - таймер концентрации")
        box = Gtk.Box(spacing=26)
        box.get_style_context().add_class("srow")
        self.pomo_ring = Ring("работа", 170)
        box.pack_start(self.pomo_ring, False, False, 0)
        ctl = Gtk.Box(orientation=V, spacing=10)
        ctl.set_valign(CENTER)
        ctl.pack_start(lbl("Работай, пока идёт таймер, потом отдохни. Звонок прозвучит сам, "
                           "а рабочий стол с Настройками подсветится в панели.", "rdesc", wrap=True), False, False, 0)
        self.pomo_combo = self.combo((("25/5", "25 мин работы / 5 отдыха"), ("50/10", "50 / 10"),
                                      ("15/3", "15 / 3")), "25/5", lambda _v: self.pomo_reset())
        self.pomo_combo.set_halign(Gtk.Align.START)
        ctl.pack_start(self.pomo_combo, False, False, 0)
        btns = Gtk.Box(spacing=8)
        self.pomo_btn = self.button("Старт", self.pomo_toggle, "media-playback-start-symbolic", "accent")
        btns.pack_start(self.pomo_btn, False, False, 0)
        btns.pack_start(self.button("Сброс", self.pomo_reset, "view-refresh-symbolic"), False, False, 0)
        btns.pack_start(self.button("Пропустить", self.pomo_skip, "media-skip-forward-symbolic"), False, False, 0)
        ctl.pack_start(btns, False, False, 0)
        box.pack_start(ctl, True, True, 0)
        g.pack_start(box, False, False, 0)
        self.pomo_reset()

        g = self.group(p, "Случайность")
        box = Gtk.Box(spacing=18)
        box.get_style_context().add_class("srow")
        self.dice = lbl("⚄", "dice", xalign=0.5)
        self.dice.set_width_chars(2)
        box.pack_start(self.dice, False, False, 0)
        col = Gtk.Box(orientation=V, spacing=8)
        col.set_valign(CENTER)
        self.chance = lbl("Не знаешь, что выбрать? Доверься случаю.", "chance")
        col.pack_start(self.chance, False, False, 0)
        bb = Gtk.Box(spacing=8)
        bb.pack_start(self.button("Бросить кубик", self.roll), False, False, 0)
        bb.pack_start(self.button("Подбросить монетку", self.coin), False, False, 0)
        bb.pack_start(self.button("Число 1-100", lambda: self.chance.set_text(f"Число: {random.randint(1, 100)}")),
                      False, False, 0)
        col.pack_start(bb, False, False, 0)
        box.pack_start(col, True, True, 0)
        g.pack_start(box, False, False, 0)

        g = self.group(p, "Совет")
        self.tip = lbl(random.choice(TIPS), "tip", wrap=True)
        self.tip.set_max_width_chars(60)
        box = Gtk.Box(spacing=12)
        box.get_style_context().add_class("srow")
        box.pack_start(self.tip, True, True, 0)
        box.pack_end(self.button("Ещё", self.next_tip, "go-next-symbolic"), False, False, 0)
        g.pack_start(box, False, False, 0)

        g = self.group(p, "Для красоты")
        box = Gtk.Box(spacing=8)
        box.pack_start(self.button("Визуализатор cava", lambda: spawn(["alacritty", "-e", "cava"]),
                                   "audio-x-generic-symbolic"), False, False, 0)
        box.pack_start(self.button("fastfetch", lambda: spawn(["alacritty", "-e", "sh",
                                                               os.path.join(HOME, ".config", "fastfetch", "show.sh")]),
                                   "utilities-terminal-symbolic"), False, False, 0)
        box.pack_start(self.button("Случайные обои", self.random_wall, "media-playlist-shuffle-symbolic"),
                       False, False, 0)
        r = Gtk.Box()
        r.get_style_context().add_class("srow")
        r.pack_start(box, False, False, 0)
        g.pack_start(r, False, False, 0)
        return p

    def toggle_game(self, on):
        if self.syncing:
            return
        if on:
            if not self.st.get("game"):
                backup = {k: self.st[k] for k in GAME}
                backup["profile"] = out(["powerprofilesctl", "get"])
                self.st["game"] = backup
            self.apply_values(GAME)
            threading.Thread(target=ppd_set, args=("performance",), daemon=True).start()
            self.say("Игровой режим включён")
        else:
            b = dict(self.st.get("game") or {})
            self.st["game"] = None
            prof = b.pop("profile", "")
            self.apply_values({k: b.get(k, DEFAULTS[k]) for k in GAME})
            if prof:
                threading.Thread(target=ppd_set, args=(prof,), daemon=True).start()
            self.say("Игровой режим выключен - всё как было")
        self.queue_save()

    def pomo_lens(self):
        try:
            w, b = (int(x) for x in (self.pomo_combo.get_active_id() or "25/5").split("/"))
        except ValueError:
            w, b = 25, 5
        return {"work": w * 60, "break": b * 60}

    def pomo_draw(self):
        s = self.pomo
        total = self.pomo_lens()[s["mode"]]
        m, sec = divmod(max(s["left"], 0), 60)
        self.pomo_ring.title = "работа" if s["mode"] == "work" else "перерыв"
        self.pomo_ring.set(s["left"] / total if total else 0, f"{m:02d}:{sec:02d}", 0 if s["mode"] == "work" else 1)

    def pomo_toggle(self):
        s = self.pomo
        s["run"] = not s["run"]
        self.pomo_btn.text_label.set_text("Пауза" if s["run"] else "Продолжить")
        if s["run"] and not s["id"]:
            s["id"] = GLib.timeout_add_seconds(1, self.pomo_tick)

    def pomo_tick(self):
        s = self.pomo
        if not s["run"]:
            s["id"] = 0
            return False
        s["left"] -= 1
        if s["left"] <= 0:
            play_beep()
            self.set_urgency_hint(True)
            s["mode"] = "break" if s["mode"] == "work" else "work"
            s["left"] = self.pomo_lens()[s["mode"]]
            self.say("Время отдохнуть!" if s["mode"] == "break" else "Перерыв окончен - за дело!")
        self.pomo_draw()
        return True

    def pomo_reset(self):
        s = self.pomo
        s["run"], s["mode"] = False, "work"
        s["left"] = self.pomo_lens()["work"]
        self.pomo_btn.text_label.set_text("Старт")
        self.pomo_draw()

    def pomo_skip(self):
        s = self.pomo
        s["mode"] = "break" if s["mode"] == "work" else "work"
        s["left"] = self.pomo_lens()[s["mode"]]
        self.pomo_draw()

    def roll(self):
        faces = "⚀⚁⚂⚃⚄⚅"
        n = {"k": 0}

        def step():
            n["k"] += 1
            v = random.randrange(6)
            self.dice.set_text(faces[v])
            if n["k"] >= 10:
                self.chance.set_text(f"Выпало: {v + 1}")
                return False
            return True
        GLib.timeout_add(55, step)

    def coin(self):
        n = {"k": 0}

        def step():
            n["k"] += 1
            self.chance.set_text("Орёл…" if n["k"] % 2 else "Решка…")
            if n["k"] >= 8:
                self.chance.set_text("Выпало: " + random.choice(("Орёл", "Решка")))
                return False
            return True
        GLib.timeout_add(90, step)

    def next_tip(self):
        cur = self.tip.get_text()
        self.tip.set_text(random.choice([t for t in TIPS if t != cur]))


# ================= запуск =================
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


def main():
    GLib.set_prgname(NAME)
    GLib.set_application_name("Настройки")
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = Settings()

    def on_destroy(*_):
        drop_lock()
        Gtk.main_quit()
    w.connect("destroy", on_destroy)
    w.show_all()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    Gtk.main()


if __name__ == "__main__":
    main()
SETTINGS_EOF
chmod 755 /usr/local/bin/hypr-settings

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
  hl.exec_cmd("dbus-update-activation-environment --systemd --all")
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
hl.bind(mod .. " + SHIFT + I", hl.dsp.exec_cmd("/usr/local/bin/hypr-settings"))
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
hl.window_rule({ name = "float-hypr-settings", match = { class = "^(hypr-settings)$" }, float = true })

-- значения из приложения «Настройки» (Super+Shift+I); если файла нет - ничего не случится
pcall(function() dofile(os.getenv("HOME") .. "/.config/hypr/settings.lua") end)
EOF

# ---------- alacritty ----------
w "$H/.config/alacritty/alacritty.toml" <<'EOF'
[window]
decorations = "none"
opacity = 1.0

[colors.primary]
background = "#121712"
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
    "exec": "/usr/local/bin/performance-status",
    "return-type": "json",
    "interval": 30,
    "signal": 8,
    "format": "{}",
    "tooltip": true,
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
#custom-performance.power-saver { color: #a9cc82; }
#custom-performance.performance { color: #d8b76c; }
#custom-performance.unknown { color: #8a9a82; }
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

# Картинка для fastfetch: положи PNG в ~/.config/fastfetch/logo.png (лучше 512x512)
w "$H/.config/fastfetch/show.sh" <<'EOF'
#!/bin/sh
LOGO="$HOME/.config/fastfetch/logo.png"
if [ -f "$LOGO" ]; then
  fastfetch --logo "$LOGO" --logo-type chafa --logo-width 30 --logo-height 15
else
  fastfetch --logo none
fi
exec bash
EOF

w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
# Обои: положи картинки в ~/Pictures/wall, Super+W - следующая
# Сплошной цвет и режим растягивания выбираются в Настройках (Super+Shift+I)
D="$HOME/Pictures/wall"; C="$HOME/.cache/wallpaper"
m="$(cat "$HOME/.config/hypr/wallpaper-mode" 2>/dev/null)"
case "$m" in fill|fit|center|tile|stretch) ;; *) m=fill ;; esac
pkill swaybg 2>/dev/null
cur="$(cat "$C" 2>/dev/null)"
case "$cur" in color:*) [ "$1" = next ] || exec swaybg -c "${cur#color:}" ;; esac
list="$(ls "$D"/*.png "$D"/*.jpg "$D"/*.jpeg "$D"/*.webp 2>/dev/null)"
[ -n "$list" ] || exec swaybg -c 0f1410
if [ "$1" = next ]; then
  f="$(printf '%s\n' "$list" | awk -v c="$cur" 'f{print;exit} $0==c{f=1}')"
  [ -n "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
else
  f="$cur"; [ -f "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
fi
mkdir -p "$(dirname "$C")"; printf '%s\n' "$f" > "$C"
exec swaybg -i "$f" -m "$m"
EOF

# ---------- ярлыки и программы по умолчанию ----------
w "$H/.local/share/applications/cava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=cava
Exec=cava
NoDisplay=true
EOF
# Files: в wofi не показывается (NoDisplay), но остаётся программой для папок и открывается по Super+E
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
  if command -v start-hyprland >/dev/null 2>&1; then start-hyprland; else Hyprland; fi
fi
EOF
fi
mkdir -p "$H/Pictures/wall"

# реальное имя Font Awesome (иконки в меню)
FA="$(fc-list : family 2>/dev/null | grep -o 'Font Awesome [0-9]* Free' | head -n1 || true)"
FA="${FA:-Font Awesome 7 Free} Solid"
sed -i "s/FontAwesome/$FA/g" /usr/local/bin/power-menu /usr/local/lib/hypr-menus/hyprmenu.py \
  "$H/.config/waybar/style.css"
# заранее скомпилировать общий модуль меню - быстрее запуск
python3 -m compileall -q /usr/local/lib/hypr-menus >/dev/null 2>&1 || true

chown -R "$U:$G" "$H/.config" "$H/.local" "$H/Pictures" "$H/.bashrc" "$H/.bash_profile" 2>/dev/null || true
# стандартные папки с английскими именами (иначе при русской локали появятся «Изображения» и т.п.)
runuser -u "$U" -- env HOME="$H" LC_ALL=C LANG=C xdg-user-dirs-update 2>/dev/null || true

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
# (Files и Настройки в лаунчер не попадают: Super+E и Super+Shift+I)
allow="$( { for p in steam telegram-desktop happ firefox photocraft; do pacman -Ql "$p" 2>/dev/null; done \
  | awk '{print $2}' | grep '^/usr/share/applications/.*\.desktop$' | while read -r f; do basename "$f"; done
  printf '%s\n' onlyoffice.desktop photocraft.desktop limusic.desktop; } )"
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
echo "  Super+Shift+I     - настройки (повторное нажатие закрывает)"
echo "  Super+W           - следующие обои"
echo "  Super+V           - окно: плавающее / тайлинг"
echo "  Super+F           - полный экран"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть окно"
echo "  Super+Shift+Q     - зажми и води курсором: окна под ним закрываются подряд"
echo "  Super+Shift+S     - скриншот области в буфер"
