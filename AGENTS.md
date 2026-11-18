# AGENTS.md

给在本仓库上工作的 agent 的事实清单。**先读本文，再动手。**

## 0. 一句话

腾讯会议 `wemeet-bin 3.26.10.401-5` 在 Hyprland 下共享黑屏，只有三个原因：没设
`WEMEET_XWAYLAND=1`（不走 portal）、`SelectSources/Start` 竞态（Hunk 0）、XDPH 给
DMA-BUF（`force_shm`）。三者都已修，且都经过实测。

## 1. 已验证环境

```
Arch Linux / Omarchy 4.0.0        Hyprland 0.57.2
wemeet-bin 3.26.10.401-5          xdg-desktop-portal 1.22.1
xdg-desktop-portal-hyprland 1.5.0 pipewire 1.6.11 / wireplumber 0.5.19
bubblewrap, hyprland-preview-share-picker
```

只验证了 **XDPH** 后端。GNOME/KDE/wlr 后端未验证，不要照搬结论。

## 2. 关键事实（含反汇编依据）

### 2.1 `WEMEET_XWAYLAND=1` 是「走 portal」的开关，不是「关闭 portal」

`bin/modules/screen_share/libscreen_share_module.so` 里 `IsUseXDGDesktopPortal()`
（`0x41fac0`，日志里会打印函数名与 `get xwayland env:` 值）：

```asm
41facb: lea    0x505b5e(%rip),%rdi   # "WEMEET_XWAYLAND"
41fad2: call   getenv@plt
41fdfb: lea    0x4f9b03(%rip),%rsi   # "1"
41fe06: call   operator==(std::string, const char*)
41fe32: ret                          # return env == "1"
```

- 设为 `1` → portal 路径（`ext_portal` 设备，PipeWire 流）。
- 不设 / 设 `0` → 旧 X11 `XShmGetImage` 路径，在 Hyprland 下抓到**空的 XWayland root
  window**，现象是「共享确实开始了，但画面全黑」。

上游 Matheritasiv 仓库的 PR #6 文档写反了（说 `=1` 关闭 portal），已实测推翻。

### 2.2 `bwrap --unshare-pid` 必须去掉

AUR `/usr/bin/wemeet` 用 bwrap 包了一层并带 `--unshare-pid`。PID namespace 隔离后
`xdg-desktop-portal` 无法通过 `GetConnectionUnixProcessID` 反查客户端凭据，表现是
「点共享屏幕没有任何反应」。启动器已去掉该参数（`--unshare-user-try` 保留即可）。

### 2.3 `force_shm` 必须开

Hyprland/XDPH 默认用 GPU 零拷贝 DMA-BUF 分发帧；wemeet 只会读普通内存（SHM），
否则协商成功但帧不可读 → 黑屏。`~/.config/hypr/xdph.conf`：

```ini
screencopy {
    force_shm = true
}
```

### 2.4 Hunk 1a/1b 不要打

上游 `patch.py` 的 Hunk 1a/1b 把硬编码的 `BGRx(8)` 篡改成 `RGBx(7)` 并劫持拷贝路径
（需要 `libhook.so`）。在 XDPH + `force_shm` 下不需要，打了会偏色；在 GNOME/Mutter
下更会直接导致协商失败、白屏（上游 issue #2）。本仓库只保留 Hunk 0。

### 2.5 界面必须保持 X11，但不能「假 wayland」

`XDG_SESSION_TYPE=wayland` + `QT_QPA_PLATFORM=xcb` 会在进会议时崩：

```
#3 XSetInputFocus
#4 x_utils::SetWindowInputFocus(QWidget*)
#5 WMQtUiUtil::ShowWindow
```

所以启动器保持：`XDG_SESSION_TYPE=x11`、`unset WAYLAND_DISPLAY`、
`QT_QPA_PLATFORM=xcb`，只让**采集**走 portal。

## 3. 仓库约定（不变量）

1. **绝不修改 `/opt/wemeet` 下的文件**。补丁模块只在 bwrap 的 mount namespace 内
   以 `--ro-bind` 覆盖（`launcher/wemeet-wayland` 已这么做）。
2. 不提交二进制产物（`*.so`、AUR 包、`~/.cache` 内容）。补丁以「偏移 + 字节」形式
   存在于 `patch.py`。
3. `patch.py` 只允许包含与 `3.26.10.401-5` 对应的偏移；换版本时更新
   `PKG_VERSION`/偏移，而不是加兼容分支去猜。
