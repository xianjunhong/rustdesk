# DogShare 账号门禁交付说明

本说明适用于加入自建账号门禁的 Windows DogShare。A（控制/发送端）和 B（被控/字幕接收端）都需要更新到同一代账号版 DogShare，并分别登录有效账号。此前纯字幕版本支持原版 RustDesk 发送端的说明，不适用于本版本的完整账号授权流程。

## 账号与连接

- 客户端内置账号 API 根地址 `https://phenoseed.com/dogshare-account`，不能通过 ID/中继服务器设置更换账号服务。该服务处理账号、设备绑定和连接授权；现有 RustDesk ID/中继服务仍承担发现、穿透与转发。
- 账号仅由管理员在服务器通过 CLI 创建；没有公开注册、找回密码、第三方登录或管理 Web 控制台。不提供或模拟 RustDesk Pro 授权；首版不开放云通讯录和设备组入口。
- 管理员在账号服务目录、使用服务相同数据库配置执行 `python -m dogshare_account_server.admin create <用户名>`。密码通过不回显的交互提示输入，不能写入命令参数或交付文档。完整管理与部署步骤见 [账号服务 README](../dogshare-account-server/README.md)。
- 首次成功登录把客户端声明的 **ID + UUID** 绑定到账号；这不是 TPM、硬件身份或防克隆证明。已有绑定发生冲突时拒绝覆盖，重装或换身份需由管理员核实并解绑。
- 本系统内任意有效账号的已绑定设备可以互连，不限于同一账号。账号授权通过后，仍须满足 B 原有的设备密码或人工批准；账户密码不替代设备连接认证。
- 当前拒绝直接输入 IP 建连。请使用已绑定的设备 ID。账号版的安装后 SYSTEM 服务路径尚未支持；本次交付面向正常 Windows 用户上下文运行的便携版，不应把用户凭据复制给 SYSTEM 服务。

## 登录、退出与失效

现有“账号”页面继续提供登录和退出入口。用户名缓存不构成授权：登录保存凭据后必须成功取得原生服务端授权，才允许发起远控或开启字幕。凭据保存或清除后会读回检查；本地存储失败会提示错误，不能视为成功登录或成功清除凭据。

连接采用短期单次票据。A 向账号服务取得绑定源设备、目标设备和连接类型的票据，B 使用自身会话验证并消费。长期 Bearer 凭据只发给固定 HTTPS 账号服务，不传给对端。普通远控、文件传输、查看摄像头、TCP 转发和终端使用对应连接类型；RDP 映射为 TCP 转发类型。最终设备密码/批准流程仍保留。

原生连接每 30 秒复核授权，单次账号网络请求超时为 8 秒。字幕授权租约最多 75 秒，且不超过账号会话有效期；各 Flutter 进程默认每 30 秒刷新，原生字幕窗口另行检查租约。账号禁用、会话撤销、设备绑定不符、验证失败或租约过期时拒绝继续授权，关闭相应连接或字幕，而不是依赖旧用户名继续使用。网络故障也会影响远控及字幕可用性。

退出先使本进程授权失效、停用字幕并清除本地凭据，再使用退出前保留的令牌向服务端撤销会话；网络撤销失败不会成为保留本地令牌的理由。本进程会立即清除字幕租约并请求关闭出站连接。**其他独立进程和另一台电脑不会全部瞬时退出**：它们通过下一次 30 秒复核以及最多 8 秒的单次网络等待发现失效；不能承诺零延迟全端注销。字幕关闭后不会因后续聊天消息自行重新开启。

Windows 令牌保存到当前用户配置目录中的独立 `DogShare_account.bin`，使用当前 Windows 用户范围的 DPAPI 加密，避免其他进程保存普通偏好时覆盖令牌。旧明文令牌不会自动迁移，本版本首次使用需要重新登录。不同 Windows 用户和 SYSTEM 服务不能直接复用该凭据文件。

## 必要改动与回归范围

