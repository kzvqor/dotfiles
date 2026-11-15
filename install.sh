#!/usr/bin/env bash
# Минимальная установка Arch Linux + Hyprland для Intel UHD Graphics.
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
    # Replace symlinks themselves rather than writing through them into another path.
    [[ ! -L "$dest" ]] || rm -f -- "$dest"
  fi
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

log "Пользователь: $TARGET_USER ($TARGET_HOME)"
log "Резервные копии конфигураций будут сохранены в $BACKUP_ROOT"

# multilib нужен Steam для 32-битных библиотек. Существующие настройки сохраняются.
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

# Сначала фиксируем Intel Vulkan/OpenGL-провайдеры отдельной транзакцией.
# Это не даёт pacman выбрать NVIDIA как провайдера Steam при разрешении зависимостей.
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
  ttf-dejavu ttf-jetbrains-mono-nerd noto-fonts-emoji
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

# Строго выбираем Intel: если iGPU не обнаружена, не запускаем конфигурацию с возможным fallback на NVIDIA.
[[ "$(uname -m)" == "x86_64" ]] || die "Поддерживается только x86_64."
INTEL_DRM_CARD="/dev/dri/by-path/pci-0000:00:02.0-card"
[[ -e "$INTEL_DRM_CARD" ]] || die "Не найден DRM-узел Intel UHD ($INTEL_DRM_CARD). Отказ от настройки, чтобы не допустить fallback на NVIDIA. Проверь i915 и /dev/dri/by-path."
INTEL_CARD_REAL="$(readlink -f "$INTEL_DRM_CARD")"
INTEL_CARD_NAME="${INTEL_CARD_REAL##*/}"
INTEL_VENDOR="$(cat "/sys/class/drm/$INTEL_CARD_NAME/device/vendor" 2>/dev/null || true)"
[[ "$INTEL_VENDOR" == "0x8086" ]] || die "Устройство $INTEL_DRM_CARD не подтверждено как Intel (vendor=$INTEL_VENDOR)."
INTEL_ICD="/usr/share/vulkan/icd.d/intel_icd.json"
[[ -r "$INTEL_ICD" ]] || die "Не найден Intel Vulkan ICD ($INTEL_ICD), хотя vulkan-intel был запрошен."

# Утилиты для локальных .pkg.tar.* устанавливаются только после явного подтверждения.
install -d -m 0755 "$LIB_ROOT" "$APP_ROOT"
write_file "$BIN_ROOT/arch-package-install" 0755 <<'PKG_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
f="${1:-}"
[[ -n "$f" ]] || { echo "Не передан файл пакета."; read -r -p "Enter для выхода "; exit 2; }
f="$(realpath -- "$f")"
[[ -f "$f" && -r "$f" ]] || { echo "Файл не найден или недоступен: $f"; read -r -p "Enter для выхода "; exit 2; }
case "$f" in
  *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz|*.pkg.tar)
    ;;
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

