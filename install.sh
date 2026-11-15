#!/usr/bin/env bash
# Минимальная установка Arch Linux + Hyprland для Intel UHD Graphics (Core i5-10300H + GTX 1650).
# Запуск: sudo bash install.sh [имя_пользователя]
set -Eeuo pipefail
IFS=$'\n\t'

readonly GREEN='\033[0;32m' YELLOW='\033[0;33m' RED='\033[0;31m' RESET='\033[0m'
log()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!!${RESET} %s\n" "$*" >&2; }
die()  { printf "${RED}ОШИБКА:${RESET} %s\n" "$*" >&2; exit 1; }
trap 'rc=$?; printf "\n${RED}Сбой на строке %s (код %s).${RESET}\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash install.sh [пользователь]."
[[ -f /etc/arch-release ]] || die "Этот установщик предназначен только для Arch Linux."
command -v pacman >/dev/null || die "Не найден pacman."
command -v runuser >/dev/null || die "Не найден runuser."

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\/home\// {print $1; exit}')"
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Не удалось определить обычного пользователя. Укажи его: sudo bash install.sh ИМЯ."
id "$TARGET_USER" >/dev/null 2>&1 || die "Пользователь '$TARGET_USER' не существует."
TARGET_UID="$(id -u "$TARGET_USER")"
[[ "$TARGET_UID" -ge 1000 && "$TARGET_UID" -lt 60000 ]] || die "Укажи обычного пользователя с UID от 1000 до 59999."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$TARGET_HOME" && "$TARGET_HOME" != / ]] || die "Домашняя директория '$TARGET_HOME' не существует."

readonly APP_ROOT="/opt/hypr-minimal"
readonly LIB_ROOT="/usr/local/lib/hypr-minimal"
readonly BIN_ROOT="/usr/local/bin"
readonly CONFIG_ROOT="$TARGET_HOME/.config"
readonly STATE_ROOT="$TARGET_HOME/.local/state/hypr-minimal"
readonly BACKUP_ROOT="$TARGET_HOME/.local/share/hypr-minimal-backups/$(date +%Y%m%d-%H%M%S)"

backup_file() {
  local f="$1"
  if [[ -e "$f" || -L "$f" ]]; then
    mkdir -p "$BACKUP_ROOT$(dirname "$f")"
    cp -a -- "$f" "$BACKUP_ROOT$f"
    log "Резервная копия: $f"
  fi
}
write_file() {
  local dest="$1" mode="${2:-0644}" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ ! -L "$dest" && -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    backup_file "$dest"
    [[ ! -L "$dest" ]] || rm -f -- "$dest"
  fi
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

log "Пользователь: $TARGET_USER ($TARGET_HOME)"
log "Резервные копии конфигураций будут сохранены в $BACKUP_ROOT"

if ! grep -qE '^[[:space:]]*\[multilib\]' /etc/pacman.conf; then
  backup_file /etc/pacman.conf
  if grep -qE '^[[:space:]]*#\[multilib\]' /etc/pacman.conf; then
    sed -i '/^[[:space:]]*#\[multilib\]/,/^[[:space:]]*#Include/s/^[[:space:]]*#//' /etc/pacman.conf
  else
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
  fi
fi

log "Полное обновление Arch (необходимое условие корректной установки пакетов)"
pacman -Syu --needed --noconfirm

INTEL_GRAPHICS_PACKAGES=(mesa vulkan-intel lib32-mesa lib32-vulkan-intel intel-media-driver)
log "Установка только Intel-графического стека"
pacman -S --needed --noconfirm "${INTEL_GRAPHICS_PACKAGES[@]}"

CORE_PACKAGES=(
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xorg-xwayland
  waybar wofi alacritty qt6-wayland
  pipewire pipewire-pulse wireplumber
  grim slurp wl-clipboard brightnessctl
  swaybg
  gtk3 python python-gobject
  udisks2 gvfs xdg-utils xdg-user-dirs desktop-file-utils
  dbus libnotify power-profiles-daemon sudo polkit-gnome lua mako qt6ct
  fastfetch cava curl playerctl metadata-cleaner
  ttf-dejavu ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols noto-fonts-emoji
  adwaita-icon-theme
  firefox telegram-desktop prismlauncher jre21-openjdk
)
log "Установка базовой системы и основных приложений"
pacman -S --needed --noconfirm "${CORE_PACKAGES[@]}"
fc-cache -f >/dev/null 2>&1 || true

log "Установка Steam после закрепления Intel 64/32-bit Vulkan-провайдеров"
pacman -S --needed --noconfirm steam

usermod -aG wheel "$TARGET_USER"
SUDOERS_FILE="/etc/sudoers.d/10-hypr-minimal-wheel"
if [[ ! -e "$SUDOERS_FILE" ]]; then
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  if ! visudo -cf "$SUDOERS_FILE" >/dev/null; then
    rm -f "$SUDOERS_FILE"
    die "Не удалось проверить правило sudoers; файл удалён."
  fi
fi

[[ "$(uname -m)" == "x86_64" ]] || die "Поддерживается только x86_64."
INTEL_DRM_BY_PATH="/dev/dri/by-path/pci-0000:00:02.0-card"
INTEL_CARD_REAL=""
if [[ -e "$INTEL_DRM_BY_PATH" ]]; then
  INTEL_CARD_REAL="$(readlink -f "$INTEL_DRM_BY_PATH")"
else
  for card_sys in /sys/class/drm/card[0-9]*; do
    [[ -e "$card_sys/device/vendor" ]] || continue
    cname="${card_sys##*/}"
    [[ "$cname" =~ ^card[0-9]+$ ]] || continue
    if [[ "$(cat "$card_sys/device/vendor" 2>/dev/null || true)" == "0x8086" && -e "/dev/dri/$cname" ]]; then
      INTEL_CARD_REAL="/dev/dri/$cname"
      break
    fi
  done
fi
[[ -n "$INTEL_CARD_REAL" && -e "$INTEL_CARD_REAL" ]] || die "Не найден DRM-узел Intel UHD. Отказ от настройки, чтобы не допустить fallback на NVIDIA."
INTEL_CARD_NAME="${INTEL_CARD_REAL##*/}"
INTEL_VENDOR="$(cat "/sys/class/drm/$INTEL_CARD_NAME/device/vendor" 2>/dev/null || true)"
[[ "$INTEL_VENDOR" == "0x8086" ]] || die "Устройство $INTEL_CARD_REAL не подтверждено как Intel (vendor=$INTEL_VENDOR)."
INTEL_ICD="/usr/share/vulkan/icd.d/intel_icd.json"
[[ -r "$INTEL_ICD" ]] || die "Не найден Intel Vulkan ICD ($INTEL_ICD), хотя vulkan-intel был запрошен."

write_file /etc/udev/rules.d/99-intel-igpu-drm.rules 0644 <<'UDEV_INTEL'
KERNEL=="card*", KERNELS=="0000:00:02.0", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", ATTRS{vendor}=="0x8086", SYMLINK+="dri/intel-igpu"
UDEV_INTEL
udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --subsystem-match=drm >/dev/null 2>&1 || true

install -d -m 0755 "$LIB_ROOT" "$APP_ROOT" "$BIN_ROOT"
write_file "$BIN_ROOT/arch-package-install" 0755 <<'PKG_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
f="${1:-}"
[[ -n "$f" ]] || { echo "Не передан файл пакета."; read -r -p "Enter для выхода "; exit 2; }
f="$(realpath -- "$f")"
[[ -f "$f" && -r "$f" ]] || { echo "Файл не найден или недоступен: $f"; read -r -p "Enter для выхода "; exit 2; }
case "$f" in
  *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz|*.pkg.tar) ;;
  *) echo "Неподдерживаемый формат. Ожидается .pkg.tar.zst/.xz/.gz."; read -r -p "Enter для выхода "; exit 2 ;;
esac
echo "Локальный пакет: $f"
echo "Проверяю архив..."
if ! bsdtar -tf "$f" >/dev/null 2>&1; then
  echo "Архив повреждён или имеет неверный формат."
  read -r -p "Enter для выхода "; exit 1
fi
echo
read -r -p "Передать пакет pacman для установки? [y/N] " answer
[[ "$answer" =~ ^[YyДд]$ ]] || { echo "Отменено."; read -r -p "Enter для выхода "; exit 0; }
if sudo pacman -U -- "$f"; then
  echo "Установка завершена."
else
  rc=$?
  echo "pacman завершился с кодом $rc. Проверка подписей и системные настройки pacman не изменялись."
  read -r -p "Enter для выхода "
  exit "$rc"
fi
read -r -p "Enter для выхода "
PKG_INSTALL

write_file "$LIB_ROOT/files.py" 0644 <<'FILES_PY'
#!/usr/bin/env python3
import os, sys, shutil, subprocess, json
from urllib.parse import unquote
from pathlib import Path
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gio", "2.0")
from gi.repository import Gtk, Gio, Gdk, GLib

HOME = Path.home()
TRASH = HOME / ".local/share/Trash"
FILES, INFO = TRASH / "files", TRASH / "info"
BOOKMARKS = HOME / ".config/files/bookmarks"
PKG_SUFFIXES = (".pkg.tar.zst", ".pkg.tar.xz", ".pkg.tar.gz", ".pkg.tar")

