# wemeet-wayland-screenshare

腾讯会议 **`wemeet-bin 3.26.10.401-5`** 在 **Hyprland + xdg-desktop-portal-hyprland** 下屏幕共享可用的最小组合。
不改 `/opt/wemeet` 任何文件。

## 三条缺一不可

| # | 问题 | 修法 |
|---|---|---|
| 1 | `IsUseXDGDesktopPortal()` 就是 `getenv("WEMEET_XWAYLAND") == "1"`（`libscreen_share_module.so` 0x41fac0）。不设 = 旧 X11 抓屏，抓到空的 XWayland root window → **共享成功但全黑** | 启动器里 `export WEMEET_XWAYLAND=1` |
| 2 | `SelectSources` 之后没等回调就发 `Start`（异步竞态，`Sources not selected`） | `patch.py` Hunk 0，把 `Start` 挪进 `onSelectSourcesResponse` |
| 3 | XDPH 默认给 DMA-BUF，wemeet 只读普通内存 | `xdph.conf` 里 `screencopy { force_shm = true }` |

另外 AUR 启动脚本的 `bwrap --unshare-pid` 会让 portal 认不出客户端，必须去掉（启动器已去掉）。

## 安装

```sh
git clone https://github.com/77-223255/wemeet-wayland-screenshare.git
cd wemeet-wayland-screenshare
./install.sh
```

前置：`wemeet-bin 3.26.10.401-5`、`bubblewrap`、`xdg-desktop-portal-hyprland`。

装完从启动器「腾讯会议」启动，点「共享屏幕」应弹出 Hyprland 的缩略图选屏器。

验证：

```sh
journalctl --user -f -u xdg-desktop-portal-hyprland | grep screencopy
# 点共享后应出现 "[screencopy] New session:"
```

## 不要做的

- **不要**打上游的 `Hunk 1a/1b`（颜色格式欺骗）：XDPH 下会偏色。
- **不要**把 `XDG_SESSION_TYPE` 改成 `wayland` 却仍用 `QT_QPA_PLATFORM=xcb`：会在
  `x_utils::SetWindowInputFocus → XSetInputFocus` 处 SIGSEGV。

## 版本绑定

严格绑定 `wemeet-bin 3.26.10.401-5`，升级后偏移失效，需要重新定位（步骤见 [AGENTS.md](AGENTS.md)）。
建议 `IgnorePkg = wemeet-bin`。

## 致谢

- Hunk 0 偏移：[Matheritasiv/wemeet-screenshare-patch](https://github.com/Matheritasiv/wemeet-screenshare-patch)
- `force_shm` 与 TOCTOU 分析：[GodKeawa/wemeet-bin-wayland-screenshare-fix](https://github.com/GodKeawa/wemeet-bin-wayland-screenshare-fix)
