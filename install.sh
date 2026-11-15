#!/usr/bin/env bash
# Переработанный установочный скрипт Arch Linux + Hyprland для ноутбука на Intel UHD Graphics.
# Аппаратный профиль: Intel Core i5-10300H + Intel UHD Graphics (NVIDIA GTX 1650 не используется).
# Запуск: sudo bash install.sh [имя_пользователя]
set -Eeuo pipefail
IFS=$'\n\t'

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly RESET='\033[0m'

log()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!!${RESET} %s\n" "$*" >&2; }
die()  { printf "${RED}ОШИБКА:${RESET} %s\n" "$*" >&2; exit 1; }
trap 'rc=$?; printf "\n${RED}Сбой на строке %s (код %s).${RESET}\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

# --- 1. Проверки окружения и прав ---
[[ $EUID -eq 0 ]] || die "Запусти установщик от root: sudo bash install.sh [имя_пользователя]"
[[ -f /etc/arch-release ]] || die "Этот скрипт предназначен только для Arch Linux."
[[ "$(uname -m)" == "x86_64" ]] || die "Поддерживается только архитектура x86_64."
command -v pacman >/dev/null 2>&1 || die "Не найден pacman."
command -v runuser >/dev/null 2>&1 || die "Не найден runuser."

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  TARGET_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\/home\// {print $1; exit}')"
fi
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] || die "Не удалось определить обычного пользователя. Укажи его явно: sudo bash install.sh ИМЯ"
id "$TARGET_USER" >/dev/null 2>&1 || die "Пользователь '$TARGET_USER' не существует в системе."
TARGET_UID="$(id -u "$TARGET_USER")"
[[ "$TARGET_UID" -ge 1000 && "$TARGET_UID" -lt 60000 ]] || die "Пользователь '$TARGET_USER' имеет UID=$TARGET_UID (нужен обычный пользователь 1000..59999)."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
[[ -d "$TARGET_HOME" && "$TARGET_HOME" != "/" ]] || die "Домашняя директория '$TARGET_HOME' не найдена."

readonly APP_ROOT="/opt/hypr-minimal"
readonly LIB_ROOT="/usr/local/lib/hypr-minimal"
readonly BIN_ROOT="/usr/local/bin"
readonly ICON_ROOT="/usr/local/share/icons/hypr-minimal"
readonly CONFIG_ROOT="$TARGET_HOME/.config"
readonly STATE_ROOT="$TARGET_HOME/.local/state/hypr-minimal"
readonly BACKUP_ROOT="$TARGET_HOME/.local/share/hypr-minimal-backups/$(date +%Y%m%d-%H%M%S)"

# --- 2. Вспомогательные функции ---
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
  if [[ ! -L "$dest" && -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    backup_file "$dest"
    [[ ! -L "$dest" ]] || rm -f -- "$dest"
  fi
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

log "Целевой пользователь: $TARGET_USER ($TARGET_HOME)"
log "Резервные копии будут сохраняться в: $BACKUP_ROOT"

# --- 3. Включение multilib (нужно для Steam и lib32-vulkan-intel) ---
if ! grep -qE '^[[:space:]]*\[multilib\]' /etc/pacman.conf; then
  backup_file /etc/pacman.conf
  if grep -qE '^[[:space:]]*#\[multilib\]' /etc/pacman.conf; then
    sed -i '/^[[:space:]]*#\[multilib\]/,/^[[:space:]]*#Include/s/^[[:space:]]*#//' /etc/pacman.conf
    log "Репозиторий [multilib] включён в /etc/pacman.conf"
  else
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
    log "Репозиторий [multilib] добавлен в /etc/pacman.conf"
  fi
fi

# --- 4. Обновление системы и установка пакетов ---
log "Обновление базы пакетов и системы Arch Linux"
pacman -Syu --needed --noconfirm

# Сначала устанавливаем стек Intel (64-bit и 32-bit), чтобы pacman при установке Steam
# не предлагал и не подтягивал NVIDIA Vulkan-провайдеры.
INTEL_GRAPHICS_PACKAGES=(
  mesa
  vulkan-intel
  lib32-mesa
  lib32-vulkan-intel
  intel-media-driver
)
log "Установка графических компонентов только для Intel UHD"
pacman -S --needed --noconfirm "${INTEL_GRAPHICS_PACKAGES[@]}"

CORE_PACKAGES=(
  # Wayland, композитор и рабочий стол
  hyprland
  xdg-desktop-portal-hyprland
  xdg-desktop-portal-gtk
  xorg-xwayland
  waybar
  wofi
  alacritty
  qt6-wayland
  swaybg
  mako
  polkit-gnome
  # Звук и мультимедиа
  pipewire
  pipewire-pulse
  wireplumber
  playerctl
  # Скриншоты, буфер обмена, яркость, уведомления
  grim
  slurp
  wl-clipboard
  brightnessctl
  libnotify
  # Зависимости Files, меню, Qt/GTK-темизации и системных утилит
  gtk3
  python
  python-gobject
  udisks2
  gvfs
  xdg-utils
  xdg-user-dirs
  desktop-file-utils
  shared-mime-info
  dbus
  sudo
  curl
  lua
  qt6ct
  adwaita-icon-theme
  # Шрифты (единый набор иконок Nerd Font + fallback + кириллица + emoji)
  ttf-jetbrains-mono-nerd
  ttf-nerd-fonts-symbols
  ttf-dejavu
  noto-fonts-emoji
  # Управление профилями производительности (единственный менеджер питания)
  power-profiles-daemon
  # Приложения из официальных репозиториев Arch
  firefox
  telegram-desktop
  prismlauncher
  jre21-openjdk
  fastfetch
  cava
)

log "Установка базовых системных пакетов и репозиторных приложений"
pacman -S --needed --noconfirm "${CORE_PACKAGES[@]}"

log "Обновление кэша шрифтов (fontconfig)"
fc-cache -fv >/dev/null 2>&1 || true

log "Установка Steam (после закрепления Intel 32/64-bit Vulkan)"
pacman -S --needed --noconfirm steam

# Право sudo для группы wheel (нужно для установки локальных .pkg.tar.* через Files)
usermod -aG wheel "$TARGET_USER"
SUDOERS_FILE="/etc/sudoers.d/10-hypr-minimal-wheel"
if [[ ! -e "$SUDOERS_FILE" ]]; then
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  if ! visudo -cf "$SUDOERS_FILE" >/dev/null; then
    rm -f "$SUDOERS_FILE"
    die "Ошибка проверки sudoers; файл $SUDOERS_FILE удалён."
  fi
fi

# --- 5. Обнаружение Intel UHD Graphics (строго без использования NVIDIA) ---
detect_intel_drm() {
  local preferred="/dev/dri/by-path/pci-0000:00:02.0-card"
  if [[ -e "$preferred" ]]; then
    local real name vendor
    real="$(readlink -f "$preferred")"
    name="${real##*/}"
    vendor="$(cat "/sys/class/drm/$name/device/vendor" 2>/dev/null || true)"
    if [[ "$vendor" == "0x8086" ]]; then
      printf '%s\n' "$preferred"
      return 0
    fi
  fi
  local link real name vendor
  for link in /dev/dri/by-path/pci-*-card; do
    [[ -e "$link" ]] || continue
    real="$(readlink -f "$link")"
    name="${real##*/}"
    vendor="$(cat "/sys/class/drm/$name/device/vendor" 2>/dev/null || true)"
    if [[ "$vendor" == "0x8086" ]]; then
      printf '%s\n' "$link"
      return 0
    fi
  done
  return 1
}

INTEL_DRM_CARD="$(detect_intel_drm)" || die "Не найден DRM-узел Intel UHD (vendor 0x8086). Проверь модуль i915 и /dev/dri/by-path."
INTEL_CARD_REAL="$(readlink -f "$INTEL_DRM_CARD")"
INTEL_CARD_NAME="${INTEL_CARD_REAL##*/}"
INTEL_PCI_SLOT="$(basename "$(readlink -f "/sys/class/drm/$INTEL_CARD_NAME/device")")"
INTEL_DRI_PRIME="pci-${INTEL_PCI_SLOT//[:.]/_}!"
INTEL_ICD="/usr/share/vulkan/icd.d/intel_icd.json"
[[ -r "$INTEL_ICD" ]] || die "Не найден Intel Vulkan ICD ($INTEL_ICD)."
log "Intel UHD подтверждена: $INTEL_DRM_CARD -> $INTEL_CARD_REAL ($INTEL_DRI_PRIME)"

# Проверка шрифтов Waybar
if ! fc-list : family | grep -qi "JetBrainsMono Nerd Font"; then
  warn "Шрифт 'JetBrainsMono Nerd Font' не найден через fc-list; проверь пакет ttf-jetbrains-mono-nerd."
fi
if ! fc-list : family | grep -qi "Symbols Nerd Font"; then
  warn "Шрифт 'Symbols Nerd Font' не найден через fc-list; проверь пакет ttf-nerd-fonts-symbols."
fi

# --- 6. Установка локальных пакетов Arch (.pkg.tar.zst / .pkg.tar.xz) ---
install -d -m 0755 "$LIB_ROOT" "$APP_ROOT" "$ICON_ROOT"

write_file "$BIN_ROOT/arch-package-install" 0755 <<'PKG_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

f="${1:-}"
[[ -n "$f" ]] || { echo "Ошибка: не передан путь к файлу пакета."; read -r -p "Нажми Enter для закрытия... "; exit 2; }
f="$(realpath -- "$f")"
[[ -f "$f" && -r "$f" ]] || { echo "Ошибка: файл не найден или недоступен для чтения: $f"; read -r -p "Нажми Enter для закрытия... "; exit 2; }

case "$f" in
  *.pkg.tar.zst|*.pkg.tar.xz)
    ;;
  *)
    echo "Неподдерживаемый формат файла. Разрешены только локальные пакеты .pkg.tar.zst и .pkg.tar.xz."
    read -r -p "Нажми Enter для закрытия... "
    exit 2
    ;;