CSS = b"""
* { font-family: 'DejaVu Sans', sans-serif; font-size: 10pt; }
window { background: #111512; color: #e1e7df; }
headerbar, toolbar { background: #171d18; color: #e1e7df; }
button { background: #202a21; color: #e1e7df; border: 1px solid #39483a; border-radius: 7px; padding: 5px 9px; }
button:hover, button:checked { background: #354832; border-color: #82965a; }
entry { background: #171e18; color: #e1e7df; border: 1px solid #526447; border-radius: 6px; padding: 6px; }
treeview { background: #111512; color: #e1e7df; }
treeview:selected { background: #405238; color: #f0f4e9; }
.sidebar { background: #151b16; }
.dim-label { color: #a0aa9d; }
"""

def css():
    p = Gtk.CssProvider()
    p.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def human(n):
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} ПБ"

def unique_path(folder, name):
    p = folder / name
    if not p.exists():
        return p
    base, ext = os.path.splitext(name)
    i = 1
    while (folder / f"{base} ({i}){ext}").exists():
        i += 1
    return folder / f"{base} ({i}){ext}"

def is_arch_pkg(path):
    return path.is_file() and path.name.lower().endswith(PKG_SUFFIXES)

class FilesWindow(Gtk.Window):
    def __init__(self, start):
        super().__init__(title="Files")
        self.set_default_size(1000, 650)
        self.cwd = Path(start).expanduser().resolve()
        FILES.mkdir(parents=True, exist_ok=True)
        INFO.mkdir(parents=True, exist_ok=True)
        self.clipboard_paths, self.cut = [], False
        self.sort_col, self.sort_reverse = 0, False
        self.store = Gtk.ListStore(str, str, str, bool, str)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add(root)
        bar = Gtk.Box(spacing=5)
        bar.set_margin_top(8); bar.set_margin_start(8); bar.set_margin_end(8)
        root.pack_start(bar, False, False, 0)
        for label, cb in (("←", self.back), ("↑", self.up), ("Обновить", self.refresh)):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda _b, f=cb: f())
            bar.pack_start(b, False, False, 0)
        self.path_entry = Gtk.Entry()
        self.path_entry.set_text(str(self.cwd))
        self.path_entry.connect("activate", self.go_entry)
        bar.pack_start(self.path_entry, True, True, 0)
        new = Gtk.Button(label="Новая папка")
        new.connect("clicked", self.new_folder)
        bar.pack_start(new, False, False, 0)
        split = Gtk.Paned()
        root.pack_start(split, True, True, 0)
        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("sidebar")
        self.side.connect("row-activated", self.side_open)
        self.side.connect("button-press-event", self.side_context)
        sw = Gtk.ScrolledWindow(); sw.set_size_request(190, -1); sw.add(self.side)
        split.pack1(sw, False, False)
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        split.pack2(right, True, False)
        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text("Поиск в текущей папке…")
        self.search.connect("search-changed", self.refresh)
        right.pack_start(self.search, False, False, 4)
        self.view = Gtk.TreeView(model=self.store)
        self.view.set_headers_clickable(True)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        for title, idx in (("Имя", 0), ("Размер", 1), ("Изменён", 2)):
            r = Gtk.CellRendererText()
            col = Gtk.TreeViewColumn(title, r, text=idx)
            col.set_resizable(True); col.set_clickable(True)
            col.connect("clicked", self.sort_by, idx)
            self.view.append_column(col)
        self.view.connect("row-activated", self.activate)
        self.view.connect("button-press-event", self.context_menu)
        targets = [Gtk.TargetEntry.new("text/uri-list", 0, 0)]
        self.view.enable_model_drag_source(Gdk.ModifierType.BUTTON1_MASK, targets, Gdk.DragAction.COPY | Gdk.DragAction.MOVE)
        self.view.drag_dest_set(Gtk.DestDefaults.ALL, targets, Gdk.DragAction.COPY | Gdk.DragAction.MOVE)
        self.view.connect("drag-data-get", self.drag_get)
        self.view.connect("drag-data-received", self.drag_receive)
        sw2 = Gtk.ScrolledWindow(); sw2.add(self.view)
        right.pack_start(sw2, True, True, 0)
        self.status = Gtk.Label(xalign=0)
        self.status.set_margin_start(10); self.status.set_margin_bottom(6)
        root.pack_start(self.status, False, False, 0)
        self.connect("key-press-event", self.keypress)
        self.build_sidebar(); self.refresh()

    def build_sidebar(self):
        for c in self.side.get_children():
            self.side.remove(c)
        places = [
            ("Домашняя папка", HOME), ("Рабочий стол", HOME / "Desktop"),
            ("Документы", HOME / "Documents"), ("Загрузки", HOME / "Downloads"),
            ("Изображения", HOME / "Pictures"), ("Музыка", HOME / "Music"),
            ("Видео", HOME / "Videos"), ("Корзина", FILES),
        ]
        for title, path in places:
            row = Gtk.ListBoxRow()
            row.add(Gtk.Label(label=title, xalign=0, margin=8))
            row.path = path
            self.side.add(row)
        try:
            data = json.loads(subprocess.run(
                ["lsblk", "-J", "-o", "PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM"],
                capture_output=True, text=True, timeout=5, check=True
            ).stdout)
            def add_devices(nodes):
                for node in nodes:
                    if node.get("fstype") and node.get("path") and node.get("fstype") not in ("crypto_LUKS", "swap", "LVM2_member"):
                        mounts = [m for m in (node.get("mountpoints") or []) if m]
                        removable = str(node.get("rm", "0")) == "1"
                        external_mount = any(m.startswith(("/run/media/", "/media/", "/mnt/")) for m in mounts)
                        if removable or external_mount:
                            row = Gtk.ListBoxRow()
                            row.add(Gtk.Label(label="▤ " + (node.get("label") or Path(node["path"]).name), xalign=0, margin=8))
                            row.device = node["path"]
                            row.mountpoint = mounts[0] if mounts else None
                            self.side.add(row)
                    add_devices(node.get("children") or [])
            add_devices(data.get("blockdevices") or [])
        except Exception:
            pass
        try:
            for line in BOOKMARKS.read_text().splitlines():
                p = Path(line)
                if p.is_dir():
                    row = Gtk.ListBoxRow()
                    row.add(Gtk.Label(label="★ " + p.name, xalign=0, margin=8))
                    row.path = p; row.bookmark = True
                    self.side.add(row)
        except OSError:
            pass
        self.side.show_all()

    def side_open(self, _box, row):
        if not row:
            return
        if hasattr(row, "device"):
            if row.mountpoint:
                self.load(row.mountpoint)
            else:
                r = subprocess.run(["udisksctl", "mount", "-b", row.device], capture_output=True, text=True)
                if r.returncode == 0:
                    import re
                    m = re.search(r" at (.+?)\.?\s*$", r.stdout.strip())
                    if m:
                        self.load(m.group(1))
                    self.build_sidebar()
                else:
                    self.message((r.stderr or r.stdout).strip() or "Не удалось подключить накопитель")
        elif hasattr(row, "path") and row.path.exists():
            self.load(row.path)

    def side_context(self, _box, event):
        if event.button != 3:
            return False
        row = self.side.get_row_at_y(int(event.y))
        if not row:
            return False
        menu = Gtk.Menu()
        if hasattr(row, "bookmark"):
            item = Gtk.MenuItem(label="Убрать закладку")
            def remove_bm(*_):
                marks = BOOKMARKS.read_text().splitlines() if BOOKMARKS.exists() else []
                BOOKMARKS.write_text("\n".join(x for x in marks if x != str(row.path)) + "\n")
                self.build_sidebar()
            item.connect("activate", remove_bm)
            menu.append(item); menu.show_all(); menu.popup_at_pointer(event)
            return True
        if not hasattr(row, "device"):
            return False
        if row.mountpoint:
            item = Gtk.MenuItem(label="Отключить накопитель")
            def action(*_):
                r = subprocess.run(["udisksctl", "unmount", "-b", row.device], capture_output=True, text=True)
                if r.returncode == 0:
                    if str(self.cwd).startswith(row.mountpoint):
                        self.load(HOME)
                    self.build_sidebar()
                else:
                    self.message((r.stderr or r.stdout).strip() or "Не удалось отключить накопитель")
        else:
            item = Gtk.MenuItem(label="Подключить накопитель")
            def action(*_):
                self.side_open(self.side, row)
        item.connect("activate", action)
        menu.append(item); menu.show_all(); menu.popup_at_pointer(event)
        return True

    def load(self, path):
        p = Path(path).expanduser()
        if not p.is_dir():
            return
        self.cwd = p.resolve()
        self.path_entry.set_text(str(self.cwd))
        self.refresh()

    def refresh(self, *_):
        self.store.clear()
        try:
            entries = list(self.cwd.iterdir())
        except OSError as e:
            self.status.set_text(str(e))
            return
        query = self.search.get_text().casefold()
        entries = [p for p in entries if query in p.name.casefold()]
        def order_key(p):
            try:
                st = p.stat()
                value = p.name.casefold() if self.sort_col == 0 else (st.st_size if self.sort_col == 1 else st.st_mtime)
            except OSError:
                value = 0
            return (not p.is_dir(), value)
        entries.sort(key=order_key, reverse=self.sort_reverse)
        for p in entries:
            try:
                st = p.lstat()
                size = "—" if p.is_dir() else human(st.st_size)
                date = GLib.DateTime.new_from_unix_local(int(st.st_mtime)).format("%Y-%m-%d %H:%M")
                self.store.append([p.name, size, date, p.is_dir(), str(p)])
            except OSError:
                continue
        self.status.set_text(f"{len(entries)} объектов · {self.cwd}")

    def sort_by(self, _col, idx):
        self.sort_reverse = not self.sort_reverse if self.sort_col == idx else False
        self.sort_col = idx
        self.refresh()

    def go_entry(self, _entry): self.load(self.path_entry.get_text())
    def back(self): self.load(self.cwd.parent)
    def up(self): self.back()

    def selected(self):
        model, paths = self.view.get_selection().get_selected_rows()
        return [Path(model[p][4]) for p in paths]

    def install_pkg(self, pkg_path):
        subprocess.Popen(["alacritty", "--title", "Установка пакета Arch", "-e", "/usr/local/bin/arch-package-install", str(pkg_path)])

    def activate(self, _view, path, _col):
        p = Path(self.store[path][4])
        if p.is_dir():
            self.load(p)
        elif is_arch_pkg(p):
            self.install_pkg(p)
        else:
            try:
                Gio.AppInfo.launch_default_for_uri(p.as_uri(), None)
            except GLib.Error as e:
                self.message(f"Не удалось открыть файл: {e.message}")

    def new_folder(self, _b):
        d = Gtk.Dialog(title="Новая папка", transient_for=self, flags=0)
        d.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Создать", Gtk.ResponseType.OK)
        e = Gtk.Entry(); e.set_text("Новая папка"); d.get_content_area().add(e); d.show_all()
        if d.run() == Gtk.ResponseType.OK:
            name = e.get_text().strip()
            if name and "/" not in name:
                try:
                    (self.cwd / name).mkdir()
                except OSError as ex:
                    self.message(str(ex))
        d.destroy(); self.refresh()

    def message(self, text):
        m = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.INFO, buttons=Gtk.ButtonsType.OK, text=text)
        m.run(); m.destroy()

    def confirm(self, text):
        m = Gtk.MessageDialog(transient_for=self, flags=0, message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.YES_NO, text=text)
        ok = m.run() == Gtk.ResponseType.YES
        m.destroy()
        return ok

    def copy(self, cut=False):
        self.clipboard_paths = self.selected()
        self.cut = cut

    def paste(self):
        if not self.clipboard_paths:
            return
        for src in self.clipboard_paths:
            try:
                if src.parent.resolve() == self.cwd.resolve():
                    continue
                if src.is_dir() and self.cwd.resolve().is_relative_to(src.resolve()):
                    raise OSError("Нельзя копировать папку внутрь самой себя")
                dst = unique_path(self.cwd, src.name)
                if self.cut:
                    shutil.move(str(src), str(dst))
                elif src.is_dir():
                    shutil.copytree(src, dst)
                else:
                    shutil.copy2(src, dst)
            except OSError as e:
                self.message(str(e))
        if self.cut:
            self.clipboard_paths = []
        self.refresh()

    def delete(self, permanent=False):
        paths = self.selected()
        if not paths:
            return
        if not self.confirm(("Удалить навсегда " if permanent else "Переместить в корзину ") + f"{len(paths)} объект(ов)?"):
            return
        for p in paths:
            try:
                if permanent:
                    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
                else:
                    Gio.File.new_for_path(str(p)).trash(None)
            except (OSError, GLib.Error) as e:
                self.message(str(e))
        self.refresh()

    def rename(self):
        paths = self.selected()
        if len(paths) != 1:
            return
        d = Gtk.Dialog(title="Переименовать", transient_for=self, flags=0)
        d.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Сохранить", Gtk.ResponseType.OK)
        e = Gtk.Entry(); e.set_text(paths[0].name); d.get_content_area().add(e); d.show_all()
        if d.run() == Gtk.ResponseType.OK and e.get_text().strip():
            try:
                new_name = e.get_text().strip()
                if new_name in (".", "..") or "/" in new_name or "\\" in new_name:
                    raise OSError("Недопустимое имя файла")
                target = paths[0].with_name(new_name)
                if target.exists() or target.is_symlink():
                    raise OSError("Файл с таким именем уже существует; он не будет перезаписан")
                paths[0].rename(target)
            except (OSError, ValueError) as ex:
                self.message(str(ex))
        d.destroy(); self.refresh()

    def bookmark(self):
        p = str(self.cwd)
        BOOKMARKS.parent.mkdir(parents=True, exist_ok=True)
        old = BOOKMARKS.read_text().splitlines() if BOOKMARKS.exists() else []
        if p not in old:
            old.append(p)
        BOOKMARKS.write_text("\n".join(old) + "\n")
        self.build_sidebar()

    def restore_selected(self):
        for src in self.selected():
            info = INFO / (src.name + ".trashinfo")
            try:
                original = None
                for line in info.read_text(errors="replace").splitlines():
                    if line.startswith("Path="):
                        original = Path(unquote(line[5:]))
                        break
                if not original or not original.is_absolute():
                    raise OSError("Не удалось определить исходный путь")
                original.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(unique_path(original.parent, original.name)))
                info.unlink(missing_ok=True)
            except OSError as e:
                self.message(str(e))
        self.refresh()

    def drag_get(self, _view, _ctx, data, _info, _time):
        data.set_uris([p.as_uri() for p in self.selected()])

    def drag_receive(self, view, ctx, x, y, data, _info, _time):
        dest = self.cwd
        hit = view.get_dest_row_at_pos(x, y)
        if hit and self.store[hit[0]][3]:
            dest = Path(self.store[hit[0]][4])
        uris = data.get_uris() or []
        move = ctx.get_selected_action() == Gdk.DragAction.MOVE
        for uri in uris:
            src = Gio.File.new_for_uri(uri).get_path()
            if not src:
                continue
            src = Path(src)
            try:
                if src.resolve() == dest.resolve() or dest.resolve().is_relative_to(src.resolve()):
                    continue
                target = unique_path(dest, src.name)
                if move:
                    shutil.move(str(src), str(target))
                elif src.is_dir():
                    shutil.copytree(src, target)
                else:
                    shutil.copy2(src, target)
            except (OSError, ValueError) as e:
                self.message(str(e))
        ctx.finish(True, False, _time)
        self.refresh()

    def properties(self):
        paths = self.selected() or [self.cwd]
        lines = []
        for p in paths:
            try:
                if p.is_dir():
                    total = 0
                    for root, _dirs, files in os.walk(p, followlinks=False):
                        for name in files:
                            try:
                                total += (Path(root) / name).lstat().st_size
                            except OSError:
                                pass
                    size = "Папка · " + human(total)
                else:
                    size = human(p.lstat().st_size)
                lines.append(f"{p.name}: {size}")
            except OSError as e:
                lines.append(f"{p}: {e}")
        self.message("\n".join(lines))

    def context_menu(self, _view, event):
        if event.button != 3:
            return False
        sel = self.selected()
        menu = Gtk.Menu()
        actions = []
        if len(sel) == 1 and is_arch_pkg(sel[0]):
            actions.append(("Установить пакет (pacman)", lambda p=sel[0]: self.install_pkg(p)))
        actions.extend([
            ("Открыть папку", lambda: self.load(self.selected()[0]) if self.selected() and self.selected()[0].is_dir() else None),
            ("Копировать", lambda: self.copy(False)),
            ("Вырезать", lambda: self.copy(True)),
            ("Вставить", self.paste),
            ("Переименовать", self.rename),
            ("В корзину", lambda: self.delete(False)),
            ("Восстановить из корзины", self.restore_selected),
            ("Удалить навсегда", lambda: self.delete(True)),
            ("Свойства / размер", self.properties),
            ("Добавить текущую папку в закладки", self.bookmark),
        ])
        for label, cb in actions:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _i, f=cb: f())
            menu.append(item)
        menu.show_all(); menu.popup_at_pointer(event)
        return True

    def keypress(self, _w, e):
        key = Gdk.keyval_name(e.keyval)
        ctrl = bool(e.state & Gdk.ModifierType.CONTROL_MASK)
        if key == "Escape": self.destroy(); return True
        if key == "Delete": self.delete(False); return True
        if key == "F2": self.rename(); return True
        if ctrl and key.lower() == "c": self.copy(False); return True
        if ctrl and key.lower() == "x": self.copy(True); return True
        if ctrl and key.lower() == "v": self.paste(); return True
        if ctrl and key.lower() == "l": self.path_entry.grab_focus(); return True
        if ctrl and key.lower() == "d": self.bookmark(); return True
        return False

