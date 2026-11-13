# DogShare Windows x64 构建

本分支包含当前 DogShare 客户端、账号服务和构建脚本。客户端基于 RustDesk，保留原许可证及上游来源。源码目录即仓库根目录，构建入口位于 `打包/`，配套脚本位于 `dogshare-tools/`。

## 本次整理的验证边界

此次整理只迁移源码和脚本、检查路径及语法，不会安装依赖、重新编译完整应用或验证双端远程会话。以下依赖清单来自已有构建环境；独立新机器从零构建仍需实际验收。

## 已知依赖版本

| 组件 | 已有构建环境记录 |
| --- | --- |
| Rust | 1.75.0，`x86_64-pc-windows-msvc` |
| Flutter / Dart | 3.24.5 / 3.5.4 |
| Visual Studio C++ Build Tools | VS 2022 17.14.44，MSVC 19.44.35229 |
| Windows SDK | 10.0.22621.0 |
| LLVM / CMake | 15.0.6 / 4.3.0 |
| PowerShell | 7 |
| Python | Python 3，需安装 `brotli`；账号服务依赖见其目录 |

`dogshare-tools/native-environment.json` 是版本参考，明确标记 `reference_only`，不表示当前机器已经通过编译检查。

## 路径与配置

脚本不要求 D 盘别名或特定 Windows 用户名，不内置代理设置。需要代理时自行设置 `HTTPS_PROXY`、`HTTP_PROXY` 或 `CARGO_HTTP_PROXY`。

| 变量 | 默认值 / 用途 |
| --- | --- |
| `DOGSHARE_REPO` | 仓库根目录；通常无需设置 |
| `DOGSHARE_TOOLS` | 仓库内 `dogshare-tools`；保存随源码发布的脚本 |
| `DOGSHARE_PYTHON` | PATH 中的 `python.exe` |
| `DOGSHARE_SDK_ROOT` | 默认 `dogshare-tools`；可指向单独的 SDK/缓存目录 |
| `DOGSHARE_VCVARS64` | 可指定 `vcvars64.bat`；默认通过已安装 VS 或 `vswhere.exe` 查找 |
| `DOGSHARE_ASSETS` | 默认 `dogshare-tools/bridge-assets`；可指向已准备的官方辅助文件目录 |
| `CARGO_HOME` / `RUSTUP_HOME` | 未设置时使用 SDK 根下的 `cargo` / `rustup` |
| `VCPKG_ROOT` / `LIBCLANG_PATH` | 未设置时使用 SDK 根下的 `vcpkg` / `llvm-15.0.6/bin` |
| `FLUTTER_ROOT` / `PUB_CACHE` | 未设置时使用 SDK 根下的 `flutter` / `pub-cache` |

例如复用另一目录中已经安装的 SDK，保持本仓库脚本路径不变：

```powershell
$env:DOGSHARE_SDK_ROOT = 'C:\DogShareSdk'
$env:DOGSHARE_PYTHON = (Get-Command python.exe).Source
```

SDK 根目录的默认布局：`cargo/bin`、`rustup`、`flutter/bin`、`vcpkg/installed`、`llvm-15.0.6/bin`、`cmake-4.3.0-windows-x86_64/bin`、`pub-cache`。已有系统安装也可通过上表对应环境变量配置。脚本只设置当前进程环境，不修改全局 PATH 或 Git 信任设置。

## 首次准备依赖

1. 安装上述 PowerShell、Python、VS C++ x64 工具及 Windows SDK，按记录版本安装 Rust、Flutter、LLVM、CMake、vcpkg。vcpkg 版本和依赖配置以仓库 `.github/workflows/flutter-build.yml`、`vcpkg.json` 为依据；本次整理未替换这些配置。
2. 在仓库根目录运行 `git submodule update --init --recursive`，取得固定提交的 `libs/hbb_common`。
3. 在网络可用时安装 Python `brotli`、准备 vcpkg 的 `x64-windows-static` 依赖、Cargo 锁定依赖和 Flutter Pub 依赖。正式打包入口保持 `--offline` / `--no-pub`，不会自动填充缺少的缓存。

