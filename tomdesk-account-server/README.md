# TomDesk 配对账号服务

独立 Python 3.11 服务，管理员批量生成配对账号，没有公开注册或默认账号；[网页管理后台](WEB_ADMIN.md)默认关闭。每组固定包含一个控制端账号 `controller`（A）和一个被控端账号 `receiver`（B）。A 只能远程控制同组 B，B 无法发起连接；每个配对账号成功登录后只保留最新会话，换设备登录不需要管理员解绑。连接权限由服务端关系、角色、会话和单次票据共同决定。

新生成的配对默认限时 24 小时，从新版 A 首次成功显示 B 的远控画面并上报后开始。已有配对保留不限时规则。详见[网页管理后台](WEB_ADMIN.md)。

新版客户端 API 根地址为 `https://phenoseed.com/tomdesk-paired-account`。部署使用独立 Compose 项目 `tomdesk-paired-account`、独立数据卷和宿主回环端口 8092，保留已有 `/tomdesk-account` 服务、账号和数据库。本目录提供代码和模板，不会自行操作服务器或创建生产账号。管理员标记仅是用户资料，不表示 RustDesk Pro 授权。

## 本地运行与测试

在本目录建立隔离环境，安装固定依赖：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -c constraints.txt -r requirements.txt
$env:TOMDESK_ACCOUNT_DB = "$PWD\data\accounts.sqlite3"
.\.venv\Scripts\python.exe -m tomdesk_account_server
```

默认监听 `http://127.0.0.1:8091`；`GET /health` 返回 `{"status":"ok"}`。Python 入口不会自动读取 `.env`，需设置进程环境。没有默认账号；批量生成配对账号请使用下文 Linux Docker CLI。