def main():
    css()
    start = sys.argv[1] if len(sys.argv) > 1 and Path(sys.argv[1]).is_dir() else str(HOME)
    w = FilesWindow(start)
    w.connect("destroy", Gtk.main_quit)
    w.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
FILES_PY
write_file "$BIN_ROOT/files" 0755 <<'FILES_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/files.py "$@"
FILES_LAUNCH

write_file "$LIB_ROOT/menu.py" 0644 <<'MENU_PY'
#!/usr/bin/env python3
import os, subprocess, sys
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

TEXT = "#e1e7df"
MUTED = "#9da89a"
ACCENT = "#82965a"
CSS = f"""
window {{ background: rgba(6, 9, 7, 0.84); color: {TEXT}; font-family: 'DejaVu Sans', sans-serif; }}
.panel {{ background: #171d18; border: 1px solid #526447; border-radius: 14px; padding: 14px; }}
button {{ background: #1e271f; color: {TEXT}; border: 1px solid #39483a; border-radius: 9px; padding: 11px 18px; font-weight: 500; }}
button:hover, button:focus {{ background: #33432e; border: 1px solid {ACCENT}; color: #f0f4e9; }}
button.active {{ background: #3a4c32; border: 1px solid #a9bb7a; color: #f0f4e9; }}
label {{ color: {TEXT}; }}
.dim {{ color: {MUTED}; font-size: 9pt; }}
"""