esac

echo "=== Установка локального пакета Arch Linux ==="
echo "Файл: $f"
echo "Проверяю целостность архива..."
if ! bsdtar -tf "$f" >/dev/null 2>&1; then
  echo "Ошибка: архив повреждён или не является корректным пакетом."
  read -r -p "Нажми Enter для закрытия... "
  exit 1
fi

if ! pkg_info="$(pacman -Qpi "$f" 2>&1)"; then
  echo "Ошибка: файл не распознан как корректный пакет Arch Linux:"
  echo "$pkg_info"
  read -r -p "Нажми Enter для закрытия... "
  exit 1
fi

echo
printf '%s\n' "$pkg_info" | grep -E '^(Name|Version|Architecture|Description|Название|Версия|Архитектура|Описание)' || printf '%s\n' "$pkg_info"
echo
read -r -p "Установить этот пакет через pacman -U? [y/N] " answer
if [[ ! "$answer" =~ ^[YyДд]$ ]]; then
  echo "Установка отменена пользователем."
  read -r -p "Нажми Enter для закрытия... "
  exit 0
fi

echo
if sudo pacman -U -- "$f"; then
  echo
  echo "Пакет успешно установлен."
else
  rc=$?
  echo
  echo "Ошибка: pacman завершился с кодом $rc."
  echo "Проверка подписей и настройки безопасности pacman не отключались."
  read -r -p "Нажми Enter для закрытия... "
  exit "$rc"
fi
read -r -p "Нажми Enter для закрытия... "
PKG_INSTALL

# --- 7. Files (перенесено из старого скрипта с сохранением всех функций + тёмно-лаймовая тема) ---
write_file "$LIB_ROOT/files.py" 0644 <<'FILES_PY'
#!/usr/bin/env python3
import os
import sys
import shutil
import subprocess
import json
import re
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

CSS = b"""
* { font-family: 'DejaVu Sans', sans-serif; font-size: 10pt; }
window { background: #111512; color: #e1e7df; }
headerbar, toolbar { background: #171d18; color: #e1e7df; }
button { background: #1f2720; color: #e1e7df; border: 1px solid #394536; border-radius: 7px; padding: 5px 9px; }
button:hover, button:checked { background: #35452f; border-color: #71834b; color: #f0f4e9; }
entry { background: #171d18; color: #e1e7df; border: 1px solid #526447; border-radius: 6px; padding: 6px; }
entry:focus { border-color: #71834b; }
treeview { background: #111512; color: #e1e7df; }
treeview:selected { background: #405238; color: #f0f4e9; }
treeview header button { background: #171d18; color: #a0aa9d; border: 0; border-bottom: 1px solid #313b31; border-radius: 0; }
.sidebar { background: #151b16; border-right: 1px solid #2b342b; }
.sidebar row:selected { background: #405238; color: #f0f4e9; }
.dim-label { color: #a0aa9d; }
menu { background: #171d18; color: #e1e7df; border: 1px solid #526447; }
menuitem:hover { background: #35452f; color: #f0f4e9; }
"""


def css():
    p = Gtk.CssProvider()
    p.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )


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
    return path.is_file() and path.name.endswith((".pkg.tar.zst", ".pkg.tar.xz"))