| 代码位置 | 改变的运行路径及必要原因 |
| --- | --- |
| `src/dogshare_account.rs`、`src/dogshare_credentials.rs`、`src/lib.rs` | 新增账号授权、票据/复核、字幕租约和 DPAPI 凭据模块，统一原生授权依据。 |
| `src/common.rs`、`src/ui_interface.rs`、`src/flutter_ffi.rs`、`Cargo.toml` | 将账号界面和专用授权接口固定到账号服务，并通过 Windows DPAPI 读写独立凭据；原生 ID/中继、设备信息同步等既有服务仍使用原配置。 |
| `src/client.rs`、`src/server/connection.rs`、`src/ui_session_interface.rs`、`libs/base/protos/message.proto` | 出站获取票据，入站在原有最终批准前验证并定期复核；扩展连接请求携带短期票据，避免仅靠可绕过的界面检查。 |
| `flutter/lib/native/dogshare_account*.dart`、`flutter/lib/models/dogshare_account_gate.dart` | 通过小型原生 ABI 获取真实授权；阻塞刷新放到工作 isolate，管理刷新与退出期间的状态。 |
| `flutter/lib/main.dart`、`flutter/lib/models/user_model.dart`、`flutter/lib/common/hbbs/hbbs.dart`、`flutter/lib/common/widgets/login.dart` | 主窗口、连接管理器和会话进程初始化授权；现有登录/退出衔接凭据核验，取消把缓存用户名当授权。 |
| `flutter/lib/common.dart`、`flutter/lib/models/text_overlay_model.dart`、`flutter/windows/runner/text_overlay_plugin.cpp` | 连接入口提示登录要求；字幕开启、显示和存续检查租约，失效停用模型和原生窗口；关闭始终允许。 |
| `flutter/lib/models/peer_tab_model.dart`、`ab_model.dart`、`group_model.dart`、`flutter/lib/common/widgets/peer_tab_page.dart` | 隐藏未实现的云功能入口并停止对应请求，避免登录成功后出现不支持的接口错误。 |
| `flutter/lib/mobile/widgets/dialog.dart`、`flutter/lib/desktop/pages/desktop_setting_page.dart` | 共用服务器设置隐藏账号 API 编辑；账户页面呈现授权失败和重新登录入口。 |
| `src/lang/*.rs` | 只追加新提示键；中文填写对应译文，其余语言留空回退英文，不修改原有翻译。 |

字幕内容、纯文字透明背景、位置及宽高设置仍沿用此前实现。Windows 捕获测试版仅对文字浮窗请求捕获排除；主窗口可照常录制。是否跳过浮窗取决于系统版本和录屏采集方式。

## 验证与已知边界

账号相关 Flutter 回归与既有字幕检查合计 10 项已通过，新账号文件静态分析无错误。较宽范围静态分析中的既有弃用和未使用代码警告没有顺手清理；例如 `common.dart` 的 `dart:math` 导入及设置页 `_LabeledTextField` 在原始 HEAD 已存在且未使用。这些结果不替代双机运行和线上接口验收。

账号服务已部署到 `/opt/dogshare-account`，通过 `phenoseed.com` 的既有 HTTPS 证书提供接口。9 项本地 API 测试及 15 项线上 HTTPS 检查通过，覆盖登录、设备绑定、未绑定目标拒绝、票据消费与防重放、退出撤销。线上验证用的临时绑定已清理，原网站与其他容器继续运行。

## 双机验收

1. A、B 退出托盘里的旧 DogShare，各自运行新版便携 `DogShare.exe`。在“设置 → 账号”登录管理员创建的账号，首次登录会分别绑定设备。同一内测账号可绑定多台设备。
2. A 输入 B 的设备 ID 发起连接。B 按原设置点“接受”或使用设备密码完成认证。
3. 在 B 的该会话聊天面板开启文字悬浮窗；A 发送一句聊天，核对 B 收到聊天并显示字幕。随后关闭字幕，下一条消息应留在正常聊天，不应重新打开字幕。
4. 退出 A 的账号，确认当前远控断开且不能新建连接。退出 B 的账号，确认字幕关闭、B 不再接受需要账号授权的连接。

线上 API 检查不等同于上述两台电脑的客户端联机验收。

升级前保存旧版本和必要配置备份。**旧版 RustDesk、旧版 DogShare 不受新账号服务约束；回滚旧客户端会解除该客户端新增的强制账号门禁。** 账号服务本身不能强制限制未包含门禁的旧程序，也不构成对任意修改版客户端或客户端声明身份的硬件可信证明。