def apply_css():
    p = Gtk.CssProvider()
    p.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def command(args):
    try:
        return subprocess.run(args, check=False).returncode == 0
    except OSError:
        return False

class Menu(Gtk.Window):
    def __init__(self, kind):
        super().__init__(title="Power Menu" if kind == "power" else "Performance Menu")
        self.kind = kind
        self.buttons = []
        self.set_decorated(False)
        self.set_modal(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.fullscreen()
        self.connect("key-press-event", self.on_key)
        self.connect("destroy", Gtk.main_quit)

        backdrop = Gtk.EventBox()
        backdrop.set_visible_window(False)
        backdrop.connect("button-press-event", self.on_backdrop_click)
        self.add(backdrop)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.set_halign(Gtk.Align.CENTER)
        outer.set_valign(Gtk.Align.CENTER)
        backdrop.add(outer)

        panel_guard = Gtk.EventBox()
        panel_guard.set_visible_window(False)
        panel_guard.connect("button-press-event", lambda *_: True)
        outer.pack_start(panel_guard, False, False, 0)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_top(20); box.set_margin_bottom(20); box.set_margin_start(24); box.set_margin_end(24)
        box.set_size_request(430, -1)
        box.get_style_context().add_class("panel")
        panel_guard.add(box)

        title = Gtk.Label()
        title.set_markup("<span size='x-large' weight='bold'>" + ("Питание" if kind == "power" else "Режим производительности") + "</span>")
        box.pack_start(title, False, False, 4)

        if kind == "power":
            opts = [
                ("Выключение", ["systemctl", "poweroff"]),
                ("Перезагрузка", ["systemctl", "reboot"]),
                ("Сон", ["systemctl", "suspend"]),
                ("Выход из Hyprland", ["bash", "-lc", "hyprctl dispatch 'hl.dsp.exit()' || hyprctl dispatch exit"]),
            ]
            for label, cmd in opts:
                b = Gtk.Button(label=label)
                b.connect("clicked", lambda _b, c=cmd: self.act(c))
                box.pack_start(b, True, True, 0)
                self.buttons.append(b)
        else:
            current_run = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True)
            listed_run = subprocess.run(["powerprofilesctl", "list"], capture_output=True, text=True)
            current = current_run.stdout.strip() if current_run.returncode == 0 else ""
            listed = listed_run.stdout if listed_run.returncode == 0 else ""
            if listed_run.returncode != 0:
                box.pack_start(Gtk.Label(label="Служба профилей питания недоступна. Проверь power-profiles-daemon и конфликтующие службы.", wrap=True), False, False, 6)
            supported = [p for p in ("performance", "balanced", "power-saver") if p in listed]
            box.pack_start(Gtk.Label(label="Активный профиль: " + (current or "не определён")), False, False, 2)
            desc = {
                "performance": "Производительность: максимальная штатная отзывчивость; нагрев и шум могут вырасти.",
                "balanced": "Сбалансированный: повседневная работа и умеренное энергопотребление.",
                "power-saver": "Энергосбережение: пониженное энергопотребление, ниже нагрев и шум.",
            }
            labels = {"performance": "Производительность", "balanced": "Сбалансированный", "power-saver": "Энергосбережение"}
            for profile in supported:
                b = Gtk.Button(label=labels[profile] + ("  ✓" if profile == current else ""))
                if profile == current:
                    b.get_style_context().add_class("active")
                b.set_tooltip_text(desc[profile])
                b.connect("clicked", lambda _b, p=profile: self.set_profile(p))
                box.pack_start(b, True, True, 0)
                self.buttons.append(b)
                info = Gtk.Label(label=desc[profile], wrap=True, xalign=0)
                info.get_style_context().add_class("dim")
                box.pack_start(info, False, False, 0)
            missing = [p for p in ("performance", "balanced", "power-saver") if p not in supported]
            if missing:
                box.pack_start(Gtk.Label(label="Не поддерживаются этим оборудованием/драйвером: " + ", ".join(missing), wrap=True), False, False, 4)

        cancel = Gtk.Button(label="Закрыть")
        cancel.connect("clicked", lambda *_: self.destroy())
        box.pack_start(cancel, False, False, 4)
        self.buttons.append(cancel)
        if self.buttons:
            self.buttons[0].grab_focus()

    def on_backdrop_click(self, _w, _event):
        self.destroy()
        return True

    def on_key(self, _w, e):
        key = Gdk.keyval_name(e.keyval)
        if key == "Escape":
            self.destroy()
            return True
        if key in ("Up", "Down") and self.buttons:
            focused = self.get_focus()
            idx = self.buttons.index(focused) if focused in self.buttons else 0
            step = -1 if key == "Up" else 1
            self.buttons[(idx + step) % len(self.buttons)].grab_focus()
            return True
        return False

    def act(self, cmd):
        self.destroy()
        command(cmd)

    def set_profile(self, p):
        if command(["powerprofilesctl", "set", p]):
            state = os.path.expanduser("~/.local/state/hypr-minimal")
            os.makedirs(state, exist_ok=True)
            with open(os.path.join(state, "power-profile"), "w") as f:
                f.write(p + "\n")
            command(["pkill", "-RTMIN+8", "waybar"])
            self.destroy()
        else:
            d = Gtk.MessageDialog(
                transient_for=self, flags=0, message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK, text="Не удалось переключить профиль питания"
            )
            d.format_secondary_text("Профиль не поддерживается или служба power-profiles-daemon недоступна.")
            d.run(); d.destroy()

def main():
    apply_css()
    w = Menu(sys.argv[1] if len(sys.argv) > 1 else "power")
    w.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
MENU_PY
write_file "$BIN_ROOT/power-menu" 0755 <<'POWER_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py power
POWER_LAUNCH
write_file "$BIN_ROOT/performance-menu" 0755 <<'PERF_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py performance
PERF_LAUNCH

write_file "$LIB_ROOT/calendar.py" 0644 <<'CALENDAR_PY'
#!/usr/bin/env python3
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

CSS = b"""
window { background: #171d18; color: #e1e7df; border: 1px solid #526447; border-radius: 12px; font-family: 'DejaVu Sans', sans-serif; }
calendar { background: #171d18; color: #e1e7df; border: none; padding: 6px; }
calendar:selected { background: #71834b; color: #f0f4e9; border-radius: 6px; }
calendar.header { color: #a9bb7a; font-weight: bold; }
calendar.highlight { color: #a9bb7a; }
button { background: #202a21; color: #e1e7df; border: 1px solid #39483a; border-radius: 7px; padding: 4px 12px; }
button:hover { background: #354832; border-color: #82965a; }
"""

class CalendarPopup(Gtk.Window):
    def __init__(self):
        super().__init__(title="waybar-calendar")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        p = Gtk.CssProvider()
        p.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(10); box.set_margin_bottom(10); box.set_margin_start(10); box.set_margin_end(10)
        self.add(box)

        cal = Gtk.Calendar()
        box.pack_start(cal, True, True, 0)

        close_btn = Gtk.Button(label="Закрыть")
        close_btn.connect("clicked", lambda *_: self.destroy())
        box.pack_start(close_btn, False, False, 0)

        self.connect("key-press-event", self.on_key)
        self.connect("destroy", Gtk.main_quit)

    def on_key(self, _w, e):
        if Gdk.keyval_name(e.keyval) == "Escape":
            self.destroy()
            return True
        return False

def main():
    w = CalendarPopup()
    w.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
CALENDAR_PY
write_file "$BIN_ROOT/waybar-calendar" 0755 <<'CAL_LAUNCH'
#!/usr/bin/env bash
set -Eeuo pipefail
if pgrep -u "$UID" -f "/usr/local/lib/hypr-minimal/calendar.py" >/dev/null 2>&1; then
  pkill -u "$UID" -f "/usr/local/lib/hypr-minimal/calendar.py" || true
  exit 0
fi
exec /usr/bin/python /usr/local/lib/hypr-minimal/calendar.py
CAL_LAUNCH

write_file "$BIN_ROOT/waybar-performance" 0755 <<'WB_PERF'
#!/usr/bin/env bash
set -u
profile="unknown"
if command -v powerprofilesctl >/dev/null 2>&1; then
  profile="$(powerprofilesctl get 2>/dev/null || echo unknown)"
fi
case "$profile" in
  performance) label="Производительность" ;;
  balanced) label="Сбалансированный" ;;
  power-saver) label="Энергосбережение" ;;
  *) label="Недоступен"; profile="unknown" ;;
esac
printf '{"text":"󰓅","tooltip":"Режим производительности: %s (нажмите для выбора)","class":"%s"}\n' "$label" "$profile"
WB_PERF

write_file "$BIN_ROOT/hypr-layout-next" 0755 <<'LAYOUT_NEXT'
#!/usr/bin/env bash
set -u
hyprctl switchxkblayout current next >/dev/null 2>&1 || hyprctl switchxkblayout all next >/dev/null 2>&1 || true
LAYOUT_NEXT

write_file "$BIN_ROOT/audio-control" 0755 <<'AUDIO_CTRL'
#!/usr/bin/env bash
set -u
command -v wpctl >/dev/null 2>&1 || exit 0
case "${1:-}" in
  vol-up) wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ || true ;;
  vol-down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- || true ;;
  vol-mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle || true ;;
  mic-mute) wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle || true ;;
  mic-up) wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SOURCE@ 5%+ || true ;;
  mic-down) wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 5%- || true ;;