class FilesWindow(Gtk.Window):
    def __init__(self, start):
        super().__init__(title="Files")
        self.set_wmclass("files", "files")
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
        bar.set_margin_top(8)
        bar.set_margin_start(8)
        bar.set_margin_end(8)
        root.pack_start(bar, False, False, 0)

        for label, cb in (("←", self.back), ("↑", self.up), ("Обновить", self.refresh)):
            b = Gtk.Button(label=label)
            b.connect("clicked", lambda _b, f=cb: f())
            bar.pack_start(b, False, False, 0)

        self.path_entry = Gtk.Entry()
        self.path_entry.set_text(str(self.cwd))
        self.path_entry.connect("activate", self.go_entry)
        bar.pack_start(self.path_entry, True, True, 0)

        new_btn = Gtk.Button(label="Новая папка")
        new_btn.connect("clicked", self.new_folder)
        bar.pack_start(new_btn, False, False, 0)

        split = Gtk.Paned()
        root.pack_start(split, True, True, 0)

        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("sidebar")
        self.side.connect("row-activated", self.side_open)
        self.side.connect("button-press-event", self.side_context)

        sw = Gtk.ScrolledWindow()
        sw.set_size_request(200, -1)
        sw.add(self.side)
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
            col.set_resizable(True)
            col.set_clickable(True)
            col.connect("clicked", self.sort_by, idx)
            self.view.append_column(col)

        self.view.connect("row-activated", self.activate)
        self.view.connect("button-press-event", self.context_menu)

        targets = [Gtk.TargetEntry.new("text/uri-list", 0, 0)]
        self.view.enable_model_drag_source(
            Gdk.ModifierType.BUTTON1_MASK, targets, Gdk.DragAction.COPY | Gdk.DragAction.MOVE
        )
        self.view.drag_dest_set(
            Gtk.DestDefaults.ALL, targets, Gdk.DragAction.COPY | Gdk.DragAction.MOVE
        )
        self.view.connect("drag-data-get", self.drag_get)
        self.view.connect("drag-data-received", self.drag_receive)

        sw2 = Gtk.ScrolledWindow()
        sw2.add(self.view)
        right.pack_start(sw2, True, True, 0)

        self.status = Gtk.Label(xalign=0)
        self.status.set_margin_start(10)
        self.status.set_margin_bottom(6)
        root.pack_start(self.status, False, False, 0)

        self.connect("key-press-event", self.keypress)
        self.build_sidebar()
        self.refresh()

    def build_sidebar(self):
        for c in self.side.get_children():
            self.side.remove(c)
        places = [
            ("Домашняя папка", HOME),
            ("Рабочий стол", HOME / "Desktop"),
            ("Документы", HOME / "Documents"),
            ("Загрузки", HOME / "Downloads"),
            ("Изображения", HOME / "Pictures"),
            ("Музыка", HOME / "Music"),
            ("Видео", HOME / "Videos"),
            ("Корзина", FILES),
        ]
        for title, path in places:
            row = Gtk.ListBoxRow()
            row.add(Gtk.Label(label=title, xalign=0, margin=8))
            row.path = path
            self.side.add(row)

        try:
            data = json.loads(
                subprocess.run(
                    ["lsblk", "-J", "-o", "PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=True,
                ).stdout
            )

            def add_devices(nodes):
                for node in nodes:
                    if (
                        node.get("fstype")
                        and node.get("path")
                        and node.get("fstype") not in ("crypto_LUKS", "swap", "LVM2_member")
                    ):
                        mounts = [m for m in (node.get("mountpoints") or []) if m]
                        removable = str(node.get("rm", "0")) == "1"
                        external_mount = any(
                            m.startswith(("/run/media/", "/media/", "/mnt/")) for m in mounts
                        )
                        if removable or external_mount:
                            row = Gtk.ListBoxRow()
                            label = node.get("label") or Path(node["path"]).name
                            row.add(Gtk.Label(label="▤ " + label, xalign=0, margin=8))
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
                    row.path = p
                    row.bookmark = True
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
                r = subprocess.run(
                    ["udisksctl", "mount", "-b", row.device], capture_output=True, text=True
                )
                if r.returncode == 0:
                    m = re.search(r" at (.+?)\.?\s*$", r.stdout.strip())
                    if m:
                        self.load(m.group(1))
                    self.build_sidebar()
                else:
                    self.message(
                        (r.stderr or r.stdout).strip() or "Не удалось подключить накопитель"
                    )
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
            menu.append(item)
            menu.show_all()
            menu.popup_at_pointer(event)
            return True

        if not hasattr(row, "device"):
            return False

        if row.mountpoint:
            item = Gtk.MenuItem(label="Отключить накопитель")

            def act(*_):
                r = subprocess.run(
                    ["udisksctl", "unmount", "-b", row.device], capture_output=True, text=True
                )
                if r.returncode == 0:
                    if str(self.cwd).startswith(row.mountpoint):
                        self.load(HOME)
                    self.build_sidebar()
                else:
                    self.message(
                        (r.stderr or r.stdout).strip() or "Не удалось отключить накопитель"
                    )
        else:
            item = Gtk.MenuItem(label="Подключить накопитель")

            def act(*_):
                self.side_open(self.side, row)

        item.connect("activate", act)
        menu.append(item)
        menu.show_all()
        menu.popup_at_pointer(event)
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
                value = (
                    p.name.casefold()
                    if self.sort_col == 0
                    else (st.st_size if self.sort_col == 1 else st.st_mtime)
                )
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

    def go_entry(self, _entry):
        self.load(self.path_entry.get_text())

    def back(self):
        self.load(self.cwd.parent)

    def up(self):
        self.back()

    def selected(self):
        model, paths = self.view.get_selection().get_selected_rows()
        return [Path(model[p][4]) for p in paths]

    def install_package(self, path):
        try:
            subprocess.Popen(
                [
                    "alacritty",
                    "--title",
                    "Установка пакета Arch",
                    "-e",
                    "/usr/local/bin/arch-package-install",
                    str(path),
                ]
            )
        except OSError as e:
            self.message(f"Не удалось запустить установщик пакетов: {e}")

    def activate(self, _view, path, _col):
        p = Path(self.store[path][4])
        if p.is_dir():
            self.load(p)
        elif is_arch_pkg(p):
            self.install_package(p)
        else:
            Gio.AppInfo.launch_default_for_uri(p.as_uri(), None)

    def new_folder(self, _b):
        d = Gtk.Dialog(title="Новая папка", transient_for=self, flags=0)
        d.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Создать", Gtk.ResponseType.OK)
        e = Gtk.Entry()
        e.set_text("Новая папка")
        d.get_content_area().add(e)
        d.show_all()
        if d.run() == Gtk.ResponseType.OK:
            name = e.get_text().strip()
            if name and "/" not in name:
                try:
                    (self.cwd / name).mkdir()
                except OSError as ex:
                    self.message(str(ex))
        d.destroy()
        self.refresh()

    def message(self, text):
        m = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text=text,
        )
        m.run()
        m.destroy()

    def confirm(self, text):
        m = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text=text,
        )
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
        prompt = ("Удалить навсегда " if permanent else "Переместить в корзину ") + f"{len(paths)} объект(ов)?"
        if not self.confirm(prompt):
            return
        for p in paths:
            try:
                if permanent:
                    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
                else:
                    Gio.File.new_for_path(str(p)).trash(None)
            except OSError as e:
                self.message(str(e))
        self.refresh()

    def rename(self):
        paths = self.selected()
        if len(paths) != 1:
            return
        d = Gtk.Dialog(title="Переименовать", transient_for=self, flags=0)
        d.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Сохранить", Gtk.ResponseType.OK)
        e = Gtk.Entry()
        e.set_text(paths[0].name)
        d.get_content_area().add(e)
        d.show_all()
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
        d.destroy()
        self.refresh()

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
        menu = Gtk.Menu()
        sel = self.selected()
        actions = []
        if len(sel) == 1 and is_arch_pkg(sel[0]):
            actions.append(("Установить пакет Arch", lambda p=sel[0]: self.install_package(p)))
        actions.extend([
            (
                "Открыть папку",
                lambda: self.load(sel[0]) if sel and sel[0].is_dir() else None,
            ),
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
        menu.show_all()
        menu.popup_at_pointer(event)
        return True

    def keypress(self, _w, e):
        key = Gdk.keyval_name(e.keyval)
        ctrl = bool(e.state & Gdk.ModifierType.CONTROL_MASK)
        if key == "Escape":
            self.destroy()
            return True
        if key == "Delete":
            self.delete(False)
            return True
        if key == "F2":
            self.rename()
            return True
        if ctrl and key.lower() == "c":
            self.copy(False)
            return True
        if ctrl and key.lower() == "x":
            self.copy(True)
            return True
        if ctrl and key.lower() == "v":
            self.paste()
            return True
        if ctrl and key.lower() == "l":
            self.path_entry.grab_focus()
            return True
        if ctrl and key.lower() == "d":
            self.bookmark()
            return True
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

# --- 8. Power Menu и Меню переключения производительности (GTK3 без фонового демона) ---
write_file "$LIB_ROOT/menu.py" 0644 <<'MENU_PY'
#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

TEXT = "#e1e7df"
MUTED = "#a0aa9d"
ACCENT = "#71834b"
PANEL = "#1a211b"

CSS = f"""
window {{ background: rgba(8, 11, 9, 0.84); color: {TEXT}; font-family: 'DejaVu Sans', sans-serif; }}
.panel {{ background: {PANEL}; border: 1px solid #526447; border-radius: 14px; padding: 14px; }}
button {{ background: #202821; color: {TEXT}; border: 1px solid #394536; border-radius: 9px; padding: 11px 18px; }}
button:hover, button:focus {{ background: #35452f; border: 1px solid {ACCENT}; color: #f0f4e9; }}
button.active {{ background: #3b4d32; border: 1px solid #82965a; color: #f0f4e9; font-weight: bold; }}
label {{ color: {TEXT}; }}
.dim {{ color: {MUTED}; font-size: 9pt; }}
"""


def apply_css():
    p = Gtk.CssProvider()
    p.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )


def run_cmd(args):
    try:
        return subprocess.run(args, check=False).returncode == 0
    except OSError:
        return False


class Menu(Gtk.Window):
    def __init__(self, kind):
        super().__init__(title="Power Menu" if kind == "power" else "Режим производительности")
        self.kind = kind
        self.action_buttons = []
        self.set_decorated(False)
        self.set_modal(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.fullscreen()
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.KEY_PRESS_MASK)
        self.connect("key-press-event", self.on_key)
        self.connect("button-press-event", self.on_click_outside)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.set_halign(Gtk.Align.CENTER)
        outer.set_valign(Gtk.Align.CENTER)
        self.add(outer)

        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
        self.card.set_margin_top(20)
        self.card.set_margin_bottom(20)
        self.card.set_margin_start(24)
        self.card.set_margin_end(24)
        self.card.set_size_request(440, -1)
        self.card.get_style_context().add_class("panel")
        outer.pack_start(self.card, False, False, 0)

        title = Gtk.Label()
        heading = "Питание" if kind == "power" else "Режим производительности"
        title.set_markup(f"<span size='large' weight='bold'>{heading}</span>")
        self.card.pack_start(title, False, False, 4)

        focus_target = None

        if kind == "power":
            exit_cmd = (
                ["hyprshutdown"]
                if shutil.which("hyprshutdown")
                else ["hyprctl", "dispatch", "hl.dsp.exit()"]
            )
            opts = [
                ("Выключение", ["systemctl", "poweroff"]),
                ("Перезагрузка", ["systemctl", "reboot"]),
                ("Сон", ["systemctl", "suspend"]),
                ("Выход из Hyprland", exit_cmd),
            ]
            for label, cmd in opts:
                b = Gtk.Button(label=label)
                b.connect("clicked", lambda _b, c=cmd: self.act(c))
                self.card.pack_start(b, True, True, 0)
                self.action_buttons.append(b)
            focus_target = self.action_buttons[0]
        else:
            current_run = subprocess.run(
                ["powerprofilesctl", "get"], capture_output=True, text=True
            )
            listed_run = subprocess.run(
                ["powerprofilesctl", "list"], capture_output=True, text=True
            )
            current = current_run.stdout.strip() if current_run.returncode == 0 else ""
            listed = listed_run.stdout if listed_run.returncode == 0 else ""
            if listed_run.returncode != 0:
                err_lbl = Gtk.Label(
                    label="Служба power-profiles-daemon недоступна. Проверь её запуск и отсутствие конфликтующих менеджеров питания.",
                    wrap=True,
                )
                self.card.pack_start(err_lbl, False, False, 6)

            supported = [p for p in ("performance", "balanced", "power-saver") if p in listed]
            status_lbl = Gtk.Label(label="Активный режим: " + (current or "не определён"))
            self.card.pack_start(status_lbl, False, False, 2)

            desc = {
                "performance": "Максимум производительности в пределах штатных возможностей Intel CPU/UHD; нагрев и шум могут возрасти.",
                "balanced": "Сбалансированный режим для повседневной работы с умеренным энергопотреблением.",
                "power-saver": "Экономия энергии и снижение нагрева: тише охлаждение, дольше работа от батареи.",
            }
            labels = {
                "performance": "Performance (Производительность)",
                "balanced": "Balanced (Сбалансированный)",
                "power-saver": "Power Saving (Экономия энергии)",
            }
            for profile in supported:
                active = profile == current
                b = Gtk.Button(label=labels[profile] + ("  ✓" if active else ""))
                b.set_tooltip_text(desc[profile])
                if active:
                    b.get_style_context().add_class("active")
                    focus_target = b
                b.connect("clicked", lambda _b, p=profile: self.set_profile(p))
                self.card.pack_start(b, True, True, 0)
                self.action_buttons.append(b)
                info = Gtk.Label(label=desc[profile], wrap=True, xalign=0)
                info.get_style_context().add_class("dim")
                self.card.pack_start(info, False, False, 0)

            missing = [p for p in ("performance", "balanced", "power-saver") if p not in supported]
            if missing:
                miss_lbl = Gtk.Label(
                    label="Не поддерживаются данным оборудованием: " + ", ".join(missing),
                    wrap=True,
                )
                miss_lbl.get_style_context().add_class("dim")
                self.card.pack_start(miss_lbl, False, False, 4)

        cancel = Gtk.Button(label="Закрыть (Esc)")
        cancel.connect("clicked", lambda *_: self.close_menu())
        self.card.pack_start(cancel, False, False, 4)
        self.action_buttons.append(cancel)

        if focus_target is None and self.action_buttons:
            focus_target = self.action_buttons[0]
        if focus_target is not None:
            focus_target.grab_focus()

    def close_menu(self):
        self.destroy()

    def on_click_outside(self, _w, event):
        alloc = self.card.get_allocation()
        inside = (
            alloc.x <= event.x <= alloc.x + alloc.width
            and alloc.y <= event.y <= alloc.y + alloc.height
        )
        if not inside:
            self.close_menu()
            return True
        return False

    def on_key(self, _w, e):
        key = Gdk.keyval_name(e.keyval)
        if key == "Escape":
            self.close_menu()
            return True
        if key in ("Up", "Down") and self.action_buttons:
            focused = self.get_focus()
            if focused in self.action_buttons:
                idx = self.action_buttons.index(focused)
                step = -1 if key == "Up" else 1
                self.action_buttons[(idx + step) % len(self.action_buttons)].grab_focus()
            else:
                self.action_buttons[0].grab_focus()
            return True
        if key in ("Return", "KP_Enter"):
            focused = self.get_focus()
            if isinstance(focused, Gtk.Button):
                focused.clicked()
                return True
        return False

    def act(self, cmd):
        self.destroy()
        run_cmd(cmd)

    def set_profile(self, profile):
        if run_cmd(["powerprofilesctl", "set", profile]):
            state = os.path.expanduser("~/.local/state/hypr-minimal")
            os.makedirs(state, exist_ok=True)
            with open(os.path.join(state, "power-profile"), "w") as f:
                f.write(profile + "\n")
            subprocess.run(["pkill", "-RTMIN+8", "waybar"], check=False)
            self.destroy()
        else:
            d = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.ERROR,
                buttons=Gtk.ButtonsType.OK,
                text="Не удалось переключить режим производительности",
            )
            d.format_secondary_text(
                "Профиль не поддерживается оборудованием или служба power-profiles-daemon недоступна."
            )
            d.run()
            d.destroy()