4. 安装脚本只用用户级路径（`~/.local/*`、`~/.config/*`），除可选的 `IgnorePkg`
   外不需要 root。
5. README 保持极简；细节写本文件。

## 4. 文件布局

```
patch.py                     Hunk 0（Start 挪进 onSelectSourcesResponse）
launcher/wemeet-wayland      启动器：去 --unshare-pid、WEMEET_XWAYLAND=1、ro-bind 补丁模块
install.sh                   生成补丁模块 + 装启动器/桌面项 + 写 xdph.conf（幂等）
xdph.conf.example            force_shm 参考片段
```

安装后的落地位置：

```
~/.local/lib/wemeet-fix/libscreen_share_module.so   打过 Hunk 0 的模块
~/.local/bin/wemeet-wayland                         启动器
~/.local/share/applications/wemeetapp.desktop       覆盖系统同名桌面项
~/.config/hypr/xdph.conf                            screencopy.force_shm
```

## 5. 诊断流程（从「黑屏」到「定位」只需三步）

1. **portal 被调了吗？**

   ```sh
   systemctl --user stop xdg-desktop-portal-hyprland
   /usr/lib/xdg-desktop-portal-hyprland -v > /tmp/xdph.log 2>&1 &
   dbus-monitor --session "interface='org.freedesktop.portal.ScreenCast'" > /tmp/bus.log 2>&1 &
   ```

   点共享后：`/tmp/bus.log` 应有 `CreateSession/SelectSources/Start/OpenPipeWireRemote`；
   `/tmp/xdph.log` 应有 `[screencopy] New session:`。**两处都空 = 根本没走 portal**，
   去查 `WEMEET_XWAYLAND`（2.1）。

2. **走的是哪条采集路径？** 看 `~/.local/share/wemeetapp/Saas/Logs/xcast_*.log`：

   - `window_capturer.cc:... Window with wid(...) is the root window` +
     `screen_capture_linux.cc:... capture.screen.id.*` → **X11 回退**（黑屏）。
   - `xc_device.c:... DVC|'ext_portal' type 1 state 1` + 无 X11 root 抓屏 → portal 正常。

3. **帧格式对不对？** `force_shm` 缺失时 XDPH 走 DMA-BUF，`pw-dump` 里能看到流的
   类型；`/tmp/xdph.log` 详细级别下能看到 screencopy buffer 相关信息。

`journalctl -b | grep -c screencopy` 在整次开机里只有 init 两行 = 从没建过会话。

## 6. 版本升级后怎么重新定位偏移

1. `strings -t x libscreen_share_module.so | grep WEMEET_XWAYLAND` 拿到字符串偏移，
   再在 `objdump -d` 输出里 `grep "# <offset> "` 找到唯一 `lea` 引用，那里就是
   `IsUseXDGDesktopPortal` 的 `getenv` 调用点；确认后面比较的字面量是 `"1"`。
2. Hunk 0 的五个站点按字节特征在新二进制里搜（保持顺序与相对距离）：

   ```
   00             (0x43d2fa)   ⇐ dbusSelectSources 里的条件跳转
   88f7           (0x43d331)
   83c718488b8588f7ffff48 (0x43d336)
   0000           (0x43d357)
   e8c305d9       (0x43dc38)   ⇐ call dbusStart
   ```

   更稳的做法：反汇编 `onSelectSourcesResponse`，找到它末尾没有 `dbusStart` 调用、
   而 `dbusSelectSources` 里有——把调用搬到回调里，重算 5 处跳转/立即数。
3. 改完用 `python3 patch.py /opt/wemeet --dry-run` 验证，再跑 `install.sh`，
   最后按第 5 节验证真实共享（要有人在对端看到画面，不看本地预览）。

## 7. 已知限制

- 结束共享的悬浮工具栏在 Hyprland 上可能被透明 overlay 盖住点不到（WM 相关，
  与本补丁无关）。
- 上游提到的 TOCTOU 崩溃（高负载/高分辨率时 portal 回收 SHM buffer 导致 SIGSEGV）
  本仓库**未**处理；若复现，参考 `GodKeawa/wemeet-bin-wayland-screenshare-fix`
  的 `libhook` 方案。
- 只支持 XDPH；其他 portal 后端需要各自验证 `Hunk 1a/1b` 与 `force_shm` 的取舍。