esac
AUDIO_CTRL

write_file "$BIN_ROOT/backlight-control" 0755 <<'BL_CTRL'
#!/usr/bin/env bash
set -u
command -v brightnessctl >/dev/null 2>&1 || exit 0
compgen -G "/sys/class/backlight/*" >/dev/null || exit 0
case "${1:-}" in
  up) brightnessctl set +5% >/dev/null 2>&1 || true ;;
  down) brightnessctl set 5%- >/dev/null 2>&1 || true ;;
esac
BL_CTRL

write_file "$BIN_ROOT/hypr-screenshot" 0755 <<'SHOT_CTRL'
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$HOME/Pictures"
geom="$(slurp 2>/dev/null)" || exit 0
[[ -n "$geom" ]] || exit 0
case "${1:-file}" in
  clip) grim -g "$geom" - | wl-copy ;;
  *) grim -g "$geom" "$HOME/Pictures/screenshot-$(date +%F-%H%M%S).png" ;;
esac
SHOT_CTRL

write_file "$BIN_ROOT/hypr-wallpaper-next" 0755 <<'WALL'
#!/usr/bin/env bash
set -Eeuo pipefail
dir="$HOME/Pictures/wall"
mkdir -p "$dir"
mapfile -d '' imgs < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 | sort -z)
pkill -x swaybg 2>/dev/null || true
if ((${#imgs[@]} == 0)); then
  exec swaybg -c '#111512'
fi
state="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-minimal/wall-index"
mkdir -p "$(dirname "$state")"
i=-1
if [[ -r "$state" ]]; then read -r i < "$state" || i=-1; fi
[[ "$i" =~ ^-?[0-9]+$ ]] || i=-1
if (( i < -1 || i >= ${#imgs[@]} )); then i=-1; fi
i=$(( (i + 1) % ${#imgs[@]} ))
printf '%s\n' "$i" > "$state"
exec swaybg -i "${imgs[$i]}" -m fill
WALL

write_file "$BIN_ROOT/hypr-restore-profile" 0755 <<'RESTORE'
#!/usr/bin/env bash
set -u
state="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-minimal/power-profile"
[[ -r "$state" ]] || exit 0
read -r profile < "$state"
case "$profile" in
  performance|balanced|power-saver)
    powerprofilesctl set "$profile" >/dev/null 2>&1 || true
    pkill -RTMIN+8 waybar >/dev/null 2>&1 || true
    ;;
esac
RESTORE

write_file "$BIN_ROOT/start-hyprland-intel" 0755 <<'START_INTEL'
#!/usr/bin/env bash
set -Eeuo pipefail

INTEL_CARD=""
for candidate in /dev/dri/intel-igpu /dev/dri/by-path/pci-0000:00:02.0-card /sys/class/drm/card[0-9]*; do
  [[ -e "$candidate" ]] || continue
  if [[ "$candidate" == /sys/class/drm/* ]]; then
    name="${candidate##*/}"
    [[ "$name" =~ ^card[0-9]+$ ]] || continue
    real="/dev/dri/$name"
  else
    real="$(readlink -f "$candidate")"
    name="${real##*/}"
  fi
  vendor="$(cat "/sys/class/drm/$name/device/vendor" 2>/dev/null || true)"
  if [[ "$vendor" == "0x8086" && -e "$real" && "$real" != *:* ]]; then
    INTEL_CARD="$real"
    break
  fi
done

if [[ -z "$INTEL_CARD" ]]; then
  echo "Ошибка: не найден DRM-узел Intel UHD (0x8086) без двоеточий в пути." >&2
  exit 1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

export AQ_DRM_DEVICES="$INTEL_CARD"
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME='pci-0000_00_02_0!'
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1; then
  exec dbus-run-session -- /usr/bin/start-hyprland "$@"
fi
exec /usr/bin/start-hyprland "$@"
START_INTEL

if [[ -e "$CONFIG_ROOT/hypr/hyprland.conf" || -L "$CONFIG_ROOT/hypr/hyprland.conf" ]]; then
  backup_file "$CONFIG_ROOT/hypr/hyprland.conf"
  rm -f -- "$CONFIG_ROOT/hypr/hyprland.conf"
fi

mkdir -p "$CONFIG_ROOT/hypr" "$CONFIG_ROOT/waybar" "$CONFIG_ROOT/wofi" "$CONFIG_ROOT/gtk-3.0" "$CONFIG_ROOT/gtk-4.0" "$STATE_ROOT" "$TARGET_HOME/Pictures/wall"
write_file "$CONFIG_ROOT/hypr/hyprland.lua" 0644 <<'HYPRLUA'
-- Hyprland 0.57+: конфигурация на Lua.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("GTK_THEME", "Adwaita-dark")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_STYLE_OVERRIDE", "Fusion")
hl.env("DRI_PRIME", "pci-0000_00_02_0!")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
hl.env("LIBVA_DRIVER_NAME", "iHD")
hl.env("VK_LOADER_DRIVERS_SELECT", "*intel_icd*")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

hl.config({
    general = {
        gaps_in = 4,
        gaps_out = 8,
        border_size = 1,
        col = {
            active_border = "rgba(82965aff)",
            inactive_border = "rgba(313c32cc)",
        },
        layout = "dwindle",
        allow_tearing = false,
    },
    input = {
        kb_layout = "us,ru",
        kb_options = "grp:alt_shift_toggle",
        follow_mouse = 1,
        repeat_rate = 35,
        repeat_delay = 275,
        touchpad = { natural_scroll = true },
    },
    decoration = {
        rounding = 8,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },
    animations = { enabled = false },
    dwindle = { preserve_split = true },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
    },
})

hl.window_rule({
    match = { title = "^(waybar-calendar)$" },
    float = true,
    center = true,
})

hl.window_rule({
    match = { title = "^(Files|Установка пакета Arch)$" },
    float = true,
    center = true,
})

local function bind(key, command)
    hl.bind(key, hl.dsp.exec_cmd(command))
end

hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DRI_PRIME VK_LOADER_DRIVERS_SELECT __GLX_VENDOR_LIBRARY_NAME LIBVA_DRIVER_NAME")
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
    hl.exec_cmd("/usr/local/bin/hypr-restore-profile")
    hl.exec_cmd("/usr/local/bin/hypr-wallpaper-next")
end)

bind("SUPER + RETURN", "alacritty -e bash -lc 'fastfetch; exec bash'")
bind("SUPER + D", "/usr/local/bin/hypr-launcher")
bind("SUPER + E", "files")
bind("SUPER + B", "firefox")
bind("SUPER + W", "/usr/local/bin/hypr-wallpaper-next")
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + SHIFT + ESCAPE", "/usr/local/bin/power-menu")
bind("SUPER + SHIFT + P", "/usr/local/bin/performance-menu")

bind("XF86AudioRaiseVolume", "/usr/local/bin/audio-control vol-up")
bind("XF86AudioLowerVolume", "/usr/local/bin/audio-control vol-down")
bind("XF86AudioMute", "/usr/local/bin/audio-control vol-mute")
bind("XF86AudioMicMute", "/usr/local/bin/audio-control mic-mute")
bind("XF86AudioPrev", "playerctl previous")
bind("XF86AudioPlay", "playerctl play-pause")
bind("XF86AudioNext", "playerctl next")
bind("XF86MonBrightnessUp", "/usr/local/bin/backlight-control up")
bind("XF86MonBrightnessDown", "/usr/local/bin/backlight-control down")

bind("SUPER + SHIFT + S", "/usr/local/bin/hypr-screenshot file")
bind("SUPER + CTRL + C", "/usr/local/bin/hypr-screenshot clip")

for i = 1, 9 do
    hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = tostring(i) }))
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = tostring(i) }))
end
HYPRLUA

write_file "$BIN_ROOT/hypr-launcher" 0755 <<'LAUNCHER'
#!/usr/bin/env bash
set -e
if pgrep -u "$UID" -x wofi >/dev/null 2>&1; then pkill -u "$UID" -x wofi; exit 0; fi
exec wofi --show drun --allow-images
LAUNCHER

write_file "$CONFIG_ROOT/waybar/config.jsonc" 0644 <<'WAYBAR'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "spacing": 4,
  "modules-left": ["custom/launcher", "custom/files", "custom/terminal", "hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["tray", "hyprland/language", "pulseaudio", "pulseaudio#mic", "backlight", "battery", "custom/performance", "custom/power"],
  "custom/launcher": {
    "format": "󰀻",
    "tooltip": true,
    "tooltip-format": "Меню приложений (Wofi)",
    "on-click": "/usr/local/bin/hypr-launcher"
  },
  "custom/files": {
    "format": "󰉋",
    "tooltip": true,
    "tooltip-format": "Files",
    "on-click": "/usr/local/bin/files"
  },
  "custom/terminal": {
    "format": "󰆍",
    "tooltip": true,
    "tooltip-format": "Терминал Alacritty",
    "on-click": "alacritty"
  },
  "hyprland/workspaces": {
    "format": "{name}",
    "on-click": "activate",
    "all-outputs": true,
    "disable-scroll": true,
    "persistent-workspaces": {
      "1": [], "2": [], "3": [], "4": [], "5": [], "6": [], "7": [], "8": [], "9": []
    }
  },
  "clock": {
    "format": "󰅐  {:%a %d %b  %H:%M}",
    "tooltip": true,
    "tooltip-format": "{:%A, %d %B %Y}\nНажмите, чтобы открыть календарь",
    "on-click": "/usr/local/bin/waybar-calendar"
  },
  "tray": {
    "icon-size": 14,
    "spacing": 6
  },
  "hyprland/language": {
    "format": "󰌌  {short}",
    "tooltip": true,
    "on-click": "/usr/local/bin/hypr-layout-next"
  },
  "pulseaudio": {
    "format": "{icon} {volume}%",
    "format-muted": "󰖁 muted",
    "format-icons": {
      "default": ["󰕿", "󰖀", "󰕾"]
    },
    "tooltip": true,
    "tooltip-format": "Динамики: {volume}%\nЛКМ: выкл./вкл. звук · Колесо: громкость",
    "on-click": "/usr/local/bin/audio-control vol-mute",
    "on-scroll-up": "/usr/local/bin/audio-control vol-up",
    "on-scroll-down": "/usr/local/bin/audio-control vol-down"
  },
  "pulseaudio#mic": {
    "format": "{format_source}",
    "format-source": "󰍬 {volume}%",
    "format-source-muted": "󰍭 muted",
    "tooltip": true,
    "tooltip-format": "Микрофон: {source_volume}%\nЛКМ: выкл./вкл. микрофон · Колесо: чувствительность",
    "on-click": "/usr/local/bin/audio-control mic-mute",
    "on-scroll-up": "/usr/local/bin/audio-control mic-up",
    "on-scroll-down": "/usr/local/bin/audio-control mic-down"
  },
  "backlight": {
    "format": "󰃟 {percent}%",
    "tooltip": true,
    "tooltip-format": "Яркость: {percent}%",
    "on-scroll-up": "/usr/local/bin/backlight-control up",
    "on-scroll-down": "/usr/local/bin/backlight-control down"
  },
  "battery": {
    "format": "{icon} {capacity}%",
    "format-charging": "󰂄 {capacity}%",
    "format-plugged": "󰂄 {capacity}%",
    "format-icons": ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"],
    "states": {
      "warning": 25,
      "critical": 10
    },
    "tooltip": true,
    "tooltip-format": "Батарея: {capacity}% ({timeTo})"
  },
  "custom/performance": {
    "exec": "/usr/local/bin/waybar-performance",
    "return-type": "json",
    "interval": 30,
    "signal": 8,
    "tooltip": true,
    "on-click": "/usr/local/bin/performance-menu"
  },
  "custom/power": {
    "format": "󰐥",
    "tooltip": true,
    "tooltip-format": "Меню питания",
    "on-click": "/usr/local/bin/power-menu"
  }
}
WAYBAR

write_file "$CONFIG_ROOT/waybar/style.css" 0644 <<'WAYCSS'
* {
  font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", "DejaVu Sans", sans-serif;
  font-size: 11px;
  border: none;
  min-height: 0;
}
window#waybar {
  background: rgba(17, 21, 18, 0.96);
  color: #e1e7df;
  border-bottom: 1px solid #354133;
}
#clock {
  color: #e1e7df;
  font-weight: 600;
  padding: 0 10px;
}
#clock:hover {
  background: #283327;
  border-radius: 5px;
}
#workspaces button {
  color: #8f9a8d;
  background: transparent;
  padding: 0 7px;
  margin: 3px 1px;
  border-radius: 5px;
}
#workspaces button.empty {
  color: #5b655a;
}
#workspaces button.active {
  color: #f0f4e9;
  background: #46583b;
}
#workspaces button:hover,
#custom-launcher:hover,
#custom-files:hover,
#custom-terminal:hover,
#language:hover,
#pulseaudio:hover,
#backlight:hover,
#custom-performance:hover,
#custom-power:hover {
  background: #2f3d2c;
  color: #f0f4e9;
  border-radius: 5px;
}
#custom-launcher,
#custom-files,
#custom-terminal,
#custom-performance,
#custom-power,
#pulseaudio,
#backlight,
#battery,
#language,
#tray {
  padding: 0 7px;
}
#custom-launcher,
#custom-files,
#custom-terminal,
#custom-performance,
#custom-power {
  font-size: 13px;
}
#custom-launcher,
#custom-performance {
  color: #a9bb7a;
}
#custom-files,
#custom-terminal {
  color: #c7d2c1;
}
#pulseaudio.muted,
#pulseaudio.source-muted {
  color: #8b9488;
}
#custom-power {
  color: #cfa987;
  padding-right: 12px;
}
#battery.charging {
  color: #a9bb7a;
}
#battery.warning {
  color: #d8b76c;
}
#battery.critical {
  color: #d98b7d;
}
tooltip {
  background: #171e18;
  border: 1px solid #526447;
  color: #e1e7df;
}
WAYCSS