def main():
    apply_css()
    kind = sys.argv[1] if len(sys.argv) > 1 else "power"
    w = Menu(kind)
    w.connect("destroy", Gtk.main_quit)
    w.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
MENU_PY

write_file "$BIN_ROOT/power-menu" 0755 <<'POWER_LAUNCH'
#!/usr/bin/env bash
if pgrep -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py power" >/dev/null 2>&1; then
  pkill -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py power" || true
  exit 0
fi
pkill -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py " 2>/dev/null || true
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py power
POWER_LAUNCH

write_file "$BIN_ROOT/performance-menu" 0755 <<'PERF_LAUNCH'
#!/usr/bin/env bash
if pgrep -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py performance" >/dev/null 2>&1; then
  pkill -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py performance" || true
  exit 0
fi
pkill -u "$UID" -f "/usr/local/lib/hypr-minimal/menu.py " 2>/dev/null || true
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py performance
PERF_LAUNCH

write_file "$BIN_ROOT/waybar-performance" 0755 <<'WB_PERF'
#!/usr/bin/env bash
set -u
mode="$(powerprofilesctl get 2>/dev/null | tr -d '\n' || true)"
case "$mode" in
  performance) label="Performance (Производительность)" ;;
  balanced)    label="Balanced (Сбалансированный)" ;;
  power-saver) label="Power Saving (Экономия энергии)" ;;
  *)           mode="unknown"; label="Не определён" ;;
esac
printf '{"text":"󰓅","tooltip":"Режим: %s\\nНажмите для переключения","class":"%s"}\n' "$label" "$mode"
WB_PERF

# --- 9. Обои и восстановление профиля ---
write_file "$BIN_ROOT/hypr-wallpaper-next" 0755 <<'WALL'
#!/usr/bin/env bash
set -Eeuo pipefail
mode="${1:-next}"
dir="$HOME/Pictures/wall"
mkdir -p "$dir"
mapfile -d '' imgs < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 | sort -z)