# Небольшой Python GTK файловый менеджер. Файловые операции выполняются от обычного пользователя.
write_file "$LIB_ROOT/files.py" 0644 <<'FILES_PY'
#!/usr/bin/env python3
import os, sys, shutil, subprocess, mimetypes, json
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
window { background: #141a14; color: #e1e7df; }
headerbar, toolbar { background: #1a211b; color: #e1e7df; }
button { background: #1a211b; color: #e1e7df; border: 1px solid #3b4938; border-radius: 7px; padding: 5px 9px; }
button:hover, button:checked { background: #2d3a2c; border-color: #a9bb7a; }
entry { background: #1a211b; color: #e1e7df; border: 1px solid #526447; border-radius: 6px; padding: 6px; }
treeview { background: #141a14; color: #e1e7df; }
treeview:selected { background: #7d9460; color: #141a14; }
.sidebar { background: #1a211b; }
.dim-label { color: #a0aa9d; }
"""
def css():
    p = Gtk.CssProvider()
    p.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

def human(n):
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if n < 1024: return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} ПБ"

def unique_path(folder, name):
    p = folder / name
    if not p.exists(): return p
    base, ext = os.path.splitext(name)
    i = 1
    while (folder / f"{base} ({i}){ext}").exists(): i += 1
    return folder / f"{base} ({i}){ext}"

def trash_path(path):
    FILES.mkdir(parents=True, exist_ok=True); INFO.mkdir(parents=True, exist_ok=True)
    dest = unique_path(FILES, path.name)
    Gio.File.new_for_path(str(path)).trash(None)
    return dest

class FilesWindow(Gtk.Window):
    def __init__(self, start):
        super().__init__(title="Files")
        self.set_default_size(1000, 650)
        self.cwd = Path(start).expanduser().resolve()
        FILES.mkdir(parents=True,exist_ok=True); INFO.mkdir(parents=True,exist_ok=True)
        self.clipboard_paths, self.cut = [], False
        self.sort_col, self.sort_reverse = 0, False
        self.store = Gtk.ListStore(str, str, str, bool, str)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6); self.add(root)
        bar = Gtk.Box(spacing=5); bar.set_margin_top(8); bar.set_margin_start(8); bar.set_margin_end(8)
        root.pack_start(bar, False, False, 0)
        for label, cb in (("←", self.back), ("↑", self.up), ("Обновить", self.refresh)):
            b=Gtk.Button(label=label); b.connect("clicked", lambda _b, f=cb: f()); bar.pack_start(b, False, False, 0)
        self.path_entry=Gtk.Entry(); self.path_entry.set_text(str(self.cwd)); self.path_entry.connect("activate", self.go_entry)
        bar.pack_start(self.path_entry, True, True, 0)
        new=Gtk.Button(label="Новая папка"); new.connect("clicked", self.new_folder); bar.pack_start(new, False, False, 0)
        split=Gtk.Paned(); root.pack_start(split, True, True, 0)
        self.side=Gtk.ListBox(); self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("sidebar")
        self.side.connect("row-activated", self.side_open)
        self.side.connect("button-press-event", self.side_context)
        sw=Gtk.ScrolledWindow(); sw.set_size_request(190,-1); sw.add(self.side); split.pack1(sw,False,False)
        right=Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4); split.pack2(right,True,False)
        self.search=Gtk.SearchEntry(); self.search.set_placeholder_text("Поиск в текущей папке…")
        self.search.connect("search-changed", self.refresh); right.pack_start(self.search,False,False,4)
        self.view=Gtk.TreeView(model=self.store); self.view.set_headers_clickable(True)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        for title, idx in (("Имя",0),("Размер",1),("Изменён",2)):
            r=Gtk.CellRendererText()
            col=Gtk.TreeViewColumn(title,r,text=idx); col.set_resizable(True); col.set_clickable(True)
            col.connect("clicked",self.sort_by,idx); self.view.append_column(col)
        self.view.connect("row-activated",self.activate)
        self.view.connect("button-press-event",self.context_menu)
        targets=[Gtk.TargetEntry.new("text/uri-list",0,0)]
        self.view.enable_model_drag_source(Gdk.ModifierType.BUTTON1_MASK,targets,Gdk.DragAction.COPY|Gdk.DragAction.MOVE)
        self.view.drag_dest_set(Gtk.DestDefaults.ALL,targets,Gdk.DragAction.COPY|Gdk.DragAction.MOVE)
        self.view.connect("drag-data-get",self.drag_get)
        self.view.connect("drag-data-received",self.drag_receive)
        sw2=Gtk.ScrolledWindow(); sw2.add(self.view); right.pack_start(sw2,True,True,0)
        self.status=Gtk.Label(xalign=0); self.status.set_margin_start(10); self.status.set_margin_bottom(6)
        root.pack_start(self.status,False,False,0)
        self.connect("key-press-event",self.keypress)
        self.build_sidebar(); self.refresh()

    def build_sidebar(self):
        for c in self.side.get_children(): self.side.remove(c)
        places=[("Домашняя папка",HOME),("Рабочий стол",HOME/"Desktop"),("Документы",HOME/"Documents"),
                ("Загрузки",HOME/"Downloads"),("Изображения",HOME/"Pictures"),("Музыка",HOME/"Music"),
                ("Видео",HOME/"Videos"),("Корзина",FILES)]
        for title,path in places:
            row=Gtk.ListBoxRow(); row.add(Gtk.Label(label=title,xalign=0,margin=8)); row.path=path
            self.side.add(row)
        try:
            data=json.loads(subprocess.run(["lsblk","-J","-o","PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM"],capture_output=True,text=True,timeout=5,check=True).stdout)
            def add_devices(nodes):
                for node in nodes:
                    if node.get("fstype") and node.get("path") and node.get("fstype") not in ("crypto_LUKS","swap","LVM2_member"):
                        mounts=[m for m in (node.get("mountpoints") or []) if m]
                        removable=str(node.get("rm","0"))=="1"
                        external_mount=any(m.startswith(("/run/media/","/media/","/mnt/")) for m in mounts)
                        if removable or external_mount:
                            row=Gtk.ListBoxRow(); row.add(Gtk.Label(label="▤ "+(node.get("label") or Path(node["path"]).name),xalign=0,margin=8))
                            row.device=node["path"]; row.mountpoint=mounts[0] if mounts else None; self.side.add(row)
                    add_devices(node.get("children") or [])
            add_devices(data.get("blockdevices") or [])
        except Exception: pass
        try:
            for line in BOOKMARKS.read_text().splitlines():
                p=Path(line)
                if p.is_dir():
                    row=Gtk.ListBoxRow(); row.add(Gtk.Label(label="★ "+p.name,xalign=0,margin=8)); row.path=p; row.bookmark=True
                    self.side.add(row)
        except OSError: pass
        self.side.show_all()

    def side_open(self,_box,row):
        if not row: return
        if hasattr(row,"device"):
            if row.mountpoint:
                self.load(row.mountpoint)
            else:
                r=subprocess.run(["udisksctl","mount","-b",row.device],capture_output=True,text=True)
                if r.returncode==0:
                    import re
                    m=re.search(r" at (.+?)\.?\s*$",r.stdout.strip())
                    if m: self.load(m.group(1))
                    self.build_sidebar()
                else: self.message((r.stderr or r.stdout).strip() or "Не удалось подключить накопитель")
        elif hasattr(row,"path") and row.path.exists(): self.load(row.path)

    def side_context(self,_box,event):
        if event.button!=3:return False
        row=self.side.get_row_at_y(int(event.y))
        if not row:return False
        menu=Gtk.Menu()
        if hasattr(row,"bookmark"):
            item=Gtk.MenuItem(label="Убрать закладку")
            def unmount(*_):
                marks=BOOKMARKS.read_text().splitlines() if BOOKMARKS.exists() else []
                BOOKMARKS.write_text("\n".join(x for x in marks if x!=str(row.path))+"\n")
                self.build_sidebar()
            item.connect("activate",unmount);menu.append(item);menu.show_all();menu.popup_at_pointer(event);return True
        if not hasattr(row,"device"):return False
        if row.mountpoint:
            item=Gtk.MenuItem(label="Отключить накопитель")
            def unmount(*_):
                r=subprocess.run(["udisksctl","unmount","-b",row.device],capture_output=True,text=True)
                if r.returncode==0:
                    if str(self.cwd).startswith(row.mountpoint):self.load(HOME)
                    self.build_sidebar()
                else:self.message((r.stderr or r.stdout).strip() or "Не удалось отключить накопитель")
        else:
            item=Gtk.MenuItem(label="Подключить накопитель")
            def unmount(*_):self.side_open(self.side,row)
        item.connect("activate",unmount);menu.append(item);menu.show_all();menu.popup_at_pointer(event);return True
    def load(self,path):
        p=Path(path).expanduser()
        if not p.is_dir(): return
        self.cwd=p.resolve(); self.path_entry.set_text(str(self.cwd)); self.refresh()

    def refresh(self,*_):
        self.store.clear()
        try: entries=list(self.cwd.iterdir())
        except OSError as e: self.status.set_text(str(e)); return
        query=self.search.get_text().casefold()
        entries=[p for p in entries if query in p.name.casefold()]
        def order_key(p):
            try:
                st=p.stat()
                value=p.name.casefold() if self.sort_col==0 else (st.st_size if self.sort_col==1 else st.st_mtime)
            except OSError: value=0
            return (not p.is_dir(), value)
        entries.sort(key=order_key,reverse=self.sort_reverse)
        for p in entries:
            try:
                st=p.lstat(); size="—" if p.is_dir() else human(st.st_size)
                date=GLib.DateTime.new_from_unix_local(int(st.st_mtime)).format("%Y-%m-%d %H:%M")
                self.store.append([p.name,size,date,p.is_dir(),str(p)])
            except OSError: continue
        self.status.set_text(f"{len(entries)} объектов · {self.cwd}")

    def sort_by(self,_col,idx):
        self.sort_reverse=not self.sort_reverse if self.sort_col==idx else False
        self.sort_col=idx; self.refresh()

    def go_entry(self,_entry): self.load(self.path_entry.get_text())
    def back(self): self.load(self.cwd.parent)
    def up(self): self.back()
    def selected(self):
        model, paths=self.view.get_selection().get_selected_rows()
        return [Path(model[p][4]) for p in paths]
    def activate(self,_view,path,_col):
        p=Path(self.store[path][4])
        if p.is_dir(): self.load(p)
        else: Gio.AppInfo.launch_default_for_uri(p.as_uri(),None)
    def new_folder(self,_b):
        d=Gtk.Dialog(title="Новая папка",transient_for=self,flags=0)
        d.add_buttons("Отмена",Gtk.ResponseType.CANCEL,"Создать",Gtk.ResponseType.OK)
        e=Gtk.Entry(); e.set_text("Новая папка"); d.get_content_area().add(e); d.show_all()
        if d.run()==Gtk.ResponseType.OK:
            name=e.get_text().strip()
            if name and "/" not in name:
                try: (self.cwd/name).mkdir()
                except OSError as ex: self.message(str(ex))
        d.destroy(); self.refresh()
    def message(self,text):
        m=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.INFO,buttons=Gtk.ButtonsType.OK,text=text)
        m.run(); m.destroy()
    def confirm(self,text):
        m=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.QUESTION,buttons=Gtk.ButtonsType.YES_NO,text=text)
        ok=m.run()==Gtk.ResponseType.YES; m.destroy(); return ok
    def copy(self,cut=False):
        self.clipboard_paths=self.selected(); self.cut=cut
    def paste(self):
        if not self.clipboard_paths:return
        for src in self.clipboard_paths:
            try:
                if src.parent.resolve()==self.cwd.resolve(): continue
                if src.is_dir() and self.cwd.resolve().is_relative_to(src.resolve()):
                    raise OSError("Нельзя копировать папку внутрь самой себя")
                dst=unique_path(self.cwd,src.name)
                if self.cut: shutil.move(str(src),str(dst))
                elif src.is_dir(): shutil.copytree(src,dst)
                else: shutil.copy2(src,dst)
            except OSError as e: self.message(str(e))
        if self.cut:self.clipboard_paths=[]
        self.refresh()
    def delete(self,permanent=False):
        paths=self.selected()
        if not paths:return
        if not self.confirm(("Удалить навсегда " if permanent else "Переместить в корзину ") + f"{len(paths)} объект(ов)?"):return
        for p in paths:
            try:
                if permanent:
                    shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
                else: Gio.File.new_for_path(str(p)).trash(None)
            except OSError as e:self.message(str(e))
        self.refresh()
    def rename(self):
        paths=self.selected()
        if len(paths)!=1:return
        d=Gtk.Dialog(title="Переименовать",transient_for=self,flags=0)
        d.add_buttons("Отмена",Gtk.ResponseType.CANCEL,"Сохранить",Gtk.ResponseType.OK)
        e=Gtk.Entry();e.set_text(paths[0].name);d.get_content_area().add(e);d.show_all()
        if d.run()==Gtk.ResponseType.OK and e.get_text().strip():
            try:
                new_name=e.get_text().strip()
                if new_name in (".", "..") or "/" in new_name or "\\" in new_name:
                    raise OSError("Недопустимое имя файла")
                target=paths[0].with_name(new_name)
                if target.exists() or target.is_symlink():
                    raise OSError("Файл с таким именем уже существует; он не будет перезаписан")
                paths[0].rename(target)
            except (OSError, ValueError) as ex:self.message(str(ex))
        d.destroy();self.refresh()
    def bookmark(self):
        p=str(self.cwd); BOOKMARKS.parent.mkdir(parents=True,exist_ok=True)
        old=BOOKMARKS.read_text().splitlines() if BOOKMARKS.exists() else []
        if p not in old: old.append(p)
        BOOKMARKS.write_text("\n".join(old)+"\n"); self.build_sidebar()
    def restore_selected(self):
        for src in self.selected():
            info=INFO/(src.name+".trashinfo")
            try:
                original=None
                for line in info.read_text(errors="replace").splitlines():
                    if line.startswith("Path="):
                        original=Path(unquote(line[5:]))
                        break
                if not original or not original.is_absolute(): raise OSError("Не удалось определить исходный путь")
                original.parent.mkdir(parents=True,exist_ok=True)
                shutil.move(str(src),str(unique_path(original.parent,original.name)))
                info.unlink(missing_ok=True)
            except OSError as e: self.message(str(e))
        self.refresh()
    def drag_get(self,_view,_ctx,data,_info,_time):
        data.set_uris([p.as_uri() for p in self.selected()])
    def drag_receive(self,view,ctx,x,y,data,_info,_time):
        dest=self.cwd
        hit=view.get_dest_row_at_pos(x,y)
        if hit and self.store[hit[0]][3]: dest=Path(self.store[hit[0]][4])
        uris=data.get_uris() or []
        move=ctx.get_selected_action()==Gdk.DragAction.MOVE
        for uri in uris:
            src=Gio.File.new_for_uri(uri).get_path()
            if not src: continue
            src=Path(src)
            try:
                if src.resolve()==dest.resolve() or dest.resolve().is_relative_to(src.resolve()): continue
                target=unique_path(dest,src.name)
                if move: shutil.move(str(src),str(target))
                elif src.is_dir(): shutil.copytree(src,target)
                else: shutil.copy2(src,target)
            except (OSError,ValueError) as e: self.message(str(e))
        ctx.finish(True,False,_time);self.refresh()
    def properties(self):
        paths=self.selected() or [self.cwd]
        lines=[]
        for p in paths:
            try:
                if p.is_dir():
                    total=0
                    for root,dirs,files in os.walk(p,followlinks=False):
                        for name in files:
                            try: total+=(Path(root)/name).lstat().st_size
                            except OSError: pass
                    size="Папка · "+human(total)
                else: size=human(p.lstat().st_size)
                lines.append(f"{p.name}: {size}")
            except OSError as e: lines.append(f"{p}: {e}")
        self.message("\n".join(lines))
    def context_menu(self,_view,event):
        if event.button!=3:return False
        menu=Gtk.Menu()
        actions=[("Открыть папку",lambda:self.load(self.selected()[0]) if self.selected() and self.selected()[0].is_dir() else None),
                 ("Копировать",lambda:self.copy(False)),("Вырезать",lambda:self.copy(True)),
                 ("Вставить",self.paste),("Переименовать",self.rename),("В корзину",lambda:self.delete(False)),
                 ("Восстановить из корзины",self.restore_selected),("Удалить навсегда",lambda:self.delete(True)),
                 ("Свойства / размер",self.properties),("Добавить текущую папку в закладки",self.bookmark)]
        for label,cb in actions:
            item=Gtk.MenuItem(label=label);item.connect("activate",lambda _i,f=cb:f());menu.append(item)
        menu.show_all();menu.popup_at_pointer(event);return True
    def keypress(self,_w,e):
        key=Gdk.keyval_name(e.keyval); ctrl=bool(e.state&Gdk.ModifierType.CONTROL_MASK)
        if key=="Escape": self.destroy();return True
        if key=="Delete": self.delete(False);return True
        if key=="F2": self.rename();return True
        if ctrl and key.lower()=="c":self.copy(False);return True
        if ctrl and key.lower()=="x":self.copy(True);return True
        if ctrl and key.lower()=="v":self.paste();return True
        if ctrl and key.lower()=="l":self.path_entry.grab_focus();return True
        if ctrl and key.lower()=="d":self.bookmark();return True
        return False

def main():
    css(); start=sys.argv[1] if len(sys.argv)>1 and Path(sys.argv[1]).is_dir() else str(HOME)
    w=FilesWindow(start);w.connect("destroy",Gtk.main_quit);w.show_all();Gtk.main()
if __name__=="__main__": main()
FILES_PY
write_file "$BIN_ROOT/files" 0755 <<'FILES_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/files.py "$@"
FILES_LAUNCH

# Графические меню: GTK3, без постоянно работающего демона.
write_file "$LIB_ROOT/menu.py" 0644 <<'MENU_PY'
#!/usr/bin/env python3
import os, subprocess
import gi
gi.require_version("Gtk","3.0")
from gi.repository import Gtk,Gdk,GLib
BG="#141a14"; PANEL="#1a211b"; ACCENT="#a9bb7a"; TEXT="#e1e7df"; MUTED="#a0aa9d"
CSS=f"""
window {{ background: rgba(14,19,14,0.84); color:{TEXT}; }}
.panel {{ background: {PANEL}; border: 1px solid #526447; border-radius: 16px; padding: 10px; }}
button {{ background:{PANEL}; color:{TEXT}; border:1px solid #3b4938; border-radius:10px; padding:12px 20px; }}
button:hover, button:focus {{ background:#2b3629; border:1px solid {ACCENT}; }}
label {{ color:{TEXT}; }}
.dim {{ color:{MUTED}; }}
"""
def apply_css():
 p=Gtk.CssProvider();p.load_from_data(CSS.encode());Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(),p,Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
def command(args):
 try:return subprocess.run(args,check=False).returncode==0
 except OSError:return False
class Menu(Gtk.Window):
 def __init__(self,kind):
  super().__init__(title="Power Menu" if kind=="power" else "Профиль питания")
  self.kind=kind;self.set_decorated(False);self.set_modal(True);self.set_position(Gtk.WindowPosition.CENTER)
  visual=self.get_screen().get_rgba_visual()
  if visual:self.set_visual(visual)
  self.fullscreen();self.connect("key-press-event",self.key)
  outer=Gtk.Box(orientation=Gtk.Orientation.VERTICAL);outer.set_halign(Gtk.Align.CENTER);outer.set_valign(Gtk.Align.CENTER)
  self.add(outer)
  box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=10);box.set_margin_top(24);box.set_margin_bottom(24);box.set_margin_start(28);box.set_margin_end(28);box.set_size_request(430,-1);box.get_style_context().add_class("panel");outer.pack_start(box,False,False,0)
  title=Gtk.Label();title.set_markup("<span size='x-large' weight='bold'>"+("Питание" if kind=="power" else "Режим производительности")+"</span>")
  box.pack_start(title,False,False,4)
  if kind=="power":
   opts=[("Выключение","systemctl poweroff"),("Перезагрузка","systemctl reboot"),("Сон","systemctl suspend"),("Выход из Hyprland","hyprctl dispatch hl.dsp.exit()")]
   for label,cmd in opts:
    b=Gtk.Button(label=label);b.connect("clicked",lambda _b,c=cmd:self.act(c));box.pack_start(b,True,True,0)
  else:
   current_run=subprocess.run(["powerprofilesctl","get"],capture_output=True,text=True)
   listed_run=subprocess.run(["powerprofilesctl","list"],capture_output=True,text=True)
   current=current_run.stdout.strip()
   listed=listed_run.stdout if listed_run.returncode==0 else ""
   if listed_run.returncode!=0:
    box.pack_start(Gtk.Label(label="Служба профилей питания недоступна. Проверь power-profiles-daemon и конфликтующие службы.",wrap=True),False,False,6)
   supported=[p for p in ("performance","balanced","power-saver") if p in listed]
   box.pack_start(Gtk.Label(label="Активный профиль: "+(current or "не определён")),False,False,2)
   desc={"performance":"Производительность: повышенная штатная отзывчивость; нагрев и шум могут вырасти.",
         "balanced":"Сбалансированный: повседневная работа и умеренное энергопотребление.",
         "power-saver":"Энергосбережение: ниже энергопотребление; под нагрузкой система может быть медленнее."}
   labels={"performance":"Производительность","balanced":"Сбалансированный","power-saver":"Энергосбережение"}
   for profile in supported:
    b=Gtk.Button(label=labels[profile]+("  ✓" if profile==current else ""));b.set_tooltip_text(desc[profile])
    b.connect("clicked",lambda _b,p=profile:self.set_profile(p));box.pack_start(b,True,True,0)
    info=Gtk.Label(label=desc[profile],wrap=True,xalign=0);info.get_style_context().add_class("dim");box.pack_start(info,False,False,0)
   missing=[p for p in ("performance","balanced","power-saver") if p not in supported]
   if missing:
    box.pack_start(Gtk.Label(label="Не поддерживаются этим оборудованием/драйвером: "+", ".join(missing),wrap=True),False,False,4)
   box.pack_start(Gtk.Label(label="Используется power-profiles-daemon. Недоступные аппаратные функции не имитируются.",wrap=True),False,False,4)
  cancel=Gtk.Button(label="Закрыть");cancel.connect("clicked",lambda *_:self.destroy());box.pack_start(cancel,False,False,4)
 def key(self,_w,e):
  if Gdk.keyval_name(e.keyval)=="Escape":self.destroy();return True
  return False
 def act(self,cmd):
  self.destroy();command(cmd.split())
 def set_profile(self,p):
  if command(["powerprofilesctl","set",p]):
   state=os.path.expanduser("~/.local/state/hypr-minimal");os.makedirs(state,exist_ok=True)
   with open(state+"/power-profile","w") as f:f.write(p+"\n")
   self.destroy()
  else:
   d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.ERROR,buttons=Gtk.ButtonsType.OK,text="Не удалось переключить профиль питания")
   d.format_secondary_text("Профиль не поддерживается или служба power-profiles-daemon недоступна.");d.run();d.destroy()
def main():
 import sys
 apply_css();w=Menu(sys.argv[1] if len(sys.argv)>1 else "power");w.show_all();Gtk.main()
if __name__=="__main__":main()
MENU_PY
write_file "$BIN_ROOT/power-menu" 0755 <<'POWER_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py power
POWER_LAUNCH
write_file "$BIN_ROOT/performance-menu" 0755 <<'PERF_LAUNCH'
#!/usr/bin/env bash
exec /usr/bin/python /usr/local/lib/hypr-minimal/menu.py performance
PERF_LAUNCH

write_file "$BIN_ROOT/hypr-wallpaper-next" 0755 <<'WALL'
#!/usr/bin/env bash
set -Eeuo pipefail
dir="$HOME/Pictures/wall"
mkdir -p "$dir"
mapfile -d '' imgs < <(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 | sort -z)
((${#imgs[@]})) || { notify-send "Обои" "Добавь изображения в ~/Pictures/wall"; exit 0; }
state="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-minimal/wall-index"
mkdir -p "$(dirname "$state")"
i=-1
if [[ -r "$state" ]]; then read -r i < "$state" || i=-1; fi
[[ "$i" =~ ^-?[0-9]+$ ]] || i=-1
if (( i < -1 || i >= ${#imgs[@]} )); then i=-1; fi
i=$(( (i+1) % ${#imgs[@]} ))
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
case "$profile" in performance|balanced|power-saver) powerprofilesctl set "$profile" || true ;; esac
RESTORE

# Запускаем compositor с AQ_DRM_DEVICES до инициализации Aquamarine.
write_file "$BIN_ROOT/start-hyprland-intel" 0755 <<START_INTEL
#!/usr/bin/env bash
set -Eeuo pipefail
export AQ_DRM_DEVICES="$INTEL_DRM_CARD"
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME=pci-0000_00_02_0!
export __GLX_VENDOR_LIBRARY_NAME=mesa
export LIBVA_DRIVER_NAME=iHD
export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
exec /usr/bin/start-hyprland "\$@"
START_INTEL

# Цветовая тема и конфигурация Hyprland.
mkdir -p "$CONFIG_ROOT/hypr" "$CONFIG_ROOT/waybar" "$CONFIG_ROOT/wofi" "$CONFIG_ROOT/gtk-3.0" "$STATE_ROOT" "$TARGET_HOME/Pictures/wall"
write_file "$CONFIG_ROOT/hypr/hyprland.lua" 0644 <<HYPRLUA
-- Hyprland 0.57+: конфигурация на Lua (старый hyprland.conf больше не используется).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("GTK_THEME", "Adwaita-dark")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_STYLE_OVERRIDE", "Fusion")
hl.env("DRI_PRIME", "pci-0000_00_02_0!")
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
        gaps_in = 14,
        gaps_out = 14,
        border_size = 1,
        col = {
            active_border = "rgba(a9bb7aff)",
            inactive_border = "rgba(3b4938cc)",
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
    animations = { enabled = true },
    dwindle = { preserve_split = true },
    misc = {
        disable_hyprland_logo = true,
    },
})

hl.curve("easeOutQuint", {
    type = "bezier",
    points = { { 0.23, 1.0 }, { 0.32, 1.0 } },
})
hl.curve("smooth", {
    type = "bezier",
    points = { { 0.25, 0.1 }, { 0.25, 1.0 } },
})

hl.animation({ leaf = "windows", enabled = true, speed = 2.2, bezier = "easeOutQuint", style = "popin 86%" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.2, bezier = "easeOutQuint", style = "popin 86%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.8, bezier = "smooth", style = "popin 86%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.0, bezier = "smooth" })
hl.animation({ leaf = "fade", enabled = true, speed = 1.8, bezier = "smooth" })
hl.animation({ leaf = "border", enabled = true, speed = 2.0, bezier = "smooth" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.4, bezier = "easeOutQuint", style = "slide" })

local function bind(key, command)
    hl.bind(key, hl.dsp.exec_cmd(command))
end

-- Автозапуск лёгких компонентов.
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE DRI_PRIME VK_LOADER_DRIVERS_SELECT __GLX_VENDOR_LIBRARY_NAME LIBVA_DRIVER_NAME")
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
bind("SUPER + W", "hypr-wallpaper-next")
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + SHIFT + ESCAPE", "power-menu")
bind("SUPER + SHIFT + P", "performance-menu")

bind("XF86AudioRaiseVolume", "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+")
bind("XF86AudioLowerVolume", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
bind("XF86AudioMute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
bind("XF86AudioMicMute", "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
-- Fn+F6/F7/F8: мультимедийные клавиши ноутбука через MPRIS/playerctl.
-- Fn обычно обрабатывается прошивкой и отправляет XF86Audio* без отдельного модификатора.
bind("XF86AudioPrev", "playerctl previous")
bind("XF86AudioPlay", "playerctl play-pause")
bind("XF86AudioNext", "playerctl next")
bind("XF86MonBrightnessUp", "brightnessctl set +5%")
bind("XF86MonBrightnessDown", "brightnessctl set 5%-")

bind("SUPER + SHIFT + S", 'grim -g "\$(slurp)" "\$HOME/Pictures/screenshot-\$(date +%F-%H%M%S).png"')
bind("SUPER + CTRL + C", 'grim -g "\$(slurp)" - | wl-copy')

for i = 1, 5 do
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
  "height": 32,
  "spacing": 4,
  "modules-left": ["custom/launcher", "hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["hyprland/language", "pulseaudio", "backlight", "battery", "custom/performance"],
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
  "clock": {
    "format": "󰥔  {:%H:%M  ·  %a %d %b}",
    "tooltip": true,
    "tooltip-format": "<tt><small>{calendar}</small></tt>",
    "calendar": {
      "mode": "month",
      "mode-mon-col": 3,
      "weeks-pos": "right",
      "on-scroll": 1,
      "format": {
        "months": "<span color='#b5c98a'><b>{}</b></span>",
        "days": "<span color='#e1e7df'>{}</span>",
        "weeks": "<span color='#7d9460'>W{}</span>",
        "weekdays": "<span color='#a9bb7a'><b>{}</b></span>",
        "today": "<span color='#b5c98a'><b><u>{}</u></b></span>"
      }
    },
    "actions": {
      "on-click": "mode",
      "on-click-right": "shift_reset",
      "on-scroll-up": "shift_up",
      "on-scroll-down": "shift_down"
    }
  },
  "hyprland/language": {
    "format": "  {short}",
    "tooltip": true
  },
  "pulseaudio": {
    "format": "{icon}  {volume}%",
    "format-muted": "󰖁  0%",
    "format-icons": {
      "default": ["", "", ""]
    },
    "scroll-step": 5,
    "max-volume": 100,
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
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
WAYBAR
write_file "$CONFIG_ROOT/waybar/style.css" 0644 <<'WAYCSS'
* { font-family: "JetBrainsMono Nerd Font", "Symbols Nerd Font", "DejaVu Sans", sans-serif; font-size: 11.5px; border: none; min-height: 0; }
window#waybar { background: rgba(20, 26, 20, 0.94); color: #e1e7df; border-bottom: 1px solid #3b4938; }
#custom-launcher { color: #a9bb7a; background: transparent; padding: 0 10px 0 12px; margin: 4px 2px; border-radius: 6px; font-size: 13px; }
#custom-launcher:hover { background: #263125; color: #b5c98a; }
#workspaces button { color: #a0aa9d; background: transparent; padding: 0 9px; margin: 4px 2px; border-radius: 6px; transition: all 0.2s ease; }
#workspaces button.active { background: #a9bb7a; color: #141a14; font-weight: 700; }
#workspaces button:hover { background: #263125; color: #e1e7df; }
#workspaces button.urgent { background: #d98b7d; color: #141a14; font-weight: 700; }
#clock { color: #e1e7df; font-size: 13.5px; font-weight: 700; padding: 0 14px; letter-spacing: 0.2px; }
#language, #pulseaudio, #backlight, #battery, #custom-performance { background: #1a211b; color: #e1e7df; border: 1px solid #3b4938; border-radius: 6px; padding: 0 9px; margin: 4px 2px; }
#language { color: #d7dfcf; }
#pulseaudio.muted { color: #a0aa9d; }
#battery.warning { color: #d8b76c; border-color: #6c5d39; }
#battery.critical { color: #d98b7d; border-color: #6e3f38; }
#custom-performance { color: #b5c98a; padding: 0 10px; margin-right: 8px; }
#custom-performance:hover, #language:hover, #pulseaudio:hover, #backlight:hover, #battery:hover { background: #263125; border-color: #526447; }
tooltip { background: #141a14; border: 1px solid #526447; border-radius: 8px; color: #e1e7df; padding: 6px 10px; }
tooltip label { color: #e1e7df; }
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
window { background: #141a14; color: #e1e7df; border: 1px solid #526447; border-radius: 10px; font-family: "DejaVu Sans"; }
#input { background: #1a211b; color: #e1e7df; border: 1px solid #526447; border-radius: 7px; margin: 8px; padding: 8px; }
#entry { padding: 7px; border-radius: 6px; }
#entry:selected { background: #a9bb7a; color: #141a14; border-radius: 6px; }
#text { color: #e1e7df; }
#text:selected { color: #141a14; font-weight: bold; }
WOFICSS
write_file "$CONFIG_ROOT/alacritty/alacritty.toml" 0644 <<'ALACRITTY'
[window]
opacity = 1.0
padding = { x = 10, y = 8 }
decorations = "Full"

[font]
size = 10.5
normal = { family = "DejaVu Sans Mono" }

[colors.primary]
background = "#141a14"
foreground = "#e1e7df"

[colors.cursor]
text = "#141a14"
cursor = "#b5c98a"

[colors.normal]
black = "#1a211b"
red = "#bd766b"
green = "#7d9460"
yellow = "#b7a36a"
blue = "#778b72"
magenta = "#9a829a"
cyan = "#78978f"
white = "#d7dfcf"

[colors.bright]
black = "#526447"
red = "#d28b7f"
green = "#b5c98a"
yellow = "#d1bd82"
blue = "#9aab91"
magenta = "#b29ab2"
cyan = "#9ab9ae"
white = "#e1e7df"
ALACRITTY
write_file "$CONFIG_ROOT/gtk-3.0/settings.ini" 0644 <<'GTK'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
gtk-application-prefer-dark-theme=1
GTK
mkdir -p "$CONFIG_ROOT/qt6ct/colors"
write_file "$CONFIG_ROOT/qt6ct/colors/olive.conf" 0644 <<'QTCOLORS'
[ColorScheme]
active_colors=#ffe1e7df, #ff1a211b, #ff3b4938, #ff526447, #ff0d120d, #ff283328, #ffe1e7df, #fff0f4e9, #ffe1e7df, #ff141a14, #ff141a14, #ff0a0d0a, #ff7d9460, #ff141a14, #ffb5c98a, #ff8ba46b, #ff1a211b, #ffe1e7df, #ff1a211b, #ffe1e7df, #ffa0aa9d, #ffa9bb7a
inactive_colors=#ffe1e7df, #ff1a211b, #ff3b4938, #ff526447, #ff0d120d, #ff283328, #ffe1e7df, #fff0f4e9, #ffe1e7df, #ff141a14, #ff141a14, #ff0a0d0a, #ff526447, #ffe1e7df, #ffa9bb7a, #ff7d9460, #ff1a211b, #ffe1e7df, #ff1a211b, #ffe1e7df, #ffa0aa9d, #ff8ba46b
disabled_colors=#ff7c887a, #ff1a211b, #ff293329, #ff3b4938, #ff0d120d, #ff202820, #ff7c887a, #ffb8c0b5, #ff7c887a, #ff141a14, #ff141a14, #ff0a0d0a, #ff35452f, #ffb8c0b5, #ff75865a, #ff687b58, #ff1a211b, #ff7c887a, #ff1a211b, #ff7c887a, #ff657064, #ff526447
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
background-color=#1a211b
text-color=#e1e7df
border-color=#a9bb7a
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
foreground = '#b5c98a'
gradient = 1
gradient_color_1 = '#526447'
gradient_color_2 = '#7d9460'
gradient_color_3 = '#a9bb7a'
gradient_color_4 = '#b5c98a'
CAVA

# MIME: Files — файловый менеджер; пакетные архивы — безопасный обработчик с подтверждением.
write_file "$TARGET_HOME/.local/share/applications/files.desktop" 0644 <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Files
Exec=/usr/local/bin/files %U
Icon=system-file-manager
Terminal=false
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

# Установка сторонних приложений. GitHub API используется только для выбора официального asset.
write_file "$LIB_ROOT/github-asset.py" 0644 <<'GH'
#!/usr/bin/env python3
import json,re,sys,urllib.request
repo,pattern=sys.argv[1],sys.argv[2]
req=urllib.request.Request("https://api.github.com/repos/"+repo+"/releases?per_page=30",headers={"User-Agent":"hypr-minimal-installer"})
try:
 data=json.load(urllib.request.urlopen(req,timeout=25))
 for rel in data:
  if rel.get("draft") or rel.get("prerelease"): continue
  for a in rel.get("assets",[]):
   if re.search(pattern,a.get("name",""),re.I):
    print(a["browser_download_url"]);print(a.get("digest") or "")
    raise SystemExit(0)
except Exception as e:
 print("GitHub API: "+str(e),file=sys.stderr)
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
    warn "Источник не предоставил SHA-256 для $(basename "$dest"); скачивание защищено TLS, но контрольная сумма не подтверждена."
  fi
  if [[ "$expected" == elf ]]; then
    local magic
    magic="$(od -An -N4 -tx1 "$tmp" | tr -d ' \n')"
    [[ "$magic" == 7f454c46 ]] || { rm -f "$tmp"; warn "Загруженный файл не похож на ELF/AppImage: $url"; return 1; }
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
export DRI_PRIME=pci-0000_00_02_0!
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
  pacman -U --needed -- "$tmp" || { warn "$pkgname: pacman не установил пакет (подписи pacman не отключались)."; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}
log "Дополнительные приложения (каждое устанавливается независимо)"
install_arch_release "Happ-proxy/happ-desktop" '^Happ\.linux\.x64\.pkg\.tar\.zst$' happ || install_appimage "Happ-proxy/happ-desktop" 'Happ.*(x64|x86_64).*\.AppImage$' happ "Happ" "Network;" || true
install_arch_release "storytold/photocraft" 'x86_64.*\.pkg\.tar\.zst$' photocraft || install_appimage "storytold/photocraft" 'x86_64.*\.AppImage$' photocraft "PhotoCraft" "Graphics;" || true
# ONLYOFFICE — официальный сайт разработчика; checksum используется только если опубликована отдельно.
ONLYOFFICE_URL="https://download.onlyoffice.com/install/desktop/editors/linux/DesktopEditors-x86_64.AppImage"
install -d -m 0755 "$APP_ROOT/onlyoffice"
if fetch_file "$ONLYOFFICE_URL" "$APP_ROOT/onlyoffice/onlyoffice.AppImage" "" elf; then
  chmod 0755 "$APP_ROOT/onlyoffice/onlyoffice.AppImage"
  cat > "$BIN_ROOT/onlyoffice" <<EOF
#!/usr/bin/env bash
unset __NV_PRIME_RENDER_OFFLOAD __NV_PRIME_RENDER_OFFLOAD_PROVIDER __VK_LAYER_NV_optimus
export DRI_PRIME=pci-0000_00_02_0! __GLX_VENDOR_LIBRARY_NAME=mesa LIBVA_DRIVER_NAME=iHD
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
else warn "ONLYOFFICE: загрузка с официального сайта не удалась."; fi
install_appimage "SimoHypers/limusic" '(x86_64|amd64).*\.AppImage$' limusic "Limusic" "AudioVideo;Audio;Player;" || true
install_appimage "anomalyco/opencode" 'opencode-desktop-linux-(x86_64|amd64|x64).*\.AppImage$' opencode "OpenCode" "Development;" || true

# Wofi показывает только приложения из пользовательского allowlist.
# Системные desktop-файлы не удаляются: создаются пользовательские NoDisplay overrides.
WOFI_HIDE_DIR="$TARGET_HOME/.local/share/applications"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$WOFI_HIDE_DIR"
python - "$WOFI_HIDE_DIR" "$BACKUP_ROOT" <<'WOFI_CURATE'
import os, re, shutil, sys
from pathlib import Path
user_apps, backup_root = Path(sys.argv[1]), Path(sys.argv[2])
allowed = re.compile(r'firefox|telegram|steam|prism|onlyoffice|happ|photocraft|limusic|opencode|metadata.?cleaner|(^|[^a-z])files([^a-z]|$)|alacritty', re.I)
old_override = '[Desktop Entry]\nType=Application\nName=Служебная запись\nNoDisplay=true\n'

def is_allowed(path, data):
    names = re.findall(r'^(?:Name|Name\[[^]]+\])=(.*)$', data, re.M)
    return bool(allowed.search(path.stem) or any(allowed.search(n) for n in names))

# Include both system locations and user-created desktop files.
all_entries = {}
for directory in (Path('/usr/share/applications'), Path('/usr/local/share/applications'), user_apps):
    if directory.is_dir():
        for src in directory.glob('*.desktop'):
            all_entries.setdefault(src.name, src)
for desktop_id, src in all_entries.items():
    try:
        data = src.read_text(errors='replace')
    except OSError:
        continue
    if not re.search(r'^Type=Application\s*$', data, re.M):
        continue
    dst = user_apps / desktop_id
    # Remove a previously generated override if the desktop entry is now allowed.
    if is_allowed(src, data):
        try:
            if dst.is_file() and not dst.is_symlink() and dst.read_text(errors='replace') == old_override:
                dst.unlink()
        except OSError:
            pass
        continue
    # Already hidden entries (including the package-installer MIME handler) stay intact.
    if re.search(r'^(?:NoDisplay|Hidden)=true\s*$', data, re.M):
        continue
    # Keep an existing custom desktop file in the timestamped backup before hiding it.
    if dst.is_symlink():
        backup = backup_root / str(dst).lstrip('/')
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_text('SYMLINK -> ' + os.readlink(dst) + '\n')
        dst.unlink()
    elif dst.exists() and dst.read_text(errors='replace') != old_override:
        backup = backup_root / str(dst).lstrip('/')
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dst, backup)
    dst.write_text(old_override)
    os.chmod(dst, 0o644)
WOFI_CURATE
chown -R "$TARGET_USER:$TARGET_GROUP" "$WOFI_HIDE_DIR"

# Steam должен использовать Intel ICD, включая 32-битный Vulkan.
# Для приложений в пользовательской сессии экспортируем только выбор Intel, не добавляя PRIME-переключение.
write_file "$CONFIG_ROOT/environment.d/90-intel-gpu.conf" 0644 <<ENV
DRI_PRIME=pci-0000_00_02_0!
__GLX_VENDOR_LIBRARY_NAME=mesa
LIBVA_DRIVER_NAME=iHD
VK_LOADER_DRIVERS_SELECT=*intel_icd*
QT_QPA_PLATFORMTHEME=qt6ct
QT_STYLE_OVERRIDE=Fusion
ENV

# Автозапуск Hyprland только в интерактивной локальной TTY1.
USER_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
case "${USER_SHELL##*/}" in
  bash) PROFILE="$TARGET_HOME/.bash_profile"; PROFILE_KIND=bash ;;
  zsh) PROFILE="$TARGET_HOME/.zprofile"; PROFILE_KIND=zsh ;;
  *) PROFILE=""; PROFILE_KIND=unsupported; warn "Автозапуск TTY1 не добавлен: оболочка $USER_SHELL не поддержана этим блоком. Запускай start-hyprland-intel вручную." ;;
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
  if ! grep -q 'HYPR_MINIMAL_TTY1' "$PROFILE"; then
    backup_file "$PROFILE"
    cat >> "$PROFILE" <<'LOGIN_PROFILE'

# HYPR_MINIMAL_TTY1: запуск только в первой локальной консоли.
if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" && "${XDG_VTNR:-0}" == "1" && -t 0 ]]; then
    export DRI_PRIME=pci-0000_00_02_0!
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    export VK_LOADER_DRIVERS_SELECT="*intel_icd*"
    exec /usr/local/bin/start-hyprland-intel
fi
LOGIN_PROFILE
  fi
fi

# power-profiles-daemon — единственный управляющий профильный сервис.
# Не выключаем сторонние службы без согласия пользователя.
CONFLICTS=()
for svc in tlp.service auto-cpufreq.service tuned.service; do
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
# Включаем пользовательские сокеты PipeWire и WirePlumber без запуска лишних демонов от root.
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

# Записи desktop/MIME и права пользователя.
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-user-dirs-update >/dev/null 2>&1 || true
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default files.desktop inode/directory >/dev/null 2>&1 || true
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" xdg-mime default arch-package-install.desktop application/zstd >/dev/null 2>&1 || true
update-desktop-database "$TARGET_HOME/.local/share/applications" >/dev/null 2>&1 || true
chown "$TARGET_USER:$TARGET_GROUP" "$PROFILE" 2>/dev/null || true
chown -R "$TARGET_USER:$TARGET_GROUP" "$CONFIG_ROOT" "$TARGET_HOME/.local" "$TARGET_HOME/Pictures" 2>/dev/null || true
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.local/state/hypr-minimal" "$TARGET_HOME/Pictures/wall"

# Статическая проверка синтаксиса файлов, которые можно проверить без графической сессии.
log "Проверка созданных файлов"
for f in "$BIN_ROOT/arch-package-install" "$BIN_ROOT/files" "$BIN_ROOT/power-menu" "$BIN_ROOT/performance-menu" "$BIN_ROOT/hypr-wallpaper-next" "$BIN_ROOT/hypr-restore-profile" "$BIN_ROOT/hypr-launcher"; do bash -n "$f"; done
python -m py_compile "$LIB_ROOT/files.py" "$LIB_ROOT/menu.py" "$LIB_ROOT/github-asset.py"
python -m json.tool "$CONFIG_ROOT/waybar/config.jsonc" >/dev/null
# Hyprland --verify-config поддерживается текущими сборками; проверяем, если установленный бинарник это умеет.
if command -v luac >/dev/null 2>&1; then
  luac -p "$CONFIG_ROOT/hypr/hyprland.lua"
else
  warn "luac не найден; Lua-конфигурация не прошла локальную синтаксическую проверку."
fi

# Проверяем наличие дискретного GPU и драйверных пакетов. Ничего не удаляем и не меняем вслепую.
log "Аудит NVIDIA (без удаления драйверов и без опасного отключения PCIe)"
if pacman -Qq 2>/dev/null | grep -Ei '^(nvidia|nvidia-open|nvidia-utils|lib32-nvidia|opencl-nvidia|cuda|bumblebee|optimus-manager)'; then
  warn "Обнаружены NVIDIA/CUDA/Optimus-пакеты. Они не удаляются; выбор GPU для сеанса ограничен Intel."
else
  log "Пакеты NVIDIA/CUDA/Optimus в pacman не обнаружены."
fi
# Останавливаем только фоновые NVIDIA-службы, которые не нужны для Intel-сеанса.
for svc in nvidia-persistenced.service nvidia-powerd.service; do
  if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    systemctl disable --now "$svc" || warn "Не удалось остановить $svc; проверь вручную."
  fi
done
if lsmod | grep -qE '^(nvidia|nouveau)'; then
  warn "Модуль NVIDIA/nouveau уже загружен. Скрипт не выгружает его вслепую; проверь вывод lsmod и перезагрузи после настройки."
fi
if command -v lspci >/dev/null 2>&1; then
  lspci -nnk | grep -A3 -Ei 'VGA compatible controller|3D controller|Display controller' || true
fi
log "Intel UHD подтверждена по PCI vendor ID 0x8086: $INTEL_DRM_CARD → $INTEL_CARD_REAL"
log "AQ_DRM_DEVICES будет установлен до запуска Hyprland; Vulkan loader отфильтрован до Intel ICD (включая 32-битные приложения)"

cat <<EOF

Установка завершена для пользователя $TARGET_USER.

Дальше:
  1. Перезагрузи ноутбук или выйди и войди в TTY1.
  2. Добавь обои в ~/Pictures/wall.
  3. Проверь GPU: lspci -k, glxinfo -B (пакет mesa-utils при необходимости),
     vulkaninfo --summary (пакет vulkan-tools при необходимости).
  4. Проверь профили: powerprofilesctl get и powerprofilesctl list.

Резервные копии: $BACKUP_ROOT
NVIDIA-пакеты не удалялись. Hyprland стартует с AQ_DRM_DEVICES, указывающим только на подтверждённый Intel DRM node; приложения используют Intel PCI ID и Intel Vulkan ICD.
Это программное ограничение, а не аппаратное отключение GTX 1650.
EOF