write_file "$CONFIG_ROOT/wofi/config" 0644 <<'WOFI'
width=540
height=360
location=center
show=drun
prompt=Поиск приложений
allow_images=true
image_size=24
insensitive=true
hide_scroll=true
WOFI
write_file "$CONFIG_ROOT/wofi/style.css" 0644 <<'WOFICSS'
window { background: #111512; color: #e1e7df; border: 1px solid #526447; border-radius: 10px; font-family: "DejaVu Sans", sans-serif; }
#input { background: #1a211b; color: #e1e7df; border: 1px solid #526447; border-radius: 7px; margin: 8px; padding: 8px; }
#entry { padding: 7px; }
#entry:selected { background: #405238; color: #f0f4e9; border-radius: 6px; }
#text { color: #e1e7df; }
WOFICSS

write_file "$CONFIG_ROOT/alacritty/alacritty.toml" 0644 <<'ALACRITTY'
[window]
opacity = 1.0
padding = { x = 10, y = 8 }
decorations = "Full"

[font]
size = 10.5
normal = { family = "JetBrainsMono Nerd Font" }

[colors.primary]
background = "#111512"
foreground = "#e1e7df"

[colors.normal]
black = "#171e18"
red = "#bd766b"
green = "#879b60"
yellow = "#b7a36a"
blue = "#778b72"
magenta = "#9a829a"
cyan = "#78978f"
white = "#d2d9ce"

[colors.bright]
black = "#687267"
red = "#d28b7f"
green = "#a9bb7a"
yellow = "#d1bd82"
blue = "#9aab91"
magenta = "#b29ab2"
cyan = "#9ab9ae"
white = "#f0f4e9"
ALACRITTY

write_file "$CONFIG_ROOT/gtk-3.0/settings.ini" 0644 <<'GTK'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK
write_file "$CONFIG_ROOT/gtk-4.0/settings.ini" 0644 <<'GTK4'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK4

mkdir -p "$CONFIG_ROOT/qt6ct/colors"
write_file "$CONFIG_ROOT/qt6ct/colors/olive.conf" 0644 <<'QTCOLORS'
[ColorScheme]
active_colors=#ffe1e7df, #ff202a21, #ff35452f, #ff526447, #ff0b0f0c, #ff2a332a, #ffe1e7df, #ffffffff, #ffe1e7df, #ff111512, #ff111512, #ff000000, #ff46583b, #fff0f4e9, #ffa9bb7a, #ff879b60, #ff171e18, #ffe1e7df, #ff171e18, #ffe1e7df, #ff8b9689, #ff71834b
inactive_colors=#ffe1e7df, #ff202a21, #ff35452f, #ff526447, #ff0b0f0c, #ff2a332a, #ffe1e7df, #ffffffff, #ffe1e7df, #ff111512, #ff111512, #ff000000, #ff405238, #fff0f4e9, #ffa9bb7a, #ff879b60, #ff171e18, #ffe1e7df, #ff171e18, #ffe1e7df, #ff8b9689, #ff71834b
disabled_colors=#ff7c887a, #ff1a211b, #ff293329, #ff3b4938, #ff0b0f0c, #ff202820, #ff7c887a, #ffb8c0b5, #ff7c887a, #ff111512, #ff111512, #ff000000, #ff35452f, #ffb8c0b5, #ff75865a, #ff687b58, #ff171e18, #ff7c887a, #ff171e18, #ff7c887a, #ff657064, #ff526447
QTCOLORS
write_file "$CONFIG_ROOT/qt6ct/qt6ct.conf" 0644 <<QTCONF
[Appearance]
color_scheme_path=$CONFIG_ROOT/qt6ct/colors/olive.conf
custom_palette=true
icon_theme=Adwaita
style=Fusion
standard_dialogs=default
QTCONF
write_file "$CONFIG_ROOT/mako/config" 0644 <<'MAKO'
font=DejaVu Sans 10
background-color=#171e18
text-color=#e1e7df
border-color=#71834b
border-size=1
border-radius=8
padding=10
margin=8
default-timeout=5000
ignore-timeout=0
MAKO
write_file "$CONFIG_ROOT/cava/config" 0644 <<'CAVA'
[general]
framerate = 30
bars = 0

[output]
method = ncurses

[colors]
foreground = '#a9bb7a'
gradient = 1
gradient_color_1 = '#526447'
gradient_color_2 = '#71834b'
gradient_color_3 = '#879b60'
gradient_color_4 = '#a9bb7a'
CAVA

write_file "$TARGET_HOME/.local/share/applications/files.desktop" 0644 <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Files
Exec=/usr/local/bin/files %U
Icon=system-file-manager
Terminal=false
NoDisplay=true
Categories=System;FileManager;
MimeType=inode/directory;
StartupWMClass=files
DESKTOP
write_file "$TARGET_HOME/.local/share/applications/arch-package-install.desktop" 0644 <<'PKGDESK'
[Desktop Entry]
Type=Application
Name=Установщик пакетов Arch
Exec=alacritty --title "Установка пакета Arch" -e /usr/local/bin/arch-package-install %f
Icon=package-x-generic
Terminal=false
NoDisplay=true
MimeType=application/x-compressed-tar;application/zstd;application/x-zstd;application/x-zstd-compressed-tar;application/x-xz-compressed-tar;
PKGDESK
write_file "$TARGET_HOME/.config/mimeapps.list" 0644 <<'MIME'
[Default Applications]
inode/directory=files.desktop
application/x-zstd-compressed-tar=arch-package-install.desktop
application/zstd=arch-package-install.desktop
application/x-zstd=arch-package-install.desktop
application/x-compressed-tar=arch-package-install.desktop
application/x-xz-compressed-tar=arch-package-install.desktop
MIME

write_file "$LIB_ROOT/github-asset.py" 0644 <<'GH'
#!/usr/bin/env python3
import json, re, sys, urllib.request
repo, pattern = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    "https://api.github.com/repos/" + repo + "/releases?per_page=30",
    headers={"User-Agent": "hypr-minimal-installer"}
)
try:
    data = json.load(urllib.request.urlopen(req, timeout=25))
    for rel in data:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        assets = rel.get("assets", [])
        sha_url = ""
        for a in assets:
            if a.get("name", "") in ("SHA256SUMS", "SHA256SUMS.txt", "sha256sums.txt"):
                sha_url = a.get("browser_download_url", "")
                break
        for a in assets:
            name = a.get("name", "")
            if re.search(pattern, name, re.I):
                digest = a.get("digest") or ""
                if not digest and sha_url:
                    try:
                        req_sha = urllib.request.Request(sha_url, headers={"User-Agent": "hypr-minimal-installer"})
                        txt = urllib.request.urlopen(req_sha, timeout=15).read().decode("utf-8", errors="replace")
                        for line in txt.splitlines():
                            parts = line.strip().split()
                            if len(parts) >= 2 and parts[-1].lstrip("*") == name and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
                                digest = "sha256:" + parts[0].lower()
                                break
                    except Exception:
                        pass
                print(a["browser_download_url"])
                print(digest)
                raise SystemExit(0)
