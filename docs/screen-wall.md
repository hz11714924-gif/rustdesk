# Windows 屏幕墙预览版

基于 RustDesk 1.5.1（上游提交 `23e5bb471a040d62f0a6ad52591fb30784265b73`）。同一个客户端保留控制端与被控端功能，增加本机低频截图上传与屏幕墙。预览不会发起 RustDesk 远控会话；点击卡片才通过原有连接流程发起远控。

## 使用

1. 在改版 Windows x64 客户端打开“屏幕墙 → 设置”。
2. 服务地址默认是 `https://103.236.79.91:21181`，已内置该服务的公有 CA，无需向 Windows 导入证书。
3. 要查看屏幕墙，填写独立的查看令牌。
4. 要让本机出现在屏幕墙，填写本机 RustDesk ID 对应的上传令牌、设备名称，并主动开启“上报本机预览”。
5. 默认每 300 秒采集一次；可设置 30–86400 秒。图片保持长宽比，最大 640×360，JPEG 质量 55，单次上传最多 256 KiB。

服务器与网页共用同一份最新图片。网页每 30 秒检查设备清单，只有图片时间变化才下载图片。网页查看密钥只保存在当前页面内存；刷新后需要重新输入。原监控指标仍然匿名可读。

## 自签 CA

客户端仅为预览 HTTPS 请求添加 `res/screen_wall/preview-ca.pem` 中的公有 CA，仍验证签名、有效期和 URL 的服务器地址，不改变系统信任，也不影响原远控连接。更换预览服务器时可以在设置中更换 CA PEM；留空使用系统证书信任。

浏览器使用自己的证书信任，不会读取客户端内置 CA。要通过浏览器查看屏幕墙，请将 [公有 CA](http://103.236.79.91:21180/preview-ca.cer) 导入访问网页那台电脑的“受信任的根证书颁发机构”，再打开 `https://103.236.79.91:21181`。只在用于查看网页的电脑上需要此操作；所有被控电脑使用改版客户端即可。CA 的 SHA-256 指纹为：

```text
AA:5E:4C:56:69:69:CE:4C:1B:06:57:03:98:3F:0A:72:52:8F:51:1A:A4:6B:A5:5E:D1:4F:D5:E3:C3:04:90:DA
```

服务器根 CA 私钥只保存在服务器上，不在源码或下载包中。客户端包含的只有公有证书。网页 CA 下载地址在完成服务端部署后可用。

本机上传开关默认关闭。关闭上传后不再开始下一次采集；已发出的请求最多等待 15 秒结束。只保留设备的最新一张图片，不存历史。客户端配置用当前 Windows 用户的 DPAPI 加密，存放于 `%APPDATA%\RustDesk\screen-wall\settings.bin`。

## 设备令牌

在监控服务器运行：

```sh
python3 /opt/rustdesk-monitor/preview_admin.py device-token \
  --config /etc/rustdesk-monitor/preview.json --id YOUR_RUSTDESK_ID
python3 /opt/rustdesk-monitor/preview_admin.py viewer-token \
  --config /etc/rustdesk-monitor/preview.json
```

每台设备使用独立上传令牌；不要把服务端 `upload_master` 填入客户端。上传令牌不能读取屏幕墙。设备令牌与 ID 绑定，改变 RustDesk ID 后需重新签发。

## 构建

在有 GitHub Actions 的源码仓库中推送 `feature/screen-wall-win` 分支，或手动运行 **Screen wall Windows x64 preview** 工作流。该工作流只构建 Windows x64，生成原生桥、编译并运行新增 Rust/Dart 测试，上传未签名程序目录和对应源码；不创建 Release，也不发布更新元数据。

下载 `rustdesk-screen-wall-windows-x64-unsigned` 后完整解压目录，再运行其中的 `rustdesk.exe`。不要只复制 EXE，Flutter 运行库和资源也必须保留。分发时同时提供 `rustdesk-screen-wall-corresponding-source` 及原 AGPL 许可。此预览构建未经代码签名。

本地构建需要 Visual Studio C++ 工具链、Rust 1.75、Flutter 3.24.5、LLVM 15.0.6、固定版本 vcpkg 及上游原生依赖，具体步骤以工作流为准。不要在本地运行 Flutter Rust Bridge codegen；工作流负责生成。

## 首版限制与验证状态

- 采集主显示器；锁屏、安全桌面、session 0 或不可用的交互式桌面会返回错误，不尝试绕过。
- 需要交互式 Windows 客户端进程运行；仅后台系统服务运行时不会截图。
- 官方客户端仍通过原有协议远控；官方客户端没有新增的本机上传功能。
- 没有改动 rendezvous、relay、会话、视频编码、远控授权和文件传输协议。与官方客户端的互控仍需用实际构建做双向验证。
- 当前开发机缺少 Windows 编译工具链，尚未生成可执行文件，Rust/Dart 测试尚未执行。不能将源码实现视为已通过实机验证的发行版。

## 现有路径的变更

- `src/lib.rs`：仅注册两个 Windows 专用模块。
- `Cargo.toml`：为已有 Windows WinAPI 依赖启用 DPAPI 功能，用于本地加密配置，不新增依赖。
- `src/flutter_ffi.rs`：现有本地设置读写接口只为 `screen-wall-config` 和 `screen-wall-status` 增加前置处理；其他设置继续使用原逻辑，无新 FFI 签名。
- `flutter/lib/desktop/pages/desktop_tab_page.dart`：Windows 主窗口增加屏幕墙标签及恢复已启用上传的启动钩子；Home 保持初始页。

新增逻辑均位于独立模块，预览关闭时不会截图或上传。