if ((${#imgs[@]} == 0)); then
  pkill -x swaybg 2>/dev/null || true
  if [[ "$mode" != "--init" ]]; then
    notify-send "Обои" "Папка ~/Pictures/wall пуста — используется однотонный тёмный фон." 2>/dev/null || true
  fi
  exec swaybg -c "#111512"
fi

state="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-minimal/wall-index"
mkdir -p "$(dirname "$state")"
i=-1
if [[ -r "$state" ]]; then read -r i < "$state" || i=-1; fi
[[ "$i" =~ ^-?[0-9]+$ ]] || i=-1

if [[ "$mode" == "--init" ]]; then
  if (( i < 0 || i >= ${#imgs[@]} )); then i=0; fi
else
  if (( i < -1 || i >= ${#imgs[@]} )); then i=-1; fi
  i=$(( (i + 1) % ${#imgs[@]} ))
fi

printf '%s\n' "$i" > "$state"
pkill -x swaybg 2>/dev/null || true
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
    ;;
esac
RESTORE

write_file "$BIN_ROOT/hypr-launcher" 0755 <<'LAUNCHER'
#!/usr/bin/env bash
set -e
if pgrep -u "$UID" -x wofi >/dev/null 2>&1; then
  pkill -u "$UID" -x wofi
  exit 0
fi
exec wofi --show drun --allow-images
LAUNCHER

# --- 10. Запуск Hyprland строго на Intel UHD ---
write_file "$BIN_ROOT/start-hyprland-intel" 0755 <<START_INTEL
#!/usr/bin/env bash
set -Eeuo pipefail
export AQ_DRM_DEVICES="$INTEL_DRM_CARD"
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME="$INTEL_DRI_PRIME"
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
exec /usr/bin/start-hyprland "\$@"
START_INTEL

# --- 11. Конфигурации Hyprland, Waybar, Wofi, Alacritty, GTK, Qt6, Mako, CAVA ---
mkdir -p "$CONFIG_ROOT/hypr" "$CONFIG_ROOT/waybar" "$CONFIG_ROOT/wofi" "$CONFIG_ROOT/alacritty" \
  "$CONFIG_ROOT/gtk-3.0" "$CONFIG_ROOT/gtk-4.0" "$CONFIG_ROOT/qt6ct/colors" \
  "$CONFIG_ROOT/mako" "$CONFIG_ROOT/cava" "$CONFIG_ROOT/environment.d" \
  "$STATE_ROOT" "$TARGET_HOME/Pictures/wall"

write_file "$CONFIG_ROOT/hypr/hyprland.lua" 0644 <<HYPRLUA
-- Hyprland 0.57+ (Lua API). Минимальные эффекты для снижения нагрузки и нагрева.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("GTK_THEME", "Adwaita-dark")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_STYLE_OVERRIDE", "Fusion")
hl.env("DRI_PRIME", "$INTEL_DRI_PRIME")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
hl.env("LIBVA_DRIVER_NAME", "iHD")
hl.env("__NV_PRIME_RENDER_OFFLOAD", "0")
hl.env("__VK_LAYER_NV_optimus", "")
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
            active_border = "rgba(71834bff)",
            inactive_border = "rgba(343d35cc)",
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
        rounding = 7,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },
    animations = { enabled = false },
    dwindle = { preserve_split = true },
    misc = {
        disable_hyprland_logo = true,
        background_color = "0x111512",
    },
})

local function bind(key, command)
    hl.bind(key, hl.dsp.exec_cmd(command))
end

hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE DRI_PRIME VK_LOADER_DRIVERS_SELECT __GLX_VENDOR_LIBRARY_NAME LIBVA_DRIVER_NAME QT_QPA_PLATFORMTHEME QT_STYLE_OVERRIDE")
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
    hl.exec_cmd("/usr/local/bin/hypr-restore-profile")
    hl.exec_cmd("/usr/local/bin/hypr-wallpaper-next --init")
end)

-- Основные горячие клавиши
bind("SUPER + RETURN", "alacritty -e bash -lc 'fastfetch; exec bash'")
bind("SUPER + D", "/usr/local/bin/hypr-launcher")
bind("SUPER + E", "/usr/local/bin/files")
bind("SUPER + B", "firefox")
bind("SUPER + W", "/usr/local/bin/hypr-wallpaper-next")
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + SHIFT + ESCAPE", "/usr/local/bin/power-menu")
bind("SUPER + SHIFT + P", "/usr/local/bin/performance-menu")

-- Клавиши Fn: громкость, микрофон, мультимедиа и яркость
bind("XF86AudioRaiseVolume", "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+")
bind("XF86AudioLowerVolume", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
bind("XF86AudioMute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
bind("XF86AudioMicMute", "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
bind("XF86AudioPrev", "playerctl previous")
bind("XF86AudioPlay", "playerctl play-pause")
bind("XF86AudioNext", "playerctl next")
bind("XF86MonBrightnessUp", "brightnessctl set +5%")
bind("XF86MonBrightnessDown", "brightnessctl set 5%-")

-- Скриншоты
bind("SUPER + SHIFT + S", 'grim -g "\$(slurp)" "\$HOME/Pictures/screenshot-\$(date +%F-%H%M%S).png"')
bind("SUPER + CTRL + C", 'grim -g "\$(slurp)" - | wl-copy')

-- Рабочие пространства 1..9
for i = 1, 9 do
    hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = tostring(i) }))
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = tostring(i) }))
end
HYPRLUA

# Waybar: единый согласованный стиль иконок Nerd Font (Material Design nf-md-*)
write_file "$CONFIG_ROOT/waybar/config.jsonc" 0644 <<'WAYBAR'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "spacing": 4,
  "modules-left": [
    "custom/launcher",
    "custom/files",
    "custom/terminal",
    "hyprland/workspaces"
  ],
  "modules-center": [
    "clock"
  ],
  "modules-right": [
    "tray",
    "hyprland/language",
    "pulseaudio",
    "pulseaudio#mic",
    "backlight",
    "battery",
    "custom/performance",
    "custom/power"
  ],
  "custom/launcher": {
    "format": "󰀻",
    "tooltip-format": "Меню приложений (Super + D)",
    "on-click": "/usr/local/bin/hypr-launcher"
  },
  "custom/files": {
    "format": "󰉋",
    "tooltip-format": "Files (Super + E)",
    "on-click": "/usr/local/bin/files"
  },
  "custom/terminal": {
    "format": "󰆍",
    "tooltip-format": "Alacritty (Super + Enter)",
    "on-click": "alacritty"
  },
  "hyprland/workspaces": {
    "format": "{name}",
    "on-click": "activate",
    "all-outputs": true,
    "disable-scroll": true
  },
  "clock": {
    "format": "󰅐  {:%a %d %b  %H:%M}",
    "tooltip-format": "<tt>{calendar}</tt>"
  },
  "tray": {
    "spacing": 6
  },
  "hyprland/language": {
    "format": "󰌌 {short}",
    "on-click": "hyprctl switchxkblayout current next"
  },
  "pulseaudio": {
    "format": "{icon} {volume}%",
    "format-muted": "󰖂 выкл",
    "format-icons": {
      "default": ["󰕿", "󰖀", "󰕾"]
    },
    "scroll-step": 5,
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
    "on-scroll-up": "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+",
    "on-scroll-down": "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
  },
  "pulseaudio#mic": {
    "format": "{format_source}",
    "format-source": "󰍬 {volume}%",
    "format-source-muted": "󰍭 выкл",
    "scroll-step": 5,
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle",
    "on-scroll-up": "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SOURCE@ 5%+",
    "on-scroll-down": "wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 5%-"
  },
  "backlight": {
    "format": "󰃟 {percent}%",
    "tooltip-format": "Яркость: {percent}%",
    "on-scroll-up": "brightnessctl set +5%",
    "on-scroll-down": "brightnessctl set 5%-"
  },
  "battery": {
    "format": "{icon} {capacity}%",
    "format-charging": "󰂄 {capacity}%",
    "format-plugged": "󰂄 {capacity}%",
    "format-icons": ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"],
    "states": {
      "warning": 25,
      "critical": 10
    }
  },
  "custom/performance": {
    "exec": "/usr/local/bin/waybar-performance",
    "return-type": "json",
    "interval": 60,
    "signal": 8,
    "on-click": "/usr/local/bin/performance-menu"
  },
  "custom/power": {
    "format": "󰐥",
    "tooltip-format": "Power Menu (Super + Shift + Esc)",
    "on-click": "/usr/local/bin/power-menu"
  }
}
WAYBAR

write_file "$CONFIG_ROOT/waybar/style.css" 0644 <<'WAYCSS'
* {
  font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", "DejaVu Sans", sans-serif;
  font-size: 11.5px;
  border: none;
  min-height: 0;
}

window#waybar {
  background: rgba(17, 21, 18, 0.96);
  color: #e1e7df;
  border-bottom: 1px solid #394536;
}

#clock {
  color: #e1e7df;
  font-weight: 600;
}

#workspaces button {
  color: #a0aa9d;
  background: transparent;
  padding: 0 7px;
  margin: 3px 1px;
  border-radius: 5px;
}

#workspaces button.active {
  color: #f0f4e9;
  background: #46583b;
}

