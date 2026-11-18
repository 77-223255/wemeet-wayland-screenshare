#!/bin/sh
# Install the Wemeet Wayland screen-share fix for the current user.
# Nothing under /opt/wemeet is modified; no root required.
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_VERSION=3.26.10.401

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. check prerequisites ───────────────────────────────────────────────────
command -v pacman >/dev/null || die "this installer targets Arch (pacman)"
command -v bwrap >/dev/null || die "缺少 bubblewrap：sudo pacman -S bubblewrap"
command -v python3 >/dev/null || die "缺少 python3"

[ -x /opt/wemeet/bin/wemeetapp ] || die "未安装 wemeet-bin：yay -S wemeet-bin"

ver=$(pacman -Q wemeet-bin 2>/dev/null | awk '{print $2}' || true)
case "${ver:-}" in
    ${PKG_VERSION}-*) say "wemeet-bin ${ver} ✓" ;;
    *) die "wemeet-bin 版本为 ${ver:-未知}，本补丁只针对 ${PKG_VERSION}-5" ;;
esac

MODULE=/opt/wemeet/bin/modules/screen_share/libscreen_share_module.so
FIX_DIR="$HOME/.local/lib/wemeet-fix"
FIX_LIB="$FIX_DIR/libscreen_share_module.so"

# ── 2. build the patched screen-share module (Hunk 0 only) ───────────────────
say ""
say "==> 生成补丁模块 $FIX_LIB"
mkdir -p "$FIX_DIR"
cp "$MODULE" "$FIX_LIB"
# patch the copy, not the installed file
python3 - "$FIX_LIB" "$REPO_DIR/patch.py" <<'PY'
import importlib.util, sys
lib, patcher = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wp", patcher)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.exit(m.patch_file(lib))
PY

# ── 3. launcher + desktop entry ──────────────────────────────────────────────
say ""
say "==> 安装启动器 ~/.local/bin/wemeet-wayland"
install -Dm755 "$REPO_DIR/launcher/wemeet-wayland" "$HOME/.local/bin/wemeet-wayland"

say "==> 覆盖桌面项 ~/.local/share/applications/wemeetapp.desktop"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/wemeetapp.desktop" <<EOF
[Desktop Entry]
Name=WemeetApp
Name[zh_CN]=腾讯会议
Exec=$HOME/.local/bin/wemeet-wayland %u
Icon=wemeet
Type=Application
Terminal=false
Categories=AudioVideo;
Comment=Tencent Meeting Linux Client
Comment[zh_CN]=腾讯会议Linux客户端
Keywords=wemeet;tencent;meeting;
MimeType=x-scheme-handler/wemeet;
EOF
command -v update-desktop-database >/dev/null && \
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

# ── 4. xdg-desktop-portal-hyprland: force SHM instead of DMA-BUF ─────────────
XDPH_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/xdph.conf"
say ""
say "==> 配置 $XDPH_CONF （screencopy.force_shm）"
mkdir -p "$(dirname "$XDPH_CONF")"
if [ ! -f "$XDPH_CONF" ]; then
    cat > "$XDPH_CONF" <<'EOF'
screencopy {
    force_shm = true          # 腾讯会议只支持普通内存(SHM)
}
EOF
elif grep -q 'force_shm' "$XDPH_CONF"; then
    say "    已存在 force_shm，跳过"
elif grep -q '^[[:space:]]*screencopy[[:space:]]*{' "$XDPH_CONF"; then
    tmp="$XDPH_CONF.tmp.$$"
    sed '0,/^[[:space:]]*screencopy[[:space:]]*{/s//screencopy {\n    force_shm = true          # 腾讯会议只支持普通内存(SHM)/' \
        "$XDPH_CONF" > "$tmp" && mv "$tmp" "$XDPH_CONF"
else
    printf '\nscreencopy {\n    force_shm = true          # 腾讯会议只支持普通内存(SHM)\n}\n' >> "$XDPH_CONF"
fi

# ── 5. restart the portal so the config takes effect ─────────────────────────
if systemctl --user is-active --quiet xdg-desktop-portal-hyprland.service 2>/dev/null; then
    say "==> 重启 xdg-desktop-portal-hyprland"
    systemctl --user restart xdg-desktop-portal-hyprland.service 2>/dev/null || \
        say "    重启失败，请手动重启 portal"
fi

# ── 6. done ──────────────────────────────────────────────────────────────────
cat <<EOF

完成。从启动器「腾讯会议」启动即可（等价于 $HOME/.local/bin/wemeet-wayland）。

验证共享是否真的走了 portal：
  journalctl --user -f -u xdg-desktop-portal-hyprland | grep screencopy
  # 点共享后应出现 "[screencopy] New session:"

可选（推荐）：把补丁版本钉住，避免更新覆盖后偏移失效
  echo 'IgnorePkg = wemeet-bin' 追加到 /etc/pacman.conf 的 [options] 段

已知限制见 README.md，升级后需要重新定位偏移见 AGENTS.md。
EOF