except Exception as e:
    print("GitHub API: " + str(e), file=sys.stderr)
raise SystemExit(1)
GH

fetch_file() {
  local url="$1" dest="$2" digest="${3:-}" expected="${4:-}" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${dest}.download.XXXXXX")"
  if ! curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 --output "$tmp" "$url"; then
    rm -f "$tmp"; return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  if [[ "$digest" == sha256:* ]]; then
    echo "${digest#sha256:}  $tmp" | sha256sum --check --status || { rm -f "$tmp"; warn "SHA-256 не совпал: $url"; return 1; }
  else
    warn "Источник не предоставил SHA-256 для $(basename "$dest"); загрузка выполнена по HTTPS без отдельной контрольной суммы."
  fi
  if [[ "$expected" == elf ]]; then
    local magic
    magic="$(od -An -N4 -tx1 "$tmp" | tr -d ' \n')"
    [[ "$magic" == 7f454c46 ]] || { rm -f "$tmp"; warn "Загруженный файл не является ELF/AppImage: $url"; return 1; }
  fi
  if ! mv -f -- "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
}
gh_asset() {
  local data url digest
  data="$(python "$LIB_ROOT/github-asset.py" "$1" "$2" 2>/dev/null)" || return 1
  url="$(printf '%s\n' "$data" | sed -n '1p')"
  digest="$(printf '%s\n' "$data" | sed -n '2p')"
  [[ -n "$url" ]] || return 1
  printf '%s\n%s\n' "$url" "$digest"
}
install_appimage() {
  local repo="$1" pattern="$2" name="$3" title="$4" category="$5" url digest dir
  local -a asset
  if ! mapfile -t asset < <(gh_asset "$repo" "$pattern"); then warn "$title: не удалось получить release asset."; return 1; fi
  url="${asset[0]:-}"; digest="${asset[1]:-}"
  [[ -n "$url" ]] || { warn "$title: подходящий asset не найден."; return 1; }
  dir="$APP_ROOT/$name"; install -d -m 0755 "$dir"
  if ! fetch_file "$url" "$dir/$name.AppImage" "$digest" elf; then warn "$title: загрузка/проверка не удалась."; return 1; fi
  chmod 0755 "$dir/$name.AppImage"
  cat > "$BIN_ROOT/$name" <<EOF
#!/usr/bin/env bash
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME='pci-0000_00_02_0!'
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
exec "$dir/$name.AppImage" --appimage-extract-and-run "\$@"
EOF
  chmod 0755 "$BIN_ROOT/$name"
  cat > "/usr/share/applications/$name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$title
Exec=$BIN_ROOT/$name %U
Icon=application-x-executable
Terminal=false
Categories=$category
EOF
  log "$title установлен."
}
install_arch_release() {
  local repo="$1" pattern="$2" pkgname="$3" url digest tmp
  local -a asset
  if ! mapfile -t asset < <(gh_asset "$repo" "$pattern"); then warn "$pkgname: не найден официальный пакет релиза."; return 1; fi
  url="${asset[0]:-}"; digest="${asset[1]:-}"
  [[ -n "$url" ]] || { warn "$pkgname: пакет не найден."; return 1; }
  tmp="$(mktemp --suffix=.pkg.tar.zst)"
  if ! fetch_file "$url" "$tmp" "$digest"; then rm -f "$tmp"; return 1; fi
  pacman -U --needed --noconfirm -- "$tmp" || { warn "$pkgname: pacman не установил пакет (подписи pacman не отключались)."; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

log "Дополнительные приложения (устанавливаются независимо с официальных релизов)"
install_arch_release "Happ-proxy/happ-desktop" '^Happ\.linux\.x64\.pkg\.tar\.zst$' happ || install_appimage "Happ-proxy/happ-desktop" 'Happ.*(x64|x86_64).*\.AppImage$' happ "Happ" "Network;" || true
install_appimage "storytold/photocraft" 'x86_64.*\.AppImage$' photocraft "PhotoCraft" "Graphics;" || true

ONLYOFFICE_URL="https://download.onlyoffice.com/install/desktop/editors/linux/DesktopEditors-x86_64.AppImage"
install -d -m 0755 "$APP_ROOT/onlyoffice"
if fetch_file "$ONLYOFFICE_URL" "$APP_ROOT/onlyoffice/onlyoffice.AppImage" "" elf; then
  chmod 0755 "$APP_ROOT/onlyoffice/onlyoffice.AppImage"
  cat > "$BIN_ROOT/onlyoffice" <<EOF
#!/usr/bin/env bash
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME='pci-0000_00_02_0!' __GLX_VENDOR_LIBRARY_NAME=mesa LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
exec "$APP_ROOT/onlyoffice/onlyoffice.AppImage" --appimage-extract-and-run "\$@"
EOF
  chmod 0755 "$BIN_ROOT/onlyoffice"
  cat > /usr/share/applications/onlyoffice.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=ONLYOFFICE
Exec=/usr/local/bin/onlyoffice %U
Icon=application-x-executable
Terminal=false
Categories=Office;
EOF
else
  warn "ONLYOFFICE: загрузка с официального сайта не удалась."
fi
install_appimage "SimoHypers/limusic" '(x86_64|amd64).*\.AppImage$' limusic "Limusic" "AudioVideo;Audio;Player;" || true
install_appimage "anomalyco/opencode" 'opencode-desktop-linux-(x86_64|amd64|x64).*\.AppImage$' opencode "OpenCode" "Development;" || true

WOFI_HIDE_DIR="$TARGET_HOME/.local/share/applications"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$WOFI_HIDE_DIR"
python - "$WOFI_HIDE_DIR" "$BACKUP_ROOT" <<'WOFI_CURATE'
import os, shutil, sys
from pathlib import Path

user_apps, backup_root = Path(sys.argv[1]), Path(sys.argv[2])
hide_ids = {
    "files.desktop", "arch-package-install.desktop", "power-menu.desktop", "performance-menu.desktop",
    "bssh.desktop", "bvnc.desktop", "avahi-discover.desktop", "qv4l2.desktop", "qvidcap.desktop",
    "lstopo.desktop", "qt6ct.desktop", "xterm.desktop", "uxterm.desktop", "cmake-gui.desktop",
    "linguist.desktop", "designer.desktop", "assistant.desktop", "qdbusviewer.desktop",
}
old_override = "[Desktop Entry]\nType=Application\nName=Служебная запись\nNoDisplay=true\n"

all_entries = {}
for directory in (Path("/usr/share/applications"), Path("/usr/local/share/applications"), user_apps):
    if directory.is_dir():
        for src in directory.glob("*.desktop"):
            all_entries.setdefault(src.name, src)

for desktop_id, _src in all_entries.items():
    dst = user_apps / desktop_id
    if dst.is_file() and not dst.is_symlink():
        try:
            if dst.read_text(errors="replace") == old_override and desktop_id not in hide_ids:
                dst.unlink()
        except OSError:
            pass
    if desktop_id not in hide_ids:
        continue
    if desktop_id in ("files.desktop", "arch-package-install.desktop"):
        continue
    if dst.is_symlink():
        backup = backup_root / str(dst).lstrip("/")
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_text("SYMLINK -> " + os.readlink(dst) + "\n")
        dst.unlink()
    elif dst.exists() and dst.read_text(errors="replace") != old_override:
        backup = backup_root / str(dst).lstrip("/")
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dst, backup)
    dst.write_text(old_override)
    os.chmod(dst, 0o644)
WOFI_CURATE
chown -R "$TARGET_USER:$TARGET_GROUP" "$WOFI_HIDE_DIR"

write_file "$CONFIG_ROOT/environment.d/90-intel-gpu.conf" 0644 <<'ENV'
DRI_PRIME=pci-0000_00_02_0!
__GLX_VENDOR_LIBRARY_NAME=mesa
LIBVA_DRIVER_NAME=iHD
VK_LOADER_DRIVERS_SELECT=*intel_icd*
QT_QPA_PLATFORMTHEME=qt6ct
QT_STYLE_OVERRIDE=Fusion
ENV

USER_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
case "${USER_SHELL##*/}" in
  bash) PROFILE="$TARGET_HOME/.bash_profile"; PROFILE_KIND=bash ;;
  zsh) PROFILE="$TARGET_HOME/.zprofile"; PROFILE_KIND=zsh ;;
  *) PROFILE=""; PROFILE_KIND=unsupported; warn "Автозапуск TTY1 не добавлен: оболочка $USER_SHELL не поддержана. Запускай start-hyprland-intel вручную." ;;