#workspaces button:hover,
#custom-launcher:hover,
#custom-files:hover,
#custom-terminal:hover,
#custom-performance:hover,
#custom-power:hover,
#language:hover,
#pulseaudio:hover {
  background: #35452f;
  color: #f0f4e9;
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
  border-radius: 5px;
}

#custom-launcher,
#custom-files,
#custom-terminal {
  font-size: 13px;
}

#custom-launcher,
#custom-performance {
  color: #a9bb7a;
}

#custom-performance.performance {
  color: #c2b678;
}

#custom-performance.power-saver {
  color: #8ea97c;
}

#custom-power {
  color: #c9a792;
  padding-right: 11px;
  font-size: 13px;
}

#battery.warning {
  color: #d4b76e;
}

#battery.critical {
  color: #d4897c;
}

tooltip {
  background: #171d18;
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
window {
  background: #111512;
  color: #e1e7df;
  border: 1px solid #526447;
  border-radius: 10px;
  font-family: "DejaVu Sans", sans-serif;
}

#input {
  background: #1a211b;
  color: #e1e7df;
  border: 1px solid #526447;
  border-radius: 7px;
  margin: 8px;
  padding: 8px;
}

#entry {
  padding: 7px;
}

#entry:selected {
  background: #405238;
  color: #f0f4e9;
  border-radius: 6px;
}

#text {
  color: #e1e7df;
}
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
black = "#171d18"
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

write_file "$CONFIG_ROOT/gtk-3.0/settings.ini" 0644 <<'GTK3'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK3

write_file "$CONFIG_ROOT/gtk-4.0/settings.ini" 0644 <<'GTK4'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK4

write_file "$CONFIG_ROOT/qt6ct/colors/olive.conf" 0644 <<'QTCOLORS'
[ColorScheme]
active_colors=#ffe1e7df, #ff202a21, #ff35452f, #ff526447, #ff0b0f0c, #ff2a332a, #ffe1e7df, #ffffffff, #ffe1e7df, #ff111512, #ff111512, #ff000000, #ff46583b, #fff0f4e9, #ffa9bb7a, #ff879b60, #ff171d18, #ffe1e7df, #ff171d18, #ffe1e7df, #ff8b9689, #ff71834b
inactive_colors=#ffe1e7df, #ff202a21, #ff35452f, #ff526447, #ff0b0f0c, #ff2a332a, #ffe1e7df, #ffffffff, #ffe1e7df, #ff111512, #ff111512, #ff000000, #ff405238, #fff0f4e9, #ffa9bb7a, #ff879b60, #ff171d18, #ffe1e7df, #ff171d18, #ffe1e7df, #ff8b9689, #ff71834b
disabled_colors=#ff7c887a, #ff1a211b, #ff293329, #ff3b4938, #ff0b0f0c, #ff202820, #ff7c887a, #ffb8c0b5, #ff7c887a, #ff111512, #ff111512, #ff000000, #ff35452f, #ffb8c0b5, #ff75865a, #ff687b58, #ff171d18, #ff7c887a, #ff171d18, #ff7c887a, #ff657064, #ff526447
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
background-color=#171d18
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

[color]
foreground = '#a9bb7a'
gradient = 1
gradient_color_1 = '#526447'
gradient_color_2 = '#71834b'
gradient_color_3 = '#879b60'
gradient_color_4 = '#a9bb7a'
CAVA

# --- 12. MIME-ассоциации и скрытие служебных .desktop (Files НЕ в Wofi) ---
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
MimeType=application/x-alpm-package;application/x-zstd-compressed-tar;application/x-xz-compressed-tar;application/zstd;
PKGDESK

write_file "$CONFIG_ROOT/mimeapps.list" 0644 <<'MIME'
[Default Applications]
inode/directory=files.desktop
application/x-alpm-package=arch-package-install.desktop
application/x-zstd-compressed-tar=arch-package-install.desktop
application/x-xz-compressed-tar=arch-package-install.desktop
application/zstd=arch-package-install.desktop
application/x-zstd=arch-package-install.desktop
MIME

# Терминальный ярлык для CAVA (запуск через Alacritty, не фоновый процесс)
write_file "/usr/share/applications/cava.desktop" 0644 <<'CAVADESK'
[Desktop Entry]
Type=Application
Name=CAVA
Comment=Аудио-визуализатор в терминале
Exec=alacritty --title "CAVA" -e cava
Icon=utilities-terminal
Terminal=false
Categories=AudioVideo;Audio;
CAVADESK

# --- 13. Сторонние приложения из официальных источников ---
write_file "$LIB_ROOT/github-asset.py" 0644 <<'GH'
#!/usr/bin/env python3
import json
import re
import sys
import urllib.request

repo, pattern = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/{repo}/releases?per_page=50"
req = urllib.request.Request(url, headers={"User-Agent": "hypr-minimal-installer"})


def fetch_checksum_from_sums(assets, asset_name):
    for a in assets:
        aname = a.get("name", "")
        if re.search(r"sha256", aname, re.I) and aname.endswith((".txt", ".sha256", "SUMS")):
            try:
                sreq = urllib.request.Request(
                    a["browser_download_url"],
                    headers={"User-Agent": "hypr-minimal-installer"},
                )
                body = urllib.request.urlopen(sreq, timeout=20).read().decode("utf-8", "replace")
                for line in body.splitlines():
                    m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line.strip())
                    if m and (m.group(2).strip() == asset_name or len(body.splitlines()) == 1):
                        return "sha256:" + m.group(1).lower()
            except Exception:
                pass
    return ""


try:
    data = json.load(urllib.request.urlopen(req, timeout=25))
    for rel in data:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        assets = rel.get("assets", [])
        for a in assets:
            aname = a.get("name", "")
            if re.search(pattern, aname, re.I):
                digest = a.get("digest") or ""
                if not digest:
                    digest = fetch_checksum_from_sums(assets, aname)
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
    rm -f "$tmp"
    return 1
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  if [[ "$digest" == sha256:* ]]; then
    if ! echo "${digest#sha256:}  $tmp" | sha256sum --check --status; then
      rm -f "$tmp"
      warn "SHA-256 не совпал для $url"
      return 1
    fi
    log "SHA-256 подтверждён: $(basename "$dest")"
  else
    warn "Контрольная сумма SHA-256 не опубликована для $(basename "$dest"); загрузка выполнена по HTTPS."
  fi
  if [[ "$expected" == "elf" ]]; then
    local magic
    magic="$(od -An -N4 -tx1 "$tmp" | tr -d ' \n')"
    if [[ "$magic" != "7f454c46" ]]; then
      rm -f "$tmp"
      warn "Файл не является корректным ELF/AppImage: $url"
      return 1
    fi
  fi
  mv -f -- "$tmp" "$dest"
}

gh_asset() {
  local data url digest
  data="$(python "$LIB_ROOT/github-asset.py" "$1" "$2" 2>/dev/null)" || return 1
  url="$(printf '%s\n' "$data" | sed -n '1p')"
  digest="$(printf '%s\n' "$data" | sed -n '2p')"
  [[ -n "$url" ]] || return 1
  printf '%s\n%s\n' "$url" "$digest"
}