```powershell
python -m pip install brotli
. .\dogshare-tools\dogshare-env.ps1
& "$env:VCPKG_ROOT\bootstrap-vcpkg.bat" -disableMetrics
& "$env:VCPKG_ROOT\vcpkg.exe" install --triplet x64-windows-static --x-install-root="$env:VCPKG_INSTALLED_ROOT" --disable-metrics
& .\dogshare-tools\cargo-task.ps1 fetch --locked
Push-Location .\flutter
try { & ..\dogshare-tools\run-flutter.ps1 pub get } finally { Pop-Location }
```

如当前 PowerShell 已有 `CARGO_NET_OFFLINE=true`，先清除该进程变量再做首次 `cargo fetch`。不要把本机 `.env`、账号库、密钥或导出的账号清单纳入 Git。

## 桥接源码与官方辅助文件

当前桥接源码已随分支保存，摘要与 `dogshare-tools/bridge-assets/bridge-provenance.json` 一致：

- `src/bridge_generated.rs`、`src/bridge_generated.io.rs`
- `flutter/lib/generated_bridge.dart`、`flutter/lib/generated_bridge.freezed.dart`
- `flutter/ios/Runner/bridge_generated.h`、`flutter/macos/Runner/bridge_generated.h`

保留这些文件；不要运行其他版本的桥接生成器覆盖它们。其来源为 RustDesk 提交 `55786aaa5709ac0a450aabcf06f9d1fee3119908` 的官方构建记录，运行 ID `41745328480`。

Git 中只保存辅助文件的来源和摘要，不包含其 ZIP、DLL、PDB 或下载分片：

- `artifacts.json`：WindowInjection 官方构建 artifact ID 与 SHA256。
- `custom-engine-asset.json`：RustDesk 自定义 Flutter release engine 的下载位置、长度与本地已有归档 SHA256。原上游元数据未提供 digest，该摘要记录了本次构建所用归档。
- `bridge-provenance.json`：官方桥接文件来源与摘要。

WindowInjection 可从对应官方构建 artifact 或以下交付地址取得。下载后必须校验 SHA256，再解压至 `bridge-assets/topmostwindow-artifacts-x64/`，使其中包含 `WindowInjection.dll`：

```powershell
$assets = Join-Path $PWD 'dogshare-tools\bridge-assets'
python .\dogshare-tools\download_asset.py 'https://nightly.link/rustdesk/rustdesk/actions/runs/41745328480/topmostwindow-artifacts-x64.zip' "$assets\topmostwindow-artifacts-x64.zip" --sha256 cc8da669ec28ecf6b1781e73391dcf93c03bb1f352321f16f40d7ac31d362ff7
Expand-Archive -LiteralPath "$assets\topmostwindow-artifacts-x64.zip" -DestinationPath "$assets\topmostwindow-artifacts-x64"
python .\dogshare-tools\download_custom_engine.py
```

官方 Actions artifact 可能过期；如下载地址失效，需从可信留存副本恢复匹配摘要的文件，或另行更新来源、重新构建并验收。脚本不会因下载失败而忽略哈希校验。

自定义 engine 会解压到 `bridge-assets/custom-engine/`。先让 Flutter 下载标准 Windows artifacts，再将该目录的文件复制到所选 Flutter SDK 的 `bin/cache/artifacts/engine/windows-x64-release/`。已有工作环境使用了此替换。不要只复制 DLL 而遗漏匹配的头文件、导入库和 snapshot 工具。随后重新执行 Flutter Windows release 构建。

## 构建入口

在 `打包` 目录双击或从命令行运行：

```text
1-仅编译Rust后端.cmd --check --no-pause
1-仅编译Rust后端.cmd --no-pause
2-打包B端.cmd --no-pause
3-打包A端.cmd --no-pause
```

`--check` 仅验证入口与文件路径，不验证编译器、SDK、联网、依赖完整性或运行效果。完整构建会加载 MSVC 环境、按角色构建后端、运行指定 Flutter 测试、构建界面并打包，最后校验角色和便携文件内容。后端缓存使用源码及工具摘要匹配，不复用不匹配的角色或旧输入。

输出位于 `打包/输出`，日志位于 `打包/日志`，后端缓存位于 `打包/Rust后端`，均不进入 Git。打包结果仍需 A/B 两端连接、字幕、账号切换及窗口行为验收。

## 账号服务

服务端源码、配置示例和测试位于 `dogshare-account-server/`。配置及部署方式见该目录的 README。只保留 `.env.example`；真实环境文件、数据库、账号导出和管理员凭据不随源码发布。