esac
if [[ -n "$PROFILE" ]]; then
  if [[ ! -e "$PROFILE" ]]; then
    if [[ "$PROFILE_KIND" == bash ]]; then
      write_file "$PROFILE" 0644 <<'BPROFILE'
[[ -f ~/.bashrc ]] && . ~/.bashrc
BPROFILE
    else
      write_file "$PROFILE" 0644 <<'ZPROFILE'
[[ -f ~/.zshrc ]] && . ~/.zshrc
ZPROFILE
    fi
  fi
  backup_file "$PROFILE"
  python - "$PROFILE" <<'CLEAN_PROFILE'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
txt = p.read_text(errors="replace") if p.exists() else ""
txt = re.sub(r"\n?# HYPR_MINIMAL_TTY1_START[\s\S]*?# HYPR_MINIMAL_TTY1_END\n?", "\n", txt)
txt = re.sub(r"\n?# HYPR_MINIMAL_TTY1:[^\n]*\nif \[\[[^\n]*XDG_VTNR[^\n]*\]\]; then[\s\S]*?\nfi\n?", "\n", txt)
txt = txt.rstrip() + "\n"
p.write_text(txt)
CLEAN_PROFILE
  cat >> "$PROFILE" <<'LOGIN_PROFILE'

# HYPR_MINIMAL_TTY1_START
if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" && "${XDG_VTNR:-0}" == "1" && -t 0 ]]; then
    mkdir -p "$HOME/.local/state/hypr-minimal"
    if /usr/local/bin/start-hyprland-intel 2>"$HOME/.local/state/hypr-minimal/launch.log"; then
        exit 0
    else
        rc=$?
        echo "Hyprland завершился с ошибкой (код $rc). Последние строки лога:"
        tail -n 20 "$HOME/.local/state/hypr-minimal/launch.log"
    fi
fi
# HYPR_MINIMAL_TTY1_END
LOGIN_PROFILE
fi

CONFLICTS=()
for svc in tlp.service auto-cpufreq.service tuned.service laptop-mode.service; do
  if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then CONFLICTS+=("$svc"); fi
done
POWER_PROFILE_DAEMON_READY=1
if ((${#CONFLICTS[@]})); then
  printf 'Обнаружены потенциально конфликтующие службы: %s\n' "${CONFLICTS[*]}"
  read -r -p "Отключить их (пакеты и настройки останутся) и использовать power-profiles-daemon? [y/N] " answer
  if [[ "$answer" =~ ^[YyДд]$ ]]; then
    for svc in "${CONFLICTS[@]}"; do systemctl disable --now "$svc" || warn "Не удалось отключить $svc"; done
  else
    POWER_PROFILE_DAEMON_READY=0
    warn "Конфликтующие службы оставлены без изменений; меню профилей питания будет недоступно до ручного выбора одного менеджера."
  fi
fi
if ((POWER_PROFILE_DAEMON_READY)); then systemctl enable --now power-profiles-daemon.service; fi

USER_SYSTEMD="$TARGET_HOME/.config/systemd/user"
install -d "$USER_SYSTEMD/sockets.target.wants" "$USER_SYSTEMD/default.target.wants"
for unit in pipewire.socket pipewire-pulse.socket; do
  src="/usr/lib/systemd/user/$unit"; dst="$USER_SYSTEMD/sockets.target.wants/$unit"
  if [[ -e "$src" && ! -e "$dst" && ! -L "$dst" ]]; then ln -s "$src" "$dst"; fi
done
if [[ -e /usr/lib/systemd/user/wireplumber.service && ! -e "$USER_SYSTEMD/default.target.wants/wireplumber.service" && ! -L "$USER_SYSTEMD/default.target.wants/wireplumber.service" ]]; then
  ln -s /usr/lib/systemd/user/wireplumber.service "$USER_SYSTEMD/default.target.wants/wireplumber.service"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$USER_SYSTEMD"
runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" systemctl --user daemon-reload 2>/dev/null || true

runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-user-dirs-update >/dev/null 2>&1 || true
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default files.desktop inode/directory >/dev/null 2>&1 || true
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default arch-package-install.desktop application/zstd >/dev/null 2>&1 || true
update-desktop-database "$TARGET_HOME/.local/share/applications" >/dev/null 2>&1 || true
[[ -n "$PROFILE" ]] && chown "$TARGET_USER:$TARGET_GROUP" "$PROFILE" 2>/dev/null || true
chown -R "$TARGET_USER:$TARGET_GROUP" "$CONFIG_ROOT" "$TARGET_HOME/.local" "$TARGET_HOME/Pictures" 2>/dev/null || true
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.local/state/hypr-minimal" "$TARGET_HOME/Pictures/wall"

log "Проверка созданных файлов и шрифтов"
for f in \
  "$BIN_ROOT/arch-package-install" "$BIN_ROOT/files" "$BIN_ROOT/power-menu" "$BIN_ROOT/performance-menu" \
  "$BIN_ROOT/waybar-calendar" "$BIN_ROOT/waybar-performance" "$BIN_ROOT/hypr-layout-next" \
  "$BIN_ROOT/audio-control" "$BIN_ROOT/backlight-control" "$BIN_ROOT/hypr-screenshot" \
  "$BIN_ROOT/hypr-wallpaper-next" "$BIN_ROOT/hypr-restore-profile" "$BIN_ROOT/hypr-launcher" \
  "$BIN_ROOT/start-hyprland-intel"; do
  bash -n "$f"
done
python -m py_compile "$LIB_ROOT/files.py" "$LIB_ROOT/menu.py" "$LIB_ROOT/calendar.py" "$LIB_ROOT/github-asset.py"
python -m json.tool "$CONFIG_ROOT/waybar/config.jsonc" >/dev/null
if command -v luac >/dev/null 2>&1; then
  luac -p "$CONFIG_ROOT/hypr/hyprland.lua"
else
  warn "luac не найден; Lua-конфигурация не прошла локальную синтаксическую проверку."
fi
fc-match "JetBrainsMono Nerd Font" >/dev/null 2>&1 || warn "Шрифт JetBrainsMono Nerd Font не найден в fontconfig."
fc-match "Symbols Nerd Font" >/dev/null 2>&1 || warn "Шрифт Symbols Nerd Font не найден в fontconfig."

log "Аудит NVIDIA (без удаления драйверов и без опасного отключения PCIe)"
if pacman -Qq 2>/dev/null | grep -Ei '^(nvidia|nvidia-open|nvidia-utils|lib32-nvidia|opencl-nvidia|cuda|bumblebee|optimus-manager)'; then
  warn "Обнаружены NVIDIA/CUDA/Optimus-пакеты. Они не удаляются; выбор GPU для сеанса ограничен Intel."
else
  log "Пакеты NVIDIA/CUDA/Optimus в pacman не обнаружены."
fi
for svc in nvidia-persistenced.service nvidia-powerd.service; do
  if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    systemctl disable --now "$svc" || warn "Не удалось остановить $svc; проверь вручную."
  fi
done
if lsmod | grep -qE '^(nvidia|nouveau)'; then
  warn "Модуль NVIDIA/nouveau уже загружен. Скрипт не выгружает его вслепую; проверь lsmod и перезагрузи после настройки."
fi
if command -v lspci >/dev/null 2>&1; then
  lspci -nnk | grep -A3 -Ei 'VGA compatible controller|3D controller|Display controller' || true
fi
log "Intel UHD подтверждена по PCI vendor ID 0x8086: $INTEL_CARD_REAL (AQ_DRM_DEVICES без двоеточий)"

cat <<EOF

Установка завершена для пользователя $TARGET_USER.

Дальше:
  1. Перезагрузи ноутбук или выйди и войди в TTY1.
  2. При желании добавь обои в ~/Pictures/wall (иначе используется фон #111512).
  3. Проверь GPU: lspci -k, glxinfo -B (пакет mesa-utils), vulkaninfo --summary (пакет vulkan-tools).
  4. Проверь профили: powerprofilesctl get и powerprofilesctl list.

Резервные копии: $BACKUP_ROOT
EOF