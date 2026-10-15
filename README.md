# HK-Tunnel

Turn one SSH server into your own proxy. On Windows it takes over the system
proxy; on Android it takes over the whole device. No root, nothing to install
on the server.

把一台 SSH 服务器变成你自己的代理:Windows 上接管系统代理,Android 上接管全部流量。
两端共用同一台服务器、同一套账号密码,免 root,服务端不需要装任何东西。

## 两个版本

| 目录 | 平台 | 形态 |
|---|---|---|
| [`windows/`](windows/) | Windows 10 / 11 | PowerShell + WinForms,双击即用,可接管系统代理 |
| [`android/`](android/) | Android 8.0+ | 免 root 的 `VpnService` 全局代理,APK 见 [Releases](/seaunit/HK-Tunnel/releases) |

两边都是纯客户端:你只需要一台能 SSH 登录的服务器(任意发行版均可)。

## 下载使用

### Android

1. 到 [Releases](/seaunit/HK-Tunnel/releases) 下载 `app-release.apk`
2. 传到手机上安装(会提示"未知来源",允许即可)
3. 填服务器地址、SSH 端口、登录用户、登录密码,点**连接**
4. 第一次会弹 VPN 授权,同意后状态变绿即全局生效
5. 通知栏和界面里都能断开

不勾「记住密码」时,密码只在这一条连接的生命周期内留在内存里;勾上则用
AndroidKeyStore 加密保存,只有这台设备能解回来。

### Windows

1. 下载本仓库(**Code → Download ZIP**,或 `git clone`)
2. 进入 `windows/`,双击 **`启动隧道.cmd`**
3. 填服务器地址、SSH 端口、登录用户、登录密码,点**启动隧道**

程序只依赖 Windows 自带的 OpenSSH 和 PowerShell 5.1+,没有第三方依赖。
目录里看不到 `hk-askpass.exe` / `hk-httpbridge.exe` 是正常的——它们由脚本在首次运行时
从源码即时编译生成,所以仓库里不放二进制。

自检:

```powershell
powershell -ExecutionPolicy Bypass -File windows\HK-Tunnel.ps1 -SelfTest
```

想让真实联调校验出口 IP 确实是你那台服务器,先设一个环境变量再跑
`-LiveTunnelSelfTest`(不设也能跑,只是改成校验三条路径出口一致):

```powershell
$env:HKTUNNEL_EXPECT_EXIT_IP = '<你的服务器公网 IP>'
```

### 浏览器突然上不了网怎么办

程序是靠**改写 Windows 系统代理**来接管流量的。如果它没能正常还原(比如被任务管理器强杀、
或程序本身启动失败),系统代理就会一直指着**已经关掉的本地桥接**,表现是浏览器打不开任何网页、
并提示"无法连接到代理服务器" —— 网络其实是好的。

一条命令就能救回来:

```powershell
powershell -ExecutionPolicy Bypass -File windows\HK-Tunnel.ps1 -ResetProxy
```

它会结束遗留的桥接进程、还原启动前的代理设置;即使备份文件已经丢失,也会直接把系统代理关掉。

## 原理

```
应用流量 ──► 本地 SOCKS5 ──► SSH 动态转发 ──► 服务器 ──► 外网
                │
   Windows: 系统代理指向本地 HTTP 桥接(把 HTTP 代理转成 SOCKS5)
   Android: VpnService 建 tun 网卡,由 hev-socks5-tunnel 把 IP 包转成 SOCKS5
```

SSH 只负责一条加密长连接,服务器端做域名解析和实际建连,所以你不需要在服务器上
部署任何服务。

细节分别见 [`windows/`](windows/) 与 [`android/README.md`](android/README.md)。

## 已知限制

* **UDP 不过隧道。** SSH 端口转发本身只支持 TCP,这是协议决定的。走 QUIC 或纯 UDP
  的应用(部分视频通话、部分游戏)会回落到 TCP 或直接失败。
* **DNS 处理方式两端不同。** Android 端由内核里的映射 DNS 在本地合成假地址,再把
  原始域名交给服务器解析,查询不会泄漏到本地网络;Windows 端由 SOCKS5 客户端自己
  决定(浏览器通常开 `socks5h://` 走远端解析)。
* **服务端没有 IPv6 出口时**,Android 端会让 IPv6 直接走蜂窝网络而不是隧道,免得
  在隧道里反复失败。给服务器配上可用的 IPv6 后,把它重新收进隧道只需改一行。

## 安全说明

* 仓库**不包含**任何服务器地址、账号、密码或浏览器数据。连接信息保存在本机
  (`%LOCALAPPDATA%\HKTunnel`、Android 应用私有目录),不进版本库。
* 密码不会出现在命令行里:Windows 端通过环境变量交给 `ssh-askpass` 辅助程序,
  Android 端只在进程内存中传递,勾选"记住密码"时才用系统密钥库加密落盘。
* 服务器主机密钥首次连接时记录并固定,之后变更会被拒绝。

## 许可

[MIT](LICENSE)。`android/` 内嵌的 [hev-socks5-tunnel](android/app/src/main/jni/hev-socks5-tunnel)
按其自身 MIT 许可一并分发。