extract_appimage_icon() {
  local appimage="$1" name="$2" tmpdir icon_out="application-x-executable" found=""
  tmpdir="$(mktemp -d)"
  if (cd "$tmpdir" && "$appimage" --appimage-extract .DirIcon >/dev/null 2>&1 || cd "$tmpdir" && "$appimage" --appimage-extract "*.png" >/dev/null 2>&1 || cd "$tmpdir" && "$appimage" --appimage-extract "*.svg" >/dev/null 2>&1); then
    found="$(find "$tmpdir/squashfs-root" -maxdepth 4 \( -name '.DirIcon' -o -name '*.svg' -o -name '*.png' \) -type f -o -type l 2>/dev/null | head -n1 || true)"
    if [[ -n "$found" && -r "$found" ]]; then
      local real_icon ext="png"
      real_icon="$(readlink -f "$found" || printf '%s' "$found")"
      [[ "$real_icon" == *.svg ]] && ext="svg"
      if [[ -s "$real_icon" ]]; then
        install -m 0644 "$real_icon" "$ICON_ROOT/$name.$ext"
        icon_out="$ICON_ROOT/$name.$ext"
      fi
    fi
  fi
  rm -rf "$tmpdir"
  printf '%s\n' "$icon_out"
}

write_appimage_entry() {
  local appimage="$1" name="$2" title="$3" category="$4" icon
  chmod 0755 "$appimage"
  cat > "$BIN_ROOT/$name" <<EOF
#!/usr/bin/env bash
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME="$INTEL_DRI_PRIME"
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
exec "$appimage" --appimage-extract-and-run "\$@"
EOF
  chmod 0755 "$BIN_ROOT/$name"
  icon="$(extract_appimage_icon "$appimage" "$name")"
  cat > "/usr/share/applications/$name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$title
Exec=$BIN_ROOT/$name %U
Icon=$icon
Terminal=false
Categories=$category
EOF
}

install_appimage() {
  local repo="$1" pattern="$2" name="$3" title="$4" category="$5" url digest dir
  local -a asset
  if ! mapfile -t asset < <(gh_asset "$repo" "$pattern"); then
    warn "$title: не удалось получить релиз с GitHub ($repo)."
    return 1
  fi
  url="${asset[0]:-}"
  digest="${asset[1]:-}"
  [[ -n "$url" ]] || { warn "$title: подходящий AppImage x86_64 не найден."; return 1; }
  dir="$APP_ROOT/$name"
  install -d -m 0755 "$dir"
  if ! fetch_file "$url" "$dir/$name.AppImage" "$digest" elf; then
    warn "$title: загрузка или проверка файла не удалась."
    return 1
  fi
  write_appimage_entry "$dir/$name.AppImage" "$name" "$title" "$category"
  log "$title установлен ($dir/$name.AppImage)."
}

install_arch_release() {
  local repo="$1" pattern="$2" pkgname="$3" url digest tmp
  local -a asset
  if ! mapfile -t asset < <(gh_asset "$repo" "$pattern"); then
    warn "$pkgname: не найден официальный пакет .pkg.tar.zst ($repo)."
    return 1
  fi
  url="${asset[0]:-}"
  digest="${asset[1]:-}"
  [[ -n "$url" ]] || { warn "$pkgname: пакет не найден."; return 1; }
  tmp="$(mktemp --suffix=.pkg.tar.zst)"
  if ! fetch_file "$url" "$tmp" "$digest"; then
    rm -f "$tmp"
    return 1
  fi
  if pacman -U --needed --noconfirm -- "$tmp"; then
    log "$pkgname установлен через pacman -U."
  else
    warn "$pkgname: pacman -U не смог установить пакет."
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

log "Установка сторонних приложений из официальных источников"

# 1. Happ — официальный пакет Arch (.pkg.tar.zst) с GitHub Releases
install_arch_release "Happ-proxy/happ-desktop" '^Happ\.linux\.x64\.pkg\.tar\.zst$' happ || true

# 2. PhotoCraft — официальный AppImage + SHA256SUMS.txt с GitHub Releases
install_appimage "storytold/photocraft" 'photocraft-.*-linux-x86_64\.AppImage$' photocraft "PhotoCraft" "Graphics;" || true

# 3. ONLYOFFICE — официальный GitHub AppImage Releases с fallback на download.onlyoffice.com
ONLYOFFICE_DIR="$APP_ROOT/onlyoffice"
install -d -m 0755 "$ONLYOFFICE_DIR"
if ! install_appimage "ONLYOFFICE/appimage-desktopeditors" '^DesktopEditors-x86_64\.AppImage$' onlyoffice "ONLYOFFICE" "Office;"; then
  ONLYOFFICE_URL="https://download.onlyoffice.com/install/desktop/editors/linux/DesktopEditors-x86_64.AppImage"
  if fetch_file "$ONLYOFFICE_URL" "$ONLYOFFICE_DIR/onlyoffice.AppImage" "" elf; then
    write_appimage_entry "$ONLYOFFICE_DIR/onlyoffice.AppImage" "onlyoffice" "ONLYOFFICE" "Office;"
    log "ONLYOFFICE установлен с официального сайта."
  else
    warn "ONLYOFFICE: загрузка с официального сайта не удалась."
  fi
fi

# 4. Limusic — официальный AppImage с GitHub Releases
install_appimage "SimoHypers/limusic" 'limusic.*(x86_64|amd64).*\.AppImage$' limusic "Limusic" "AudioVideo;Audio;Player;" || true

# 5. OpenCode Desktop — официальный AppImage с GitHub Releases
install_appimage "anomalyco/opencode" 'opencode-desktop-linux-(x86_64|amd64|x64)\.AppImage$' opencode "OpenCode" "Development;" || true

# --- 14. Курирование Wofi: скрываем только системный технический мусор, не блокируя будущие GUI-программы ---
WOFI_HIDE_DIR="$TARGET_HOME/.local/share/applications"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$WOFI_HIDE_DIR"
python - "$WOFI_HIDE_DIR" "$BACKUP_ROOT" <<'WOFI_CLEAN'
import os
import re
import shutil
import sys
from pathlib import Path

user_apps, backup_root = Path(sys.argv[1]), Path(sys.argv[2])
hide_ids = {
    "avahi-discover.desktop",
    "bssh.desktop",
    "bvnc.desktop",
    "qv4l2.desktop",
    "qvidcap.desktop",
    "lstopo.desktop",
    "qt6ct.desktop",
    "xterm.desktop",
    "uxterm.desktop",
    "cmake-gui.desktop",
}
override_text = "[Desktop Entry]\nType=Application\nName=Служебная утилита\nNoDisplay=true\n"

for desktop_id in hide_ids:
    src = Path("/usr/share/applications") / desktop_id
    if not src.exists():
        continue
    dst = user_apps / desktop_id
    if dst.is_symlink():
        backup = backup_root / str(dst).lstrip("/")
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_text("SYMLINK -> " + os.readlink(dst) + "\n")
        dst.unlink()
    elif dst.exists() and dst.read_text(errors="replace") != override_text:
        backup = backup_root / str(dst).lstrip("/")
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dst, backup)
    dst.write_text(override_text)
    os.chmod(dst, 0o644)
WOFI_CLEAN

# --- 15. Переменные окружения Intel для всей пользовательской сессии ---
write_file "$CONFIG_ROOT/environment.d/90-intel-gpu.conf" 0644 <<ENV
DRI_PRIME=$INTEL_DRI_PRIME
__GLX_VENDOR_LIBRARY_NAME=mesa
LIBVA_DRIVER_NAME=iHD
VK_LOADER_DRIVERS_SELECT=*intel_icd*
QT_QPA_PLATFORMTHEME=qt6ct
QT_STYLE_OVERRIDE=Fusion
ENV

# --- 16. Безопасный автозапуск Hyprland только с TTY1 ---
USER_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
case "${USER_SHELL##*/}" in
  bash) PROFILE="$TARGET_HOME/.bash_profile"; PROFILE_KIND=bash ;;
  zsh)  PROFILE="$TARGET_HOME/.zprofile"; PROFILE_KIND=zsh ;;
  *)
    PROFILE=""
    PROFILE_KIND=unsupported
    warn "Автозапуск TTY1 не добавлен (оболочка $USER_SHELL). Запускай /usr/local/bin/start-hyprland-intel вручную."
    ;;