```powershell
.\.venv\Scripts\python.exe -m pip install -c constraints.txt -r requirements-dev.txt
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

API 测试使用临时 SQLite 文件，不创建生产账号。Windows 会明确跳过要求 POSIX 0600 文件权限的批量导出测试；该项需在 Linux 环境运行。测试覆盖配对、角色、旧客户端拒绝绕过、单设备绑定、票据重放/过期、会话撤销和旧数据库迁移。

## 独立 Docker 部署模板

在本目录执行，确保与旧服务使用不同项目名和宿主端口：

```sh
export TOMDESK_ACCOUNT_PUBLISH_PORT=8092
docker compose -p tomdesk-paired-account build
docker compose -p tomdesk-paired-account up -d
docker compose -p tomdesk-paired-account exec accounts python -m tomdesk_account_server.admin create-pairs --count 10 --output /data/batch-001.csv
docker compose -p tomdesk-paired-account exec accounts python -m tomdesk_account_server.admin pairs
```

`create-pairs` 一次创建 1–1000 组。新配对编号、A/B 用户名和随机密码都是 8 位字母数字。生成的密码保存于指定的新 CSV 和数据库的独立凭据表，仅登录后的网页后台可查看，不在终端、参数或日志中输出。路径必须绝对路径，文件不得已存在。容器根文件系统只读，因此示例输出到可写的 `/data`。CSV 表头固定为：

```text
pair_id,controller_username,controller_password,receiver_username,receiver_password
```

批量导出只在 Linux/POSIX 环境执行，以独占创建和 0600 权限保护凭据；Windows 的 chmod 不能提供等价 NTFS 访问控制，因此不会在那里生成明文批量文件。管理员应通过安全渠道分别交付 A/B 凭据，保管或删除已交付的明文导出，不要将其打印到共享日志、放入 Git 或发送到公开位置。

密码先在数据库事务外计算哈希，再在一个事务内写入整批配对和账号。CSV 写入并同步磁盘后提交数据库，提交成功后才保留导出标记；普通异常会回滚数据库并删除未完成导出。不承诺文件系统与数据库间的崩溃原子性；若进程被强制终止，先核对该批文件及 `pairs`，不要覆盖文件或直接重复发放。

Compose 只发布 `127.0.0.1:${TOMDESK_ACCOUNT_PUBLISH_PORT:-8091}:8091`。本方案显式使用 8092，容器内始终监听 8091；若复制 `.env.example`，其中也给出 8092。不要把新项目连到旧数据卷。数据库位于项目独立命名卷的 `/data/accounts.sqlite3`，容器 UID/GID 为 10001，根文件系统只读，去除 capabilities，启用 no-new-privileges 和内存/进程/日志限额。Dockerfile 固定基础镜像摘要，并用 `constraints.txt` 固定生产依赖。复用卷前需核实所有权和备份。

## 管理配对、账号和设备

所有命令需连接本服务相同数据库，在服务器本机执行；Docker 中加上 `docker compose -p tomdesk-paired-account exec accounts` 前缀：

```text
python -m tomdesk_account_server.admin pairs
python -m tomdesk_account_server.admin logout-pair PAIR_ID
python -m tomdesk_account_server.admin disable-pair PAIR_ID
python -m tomdesk_account_server.admin list
python -m tomdesk_account_server.admin devices
python -m tomdesk_account_server.admin unbind 100000001
python -m tomdesk_account_server.admin set-password ACCOUNT_NAME
python -m tomdesk_account_server.admin disable ACCOUNT_NAME
```

`pairs` 和 `list` 不显示密码或哈希。整组 `logout-pair` 撤销双方全部会话和票据，账号仍可重新登录；`disable-pair` 另外禁止双方重新登录，包括旧客户端。服务端撤销立即生效，客户端在下一次原生授权状态检查时断开，正常检查间隔为 30 秒。

设备 `id + uuid` 用于路由和审计，配对关系和有效会话决定授权。每个配对账号登录成功时撤销该账号先前的会话及相关票据，同一设备重新登录也适用。同一 Windows 用户可关闭原程序后顺序切换 A/B：新版在登录请求中可选携带本机上次登录的 Bearer，服务端先验证新账号密码、角色和配对，再用同设备的有效旧会话授权切换。缺少匹配的旧会话且设备仍有其他账号的有效登录时返回 HTTP 409 `device_bound`；可以用原客户端登出，或请管理员踢掉原端的会话后重试。旧会话已过期也可直接切换。未配对的旧账号继续使用原绑定规则。

单账号禁用、改密会撤销该账号全部会话及相关连接票据；改密不会恢复禁用账号。配对账号退出会释放该设备并撤销其全部会话和票据；未配对账号退出只撤销当前会话及依赖它的连接授权。当前 CLI 不提供恢复禁用配对、删除配对或迁移已有账号到配对的命令。配对内角色固定，`set-role` 修改会返回 `paired_role_locked`；停用后仍保持固定，需创建新组。

兼容管理命令 `create ACCOUNT_NAME --role controller|receiver` 创建未配对账号，默认 receiver，密码通过不回显的交互式提示输入两次（12–1024 个字符）。`set-role ACCOUNT_NAME ROLE` 只允许改未配对账号，实际改变角色时撤销其会话。未配对账号不具备连接权限，不能用于新版 A/B 客户端。账号名支持 3–64 个字母、数字或 `._@-`，登录匹配不区分大小写。

## HTTP 接口

请求和响应为 JSON。认证接口使用 `Authorization: Bearer <access_token>`，并发送本机 `id` 与 `uuid`。响应带 `Cache-Control: no-store`；错误统一为 `{"error":"可读信息","code":"稳定错误码"}`，使用对应 HTTP 状态码，不回显密码或令牌。

| 方法与路径 | 请求 | 成功响应 |
| --- | --- | --- |
| GET /api/login-options | 无 | `[]` |
| POST /api/login | `username,password,id,uuid,type:"account",autoLogin,deviceInfo,client_role?`；同机切换时可加上一次登录的 Bearer | `{type:"access_token",access_token,user,expires_at}` |
| POST /api/currentUser | Bearer + `id,uuid` | 直接返回 `user` |
| POST /api/logout | Bearer + `id,uuid` | `{success:true}` |
| POST /api/tomdesk/authorize | Bearer + `id,uuid,action` | `{user,expires_at,permissions:{remote,subtitles}}` |
| POST /api/tomdesk/paired-device | A 的 Bearer + `id,uuid` | `{target_id:string|null}` |
| POST /api/tomdesk/connection-ticket | A 的 Bearer + `id,uuid,target_id,conn_type` | `{ticket,expires_at}` |
| POST /api/tomdesk/consume-ticket | B 的 Bearer + `id,uuid,ticket,source_id,conn_type` | `{authorized:true,source:{id,user_name,role},target:{id,user_name,role}}` |
| POST /api/tomdesk/connection-status | 原 B 会话 Bearer + `id,uuid,ticket,source_id,conn_type` | 同上，仅已消费且仍有效的连接 |

`user` 为 `{name,display_name,avatar:"",status:1,is_admin,role}`，role 只能为 controller 或 receiver。`expires_at` 是 UTC Unix 秒整数。新版登录必须传对应 `client_role`；有效密码但角色不符返回 HTTP 403 `role_mismatch`，无配对返回 `pair_required`，配对停用返回 `pair_disabled`。旧客户端可省略 client_role，但所有连接接口仍执行同一配对和角色限制。

`authorize.permissions.remote` 仅对启用配对内的 controller 为 true；`subtitles` 对有效登录维持 true 以兼容身份验证，A 客户端另外禁止字幕接收功能。`action` 接受 remote/subtitles。连接请求结构兼容 remote、file_transfer、port_forward、view_camera、terminal，但本版只授权 remote，其他类型一律拒绝。RDP 客户端映射 port_forward 后同样拒绝。

`paired-device` 仅允许配对 A 查询；B 未绑定或没有未过期登录会话时返回 null。该接口反映账号会话，不是实时网络心跳，返回 ID 不保证机器当前在线。`deviceInfo` 仅为协议兼容，不存入数据库，也不作为硬件证明。

A 先申请绑定同组 B 的短期票据，再把它随原生连接请求发给 B。B 使用自己的长期 Bearer 向服务验证并原子消费。长期 Bearer 只能发送给账号服务，不能交给对端。配对版客户端使用可信票据完成授权，不再要求设备密码或人工批准；仅部署 HTTP 服务不会自动改变未集成门禁的旧客户端。

首次消费期限默认 300 秒，覆盖 NAT 建连延迟且不超过 A 的会话有效期。票据仅存 SHA-256 摘要，绑定源会话、源设备、目标设备、签发时 B 最新有效会话和连接类型；同一票据只能消费一次。消费时也要求 B 使用最新有效会话，且与票据绑定一致。签发、消费、状态检查都验证角色、同组关系和会话有效性。

B 每 30 秒复核 `connection-status`；已消费连接不受首次消费期限限制，但签发和消费时绑定的双方会话必须仍然有效。任一端重新登录后，已有远控会在下次复核时断开；B 的新登录不能使用原票据接管旧连接。退出、改密、解绑、禁用或整组下线都会使相应连接授权失效。未消费票据不能查询状态，已消费票据不能建立第二条连接；客户端只能在同一连接对象内缓存已消费结果。

## 旧数据迁移与兼容范围

首次升级旧数据库时，缺少 role 的现有账号迁移为 controller，保留原账号、密码哈希、绑定和会话；新增 pair_pk 默认为空，不自动把 frank 或任何原账号配成一组。升级前没有绑定 B 会话的未消费旧票据，可在仍有效时由 B 的最新会话消费并完成绑定；已消费但没有绑定 B 会话的旧连接无法继续授权，需要重连。迁移位于启动写事务中，重复启动不会改回已有角色。

若直接升级旧服务，未配对账号虽然仍可用旧客户端登录和读取身份，但不再获得连接票据，新 A/B 登录也会被拒绝。为避免影响现有用户，本部署方案使用全新项目、数据卷和 API 前缀，旧 /tomdesk-account 保持不变。不要在新服务中直接挂载旧数据库来替代独立部署。

设备身份来自客户端声明的 ID/UUID，不是 TPM 或硬件远程证明。持有配对账号密码的人可从另一台设备登录并使原设备下线；请勿共享密码。本服务没有设备预审批、收费授权或跨系统信任功能。

## 数据与配置

密码使用 Argon2id（64 MiB、3 次迭代、单哈希并行度 1、随机盐）；会话令牌为 256-bit 随机 opaque token，只保存 SHA-256 摘要。每次授权读取数据库当前状态。校验密码后、发会话前再次检查账号和密码哈希，防止并发禁用或改密后旧凭据发出会话。

SQLite 查询参数化，所有连接在成功与异常后显式关闭。绑定、撤销、迁移和消费使用事务；消费在 BEGIN IMMEDIATE 内完成校验和更新。外键级联撤销关联票据；connection-status 在单个只读快照内验证，过期清理只删除未消费票据，不误删仍有效的长连接。

默认单进程，最多两个并行 Argon2 操作，忙时返回 503。登录按来源 IP 和规范化账号名分别限流，包括成功尝试；计数保存在数据库，重启不清空当前窗口，超限返回 429 和 Retry-After。POST 正文最多 16 KiB，每个源会话最多 64 张未消费有效票据。

| 环境变量 | 默认值 |
| --- | --- |
| TOMDESK_ACCOUNT_DB | `data/accounts.sqlite3`，相对工作目录 |
| TOMDESK_ACCOUNT_HOST / PORT | `127.0.0.1` / `8091` |
| TOMDESK_ACCOUNT_PUBLISH_PORT | Compose 默认 8091，独立配对部署设 8092 |
| TOMDESK_SESSION_TTL_SECONDS | 43200（12 小时） |
| TOMDESK_REMEMBER_TTL_SECONDS | 604800（7 天，autoLogin=true） |
| TOMDESK_TICKET_TTL_SECONDS | 300（可设 30–900 秒） |
| TOMDESK_LOGIN_WINDOW_SECONDS | 60 |
| TOMDESK_LOGIN_IP_LIMIT / ACCOUNT_LIMIT | 30 / 10 |
| TOMDESK_HASH_CONCURRENCY | 2 |
| TOMDESK_PUBLIC_DOCS | 0；设 1 才开放 /docs 和 /openapi.json |
| TOMDESK_TRUSTED_PROXY_IPS | 空，不信任转发来源头 |

会话有效期可设 60 秒到 90 天。可信代理只能指定明确 IP，多个用逗号分隔，禁止通配符；不要信任用户提供的 X-Forwarded-For。未设可信代理时，代理后访问共用代理 IP 的限流桶。

Linux 新数据目录使用 0700，数据库使用 0600；Windows 本地服务需另外限制 NTFS ACL。数据、备份、明文凭据与 .env 不应入库。默认关闭访问日志；应用日志不记录请求正文、密码或 Bearer。使用单实例，部署前核实备份及资源预算。

## 现有 HTTPS 站点的独立反向代理

下面仅是待审查模板。在现有 phenoseed.com HTTPS server 块新增新路径，保留已有 /tomdesk-account location 和证书配置：

```nginx
location ^~ /tomdesk-paired-account/api/ {
    client_max_body_size 16k;
    client_body_timeout 10s;
    proxy_pass http://127.0.0.1:8092/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_connect_timeout 5s;
    proxy_read_timeout 15s;
}

location /tomdesk-paired-account/ {
    return 404;
}
```

客户端根地址不附加 /api。先确认 location、端口、卷与旧服务互不冲突，再运行 nginx -t，通过后重新加载。本地 /health 不通过公网暴露。容器看到的代理地址可能是 Docker 网桥网关；确认后才填写可信代理 IP。不要向公网开放宿主 8091/8092；公网客户端仅使用正常验证证书的 HTTPS。代理日志不得记录 Authorization、密码正文或票据。本地测试不替代实际 A/B 连接验收。