esac

if [[ -n "$PROFILE" ]]; then
  if [[ ! -e "$PROFILE" ]]; then
    if [[ "$PROFILE_KIND" == "bash" ]]; then
      write_file "$PROFILE" 0644 <<'BPROFILE'
[[ -f ~/.bashrc ]] && . ~/.bashrc
BPROFILE
    else
      write_file "$PROFILE" 0644 <<'ZPROFILE'
[[ -f ~/.zshrc ]] && . ~/.zshrc
ZPROFILE
    fi
  fi
  if ! grep -q 'HYPR_MINIMAL_TTY1' "$PROFILE"; then
    backup_file "$PROFILE"
    cat >> "$PROFILE" <<LOGIN_PROFILE

# HYPR_MINIMAL_TTY1: безопасный запуск Hyprland только из интерактивной TTY1.
if [[ -z "\${WAYLAND_DISPLAY:-}" && -z "\${DISPLAY:-}" && "\${XDG_VTNR:-0}" == "1" && -t 0 ]]; then
    export DRI_PRIME="$INTEL_DRI_PRIME"
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    export LIBVA_DRIVER_NAME=iHD
    export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
    exec /usr/local/bin/start-hyprland-intel
fi
LOGIN_PROFILE
  fi
fi

# --- 17. Службы питания (строго один power-profiles-daemon) и PipeWire ---
CONFLICTS=()
for svc in tlp.service auto-cpufreq.service tuned.service laptop-mode.service; do
  if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    CONFLICTS+=("$svc")
  fi
done

POWER_PROFILE_DAEMON_READY=1
if ((${#CONFLICTS[@]})); then
  printf 'Обнаружены службы управления питанием, конфликтующие с power-profiles-daemon: %s\n' "${CONFLICTS[*]}"
  read -r -p "Отключить их (без удаления пакетов) и использовать power-profiles-daemon? [y/N] " answer
  if [[ "$answer" =~ ^[YyДд]$ ]]; then
    for svc in "${CONFLICTS[@]}"; do
      systemctl disable --now "$svc" || warn "Не удалось отключить $svc"
    done
  else
    POWER_PROFILE_DAEMON_READY=0
    warn "Конфликтующие службы не тронуты; меню производительности не сможет работать до выбора одного менеджера."
  fi
fi
if ((POWER_PROFILE_DAEMON_READY)); then
  systemctl enable --now power-profiles-daemon.service
fi

USER_SYSTEMD="$TARGET_HOME/.config/systemd/user"
install -d "$USER_SYSTEMD/sockets.target.wants" "$USER_SYSTEMD/default.target.wants"
for unit in pipewire.socket pipewire-pulse.socket; do
  src="/usr/lib/systemd/user/$unit"
  dst="$USER_SYSTEMD/sockets.target.wants/$unit"
  if [[ -e "$src" && ! -e "$dst" && ! -L "$dst" ]]; then
    ln -s "$src" "$dst"
  fi
done
if [[ -e /usr/lib/systemd/user/wireplumber.service && ! -e "$USER_SYSTEMD/default.target.wants/wireplumber.service" && ! -L "$USER_SYSTEMD/default.target.wants/wireplumber.service" ]]; then
  ln -s /usr/lib/systemd/user/wireplumber.service "$USER_SYSTEMD/default.target.wants/wireplumber.service"
fi
chown -R "$TARGET_USER:$TARGET_GROUP" "$USER_SYSTEMD"
runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" systemctl --user daemon-reload 2>/dev/null || true

# --- 18. MIME, каталоги пользователя и права доступа ---
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-user-dirs-update >/dev/null 2>&1 || true
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default files.desktop inode/directory >/dev/null 2>&1 || true
for mime in application/x-alpm-package application/x-zstd-compressed-tar application/x-xz-compressed-tar application/zstd; do
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default arch-package-install.desktop "$mime" >/dev/null 2>&1 || true
done
update-desktop-database "$TARGET_HOME/.local/share/applications" >/dev/null 2>&1 || true
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

[[ -n "$PROFILE" ]] && chown "$TARGET_USER:$TARGET_GROUP" "$PROFILE" 2>/dev/null || true
chown -R "$TARGET_USER:$TARGET_GROUP" "$CONFIG_ROOT" "$TARGET_HOME/.local" "$TARGET_HOME/Pictures" 2>/dev/null || true
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$STATE_ROOT" "$TARGET_HOME/Pictures/wall"

# --- 19. Статические проверки и аудит NVIDIA ---
log "Проверка синтаксиса установленных файлов"
for f in \
  "$BIN_ROOT/arch-package-install" \
  "$BIN_ROOT/files" \
  "$BIN_ROOT/power-menu" \
  "$BIN_ROOT/performance-menu" \
  "$BIN_ROOT/waybar-performance" \
  "$BIN_ROOT/hypr-wallpaper-next" \
  "$BIN_ROOT/hypr-restore-profile" \
  "$BIN_ROOT/hypr-launcher" \
  "$BIN_ROOT/start-hyprland-intel"; do
  bash -n "$f"
done

python -m py_compile "$LIB_ROOT/files.py" "$LIB_ROOT/menu.py" "$LIB_ROOT/github-asset.py"
python -m json.tool "$CONFIG_ROOT/waybar/config.jsonc" >/dev/null

if command -v luac >/dev/null 2>&1; then
  luac -p "$CONFIG_ROOT/hypr/hyprland.lua"
else
  warn "luac не найден; проверка синтаксиса hyprland.lua пропущена."
fi

log "Проверка состояния NVIDIA (пакеты не удаляются автоматически)"
if pacman -Qq 2>/dev/null | grep -Eiq '^(nvidia|nvidia-open|nvidia-utils|lib32-nvidia|opencl-nvidia|cuda|bumblebee|optimus-manager)'; then
  warn "В системе присутствуют пакеты NVIDIA/CUDA/Optimus. Они не удалялись; сеанс привязан к Intel UHD программно."
else
  log "Пакеты NVIDIA/CUDA/Optimus не установлены."
fi

for svc in nvidia-persistenced.service nvidia-powerd.service; do
  if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    systemctl disable --now "$svc" || warn "Не удалось отключить службу $svc."
  fi
done

if lsmod | grep -qE '^(nvidia|nouveau)'; then
  warn "Модуль nvidia/nouveau загружен в текущем ядре. Он не выгружается вслепую; после перезагрузки композитор и приложения будут использовать только Intel UHD."
fi

if command -v lspci >/dev/null 2>&1; then
  lspci -nnk | grep -A3 -Ei 'VGA compatible controller|3D controller|Display controller' || true
fi

cat <<EOF

====================================================================
Установка завершена для пользователя: $TARGET_USER
====================================================================
Резервные копии прежних конфигураций: $BACKUP_ROOT

Что дальше:
  1. Перезагрузи ноутбук или выйди и войди в TTY1.
  2. Положи обои (.jpg/.png/.webp) в ~/Pictures/wall (или оставь пустой для однотонного тёмного фона).
  3. Проверь графику (после входа в Hyprland):
       - glxinfo -B            (если установлен mesa-utils)
       - vulkaninfo --summary  (если установлен vulkan-tools)
  4. Проверь профили питания:
       - powerprofilesctl list
       - powerprofilesctl get

Примечание по NVIDIA GTX 1650:
  Драйверы NVIDIA не устанавливались и не удалялись. Hyprland и приложения
  ограничены Intel UHD ($INTEL_DRM_CARD, $INTEL_DRI_PRIME, Intel Vulkan ICD).
  Если в BIOS/UEFI ноутбука есть переключатель GPU (Switchable / UMA / iGPU Only),
  для полного аппаратного обесточивания дискретной карты выбери iGPU-режим там.
  Без аппаратного отключения в BIOS питание GTX 1650 на уровне шины PCIe может не сниматься полностью.
EOF