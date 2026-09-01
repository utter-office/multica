# multica 私有化部署方案（utter-office fork）

> 本文件是 **utter-office fork 专属**的部署方案，按 utter-office（RuoYi 基线）的部署风格落地，并与 utter-office 共用服务器与镜像仓库资源。
> 上游通用自托管能力（配置全表、S3、邮件、反代细节等）见官方 [SELF_HOSTING.md](SELF_HOSTING.md) 与 [SELF_HOSTING_ADVANCED.md](SELF_HOSTING_ADVANCED.md)，本文件只写 fork 增量。

## 资源清单（与 utter-office 共用）

| 资源 | 值 | 说明 |
|---|---|---|
| SIT 服务器 | 与 utter-office 共用同一台（阿里云 ECS + 宝塔面板；地址见 utter-office 仓库 `deploy-sit.sh`，部署时通过 `SIT_HOST` 环境变量注入） |
| Compose 目录 | `/www/server/panel/data/compose/multica` | **独立目录**，与 utter-office 的 `.../compose/utter-office` 分开 |
| 镜像仓库（ACR） | `registry.cn-hangzhou.aliyuncs.com/nothing/multica-backend` / `.../multica-web` | 与 utter-office 共用 ACR 账号/命名空间 |
| 镜像仓库（GHCR） | `ghcr.io/utter-office/multica-backend` / `.../multica-web` | 备份通道，国内服务器优先走 ACR |
| SIT 域名 | `http://dev-c.geoclar.com` | 宝塔 nginx 反代到 127.0.0.1:3000（与 utter-office 的 dev-a/dev-b 同主域 geoclar.com） |
| SIT 端口 | backend `8084` / frontend `3000`（均仅回环） | 8080 被 geoclar 的 CTUPortal 占用、8083/8003 是 utter-office 的 |
| 反向代理 | 宝塔 nginx（Docker 网站代理） | 与 utter-office 同域名体系，新增一个站点 |

## 架构

```
┌─ 浏览器 ─┐          ┌─ 客户机器（每台）─┐
│  web UI  │          │ multica CLI + daemon │
└────┬─────┘          └─────────┬───────────┘
     │ https://<域名>          │ wss://<域名>/ws
     ▼                          │
┌─ nginx（TLS，域名反代；/ws 需关缓冲放行）─┐
│     只放行 443；8080 / 3000 仅回环绑定      │
└────┬──────────────────────────────────────┘
     ▼ 127.0.0.1:3000
┌─ frontend 容器（Next.js standalone，容器内 rewrites 把
│    /v1 /ws /api /uploads → backend）──────┐
└───────────────────────────────────────────▼
┌─ backend 容器 ──┐   ┌─ postgres 容器 ─┐
│  :8080          │──▶│  pgdata / uploads │
└─────────────────┘   └──────────────────┘
```

- **网络模型**：compose 全部服务只绑定 `127.0.0.1`（`docker-compose.selfhost.yml` 已如此，**不要改成 0.0.0.0**——Docker 会绕过主机防火墙）。
- **数据库**：PostgreSQL 17 是 compose 内置容器，**对客户透明**，不占用客户既有数据库，也无需手动建库导 SQL。
- **AI 执行**：在每台用户机器的 `multica` CLI/daemon 上（见下文「客户端分发」），服务端只做调度。

## 镜像构建（CI）

`.github/workflows/docker-build.yml`（仿 utter-office 的 docker-build.yml）：

- **触发**：push `utter-main` / tag `v*` / 手动 `workflow_dispatch`
- **门禁**：`go test ./...` 通过后构建
- **产物**：`multica-backend`（`Dockerfile`，Go 多阶段）+ `multica-web`（`Dockerfile.web`，Next.js standalone），双推 GHCR + 阿里云 ACR
- **tag 策略**：`utter-main`（分支）、`sha-<short>`（每次构建）、`v*`（发版）；`provenance: false` 保证 ACR 兼容（utter-office 踩过的坑）
- **回滚**：部署 `.env` 中 `MULTICA_IMAGE_TAG` 固定到具体 tag，不要用 `latest`

## 服务器部署

### 1. 准备 compose 目录

```bash
# SIT_HOST 从环境变量注入，不在公开仓库硬编码服务器 IP
export SIT_HOST=root@<your-server>
ssh "$SIT_HOST" "mkdir -p /www/server/panel/data/compose/multica"
```

上传 `docker-compose.selfhost.yml`、`.env.example` 到该目录（**不是** `utter-office` 目录）。

### 2. `.env` 配置清单

从 `.env.example` 复制为 `.env`，逐项确认：

| 变量 | 必填 | 说明 |
|---|---|---|
| `MULTICA_BACKEND_IMAGE` / `MULTICA_WEB_IMAGE` | ✅ | 指到 `registry.cn-hangzhou.aliyuncs.com/nothing/multica-backend` / `.../multica-web`（覆盖默认的上游 GHCR） |
| `MULTICA_IMAGE_TAG` | ✅ | 固定版本 tag，回滚用 |
| `JWT_SECRET` | ✅ | `openssl rand -hex 32` 生成，缺了 compose 直接拒绝启动 |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `SMTP_FROM_EMAIL` | ✅ | **登录验证码依赖邮件**，不配则验证码只打印到后端日志，无法登录 |
| `FRONTEND_ORIGIN` | ✅ | 对外域名，如 `https://m.example.com` |
| `CORS_ALLOWED_ORIGINS` | ✅ | 同上；漏配会导致 WS 403、realtime 失效 |
| `MULTICA_TRUSTED_PROXIES` | ✅ | 反代所在网段（CIDR），webhook 限流信任 `X-Forwarded-For` 必需 |
| `ALLOW_SIGNUP` / `ALLOWED_EMAIL_DOMAINS` | 建议 | 私有化建议限定企业邮箱域名注册 |
| `BACKEND_PORT` / `FRONTEND_PORT` | 冲突时 | 默认 8080 / 3000（仅回环）；SIT 上 8080 被 geoclar 占用，实际使用 `BACKEND_PORT=8084` |
| `S3_BUCKET` + `AWS_ENDPOINT_URL` | 可选 | 默认本地磁盘卷 `backend_uploads`，量大再上 MinIO |
| `MULTICA_LLM_*` | 可选 | 不配则服务端「自动标题/建议问题」静默关闭，不影响核心流程 |
| `REDIS_URL` / `REALTIME_RELAY_*` | 可选 | 单实例不配 |
| `MULTICA_CLOUD_URL` | 留空 | 留空 = 纯私有化，无云端配额门禁 |

### 3. 反向代理（WS 是重点）

推荐宝塔 nginx「Docker 网站代理」新建站点（与 utter-office 同模式），必须处理两点：

```nginx
location /ws {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
```

其余路径（`/v1`、`/api`、`/auth`、`/uploads`、`/docs`）正常反代到 `http://127.0.0.1:3000` 即可，前端容器内 rewrites 会转发到 backend。漏配 `/ws` 的表现是「一切正常但收不到实时更新、daemon 无法注册」。

### 4. 首次部署

```bash
cd /www/server/panel/data/compose/multica
docker compose pull
docker compose up -d
# 等待就绪（backend 容器启动时自动执行 ./migrate up，无需手动 SQL）
# 端口从 .env 读：SIT 实际为 8084（8080 被 geoclar 占用）
curl -s "http://127.0.0.1:${BACKEND_PORT:-8080}/readyz"    # {"status":"ok","checks":{"db":"ok","migrations":"ok"}}
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${FRONTEND_PORT:-3000}/"   # 200
```

浏览器端到端验证：域名登录（邮箱验证码）→ 建 workspace → 本机装 CLI 连 `/ws`。

## 升级与回滚

```bash
# 升级前备份（必做）：
docker exec $(docker compose ps -q postgres) pg_dump -U multica -d multica > multica-backup-$(date +%F).sql

# 升级：改 .env 中 MULTICA_IMAGE_TAG 为新 tag（或保持分支 tag）后
docker compose pull && docker compose up -d
# 等待 /readyz 返回 ok（迁移自动执行）

# 回滚：把 MULTICA_IMAGE_TAG 指回旧 tag，重复上面两步
```

## 数据持久化与危险操作

数据保存在两个 named volumes（`pgdata` / `backend_uploads`），独立于容器生命周期。**重启、`up -d --force-recreate`、镜像升级均不丢数据。**

| 操作 | 数据 | 说明 |
|---|---|---|
| `docker compose restart` / `up -d` / `pull && up -d` | ✅ 保留 | 部署/升级的正常路径 |
| `docker compose down`（不带 `-v`） | ✅ 保留 | 停服务，卷仍在 |
| `docker compose down -v` | ❌ **删除卷，不可恢复** | 严禁用于生产数据 |
| `docker volume rm multica_pgdata` | ❌ 删除 | 严禁 |
| `docker system prune -a --volumes` | ❌ 删除 | 清理前先核对挂载中的卷 |
| 改 compose 项目名 / 卷定义后 `up` | ⚠️ 数据"消失" | 实际挂到新空卷，旧数据仍在旧卷（`docker volume ls` 可找回）；**升级时只改 `MULTICA_IMAGE_TAG`，不要动 compose 文件** |

> 交付时需把「不要对生产执行 `down -v` / 删卷 / 面板勾选删除数据」写入客户操作手册。

## 备份

- **数据库**：cron 每日 `pg_dump`（如上）到对象存储/异地；**升级前必做**
- **文件**：`backend_uploads` 卷（附件等），`docker volume` 层面快照或 rsync
- 备份是卷删除事故的唯一最终兜底；参考上游 `SELF_HOSTING.md` 的备份章节的完整清单

## 客户端分发（桌面端 / CLI / daemon）

multica 的 AI 执行在用户本机：用户安装桌面端（含 CLI/daemon）或独立 CLI，daemon 通过 `wss://<域名>/ws` 注册到私有 server。**客户端是通用安装包，无需重新打包**——通过运行时配置指向私有服务器。

### 桌面端：`~/.multica/desktop.json`

在每台客户机的用户目录下创建（`apps/desktop/src/main/runtime-config-loader.ts`）：

```json
{
  "schemaVersion": 1,
  "apiUrl": "https://dev-c.geoclar.com"
}
```

- **`apiUrl`（必填）**：私有服务器地址。路径走 web 容器 rewrites 转发 `/v1` `/ws` 到 backend，与浏览器同路径，无需额外反代
- **`wsUrl`（可省略）**：自动从 apiUrl 推导（`https:` → `wss://<host>/ws`）
- **`appUrl`（可省略）**：自动推导；不匹配 `api.<host>` 约定的域名（如 `dev-c.geoclar.com`）原样返回 apiUrl
- **加载逻辑**：文件存在则解析生效；文件不存在回退官方云（`https://api.multica.ai`）；JSON 非法则启动失败并在错误中提示文件路径
- **生效**：改完重启应用

### 桌面端内嵌 CLI / daemon：自动跟随

桌面端内嵌的 `multica` CLI + daemon 使用 renderer 上报的 `apiUrl` 启动 Desktop profile（`daemon-manager.ts`），配好 `desktop.json` 后内嵌 CLI 自动连私有服务器，无需额外操作。

### 独立 CLI：`multica config set server_url`

```bash
multica config set server_url https://dev-c.geoclar.com
```

优先级：`--server-url` flag > `MULTICA_SERVER_URL` 环境变量 > 存储的 CLI 配置（`cmd_daemon.go`）。

### 交付清单

- CLI 二进制 / 安装包分发：GitHub Release（fork 出产物）或自建下载站；`scripts/install.sh` 支持指向私有 server
- 内网客户（无外网）：CLI 与 agent CLI 需离线安装包
- 交付文档注明：`desktop.json` 格式与"重启生效"；写坏会导致应用启动失败
- 完整说明见上游 `CLI_AND_DAEMON.md` / `CLI_INSTALL.md`

## Agent Executor（可选：容器化 agent 执行器）

把 multica daemon + Claude Code + GitHub CLI 装进一个容器，作为 agent 的**集中执行环境**——客户无需在每台机器装 CLI/daemon，任务在服务器侧容器内执行。

### 架构

```
compose 网络内直连（免 nginx/TLS/域名）
executor 容器 ──http://backend:8080──▶ backend（wss 注册/领任务）
  ├─ multica CLI + daemon（--foreground，tini 管理）
  ├─ Claude Code（DeepSeek 路由：ANTHROPIC_BASE_URL）
  └─ gh CLI（GH_TOKEN 凭据，git 提交身份 utter.office）
```

- multica CLI 从 **backend 镜像 COPY**（`deploy/executor/Dockerfile` 多阶段）——daemon 与 server 版本天然一致
- 镜像由 CI 构建双推 ACR（`docker-build.yml` 的 `build-and-push-executor` job，依赖 backend job 完成后构建）
- 卷：`executor_config`（登录态/配置）、`executor_workspaces`（任务工作目录）、`executor_claude`（Claude 会话）

### compose 服务段（已合入 docker-compose.selfhost.yml）

```yaml
executor:
  image: ${MULTICA_EXECUTOR_IMAGE:-ghcr.io/utter-office/multica-executor}:${MULTICA_IMAGE_TAG:-latest}
  depends_on:
    backend:
      condition: service_started
  environment:
    MULTICA_SERVER_URL: ${MULTICA_SERVER_URL:-http://backend:8080}
    MULTICA_PAT: ${MULTICA_PAT:?MULTICA_PAT must be set — create a personal token in the web UI}
    MULTICA_WORKSPACES_ROOT: /workspaces
    MULTICA_DAEMON_AUTO_UPDATE: "false"
    GH_TOKEN: ${GH_TOKEN:?GH_TOKEN must be set — GitHub PAT with repo write scopes}
    ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY must be set for headless Claude Code}
    ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL:-}
    ANTHROPIC_MODEL: ${ANTHROPIC_MODEL:-}
    ANTHROPIC_DEFAULT_OPUS_MODEL: ${ANTHROPIC_DEFAULT_OPUS_MODEL:-}
    ANTHROPIC_DEFAULT_SONNET_MODEL: ${ANTHROPIC_DEFAULT_SONNET_MODEL:-}
    ANTHROPIC_DEFAULT_HAIKU_MODEL: ${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}
    CLAUDE_CODE_SUBAGENT_MODEL: ${CLAUDE_CODE_SUBAGENT_MODEL:-}
  volumes:
    - executor_config:/root/.multica
    - executor_workspaces:/workspaces
    - executor_claude:/root/.claude
  restart: unless-stopped
```

### `.env` 变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `MULTICA_PAT` | ✅ | executor 以成员身份注册（web → 个人设置 → token，`mul_` 开头） |
| `GH_TOKEN` | ✅ | GitHub PAT（`repo` 写权限），容器内 git 提交/PR 认证 |
| `ANTHROPIC_API_KEY` | ✅ | LLM provider key（DeepSeek 场景为 DeepSeek key） |
| `ANTHROPIC_BASE_URL` | 可选 | 默认空（Anthropic 原生）；DeepSeek：`https://api.deepseek.com/anthropic` |
| `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_*_MODEL` / `CLAUDE_CODE_SUBAGENT_MODEL` | 可选 | 模型映射；SIT 全 flash：`deepseek-v4-flash` |
| `DEEPSEEK_API_KEY` | ✅ | dsh（DeepSeek Harness）原生 API key；同时被 Claude Code 兼容层使用（同一 DeepSeek 账号） |
| `IS_SANDBOX` | 固定 `"1"` | 容器以 root 运行，Claude Code 拒绝 root 下 bypassPermissions——声明沙箱环境放行 |

### DeepSeek 路由（全 flash 示例）

```bash
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
```

### 双 runtime（claude + dsh）

executor 容器内注册两个 agent runtime，web 建 agent 时可选任一：

| runtime | CLI | LLM 路径 | 模型 |
|---|---|---|---|
| Claude Code | `claude`（npm 包，`IS_SANDBOX=1` 放行 root bypassPermissions） | DeepSeek Anthropic 兼容层（`ANTHROPIC_BASE_URL`） | `deepseek-v4-flash`（全 flash 映射） |
| DeepSeek Harness | `dsh`（npm 包 `@deepseek-ai/dsh` + `dsh-profile-multica` profile） | DeepSeek 原生 API（`DEEPSEEK_API_KEY`） | `deepseek-official/deepseek-v4-flash`（catalog 默认） |

dsh 由 entrypoint 幂等安装：`dsh plugin --profile multica add dsh-profile-multica`（需 pnpm，镜像已装；`/root/.dsh` 不在持久化卷，容器重建自动重装）。

### Agent 任务环境变量（custom_env）

multica 的任务环境是**封闭白名单**——compose 容器环境变量不会自动进入任务子进程。agent 级配置通过 `PUT /api/agents/{id}/env`（或 web 建 agent 时填写）：

```bash
curl -X PUT https://<域名>/api/agents/<agent-id>/env \
  -H "Authorization: Bearer <mul_ PAT>" -H "X-Workspace-ID: <ws-id>" \
  -H "Content-Type: application/json" \
  -d '{"custom_env": {"DEEPSEEK_API_KEY": "sk-...", "DSH_PERMISSION_MODE": "danger-full-access"}}'
```

SIT 实测需要的 agent env：

| 变量 | 用途 |
|---|---|
| `DEEPSEEK_API_KEY` | dsh 调用 DeepSeek API（缺则任务报 `MISSING_CREDENTIAL`） |
| `DSH_PERMISSION_MODE=danger-full-access` | dsh 的 multica profile 默认 `workspace-write` 沙箱，主机无 bwrap/Landlock 后端时拒绝执行任何命令——切 `danger-full-access`（executor 容器本身即隔离层） |

### 部署与验证

```bash
docker compose -f docker-compose.selfhost.yml up -d executor
# 验证 1：容器稳定运行（Up，非 Restarting）
docker compose -f docker-compose.selfhost.yml ps executor
# 验证 2：环境（版本对齐 + 认证 + 模型路由）
docker exec multica-executor-1 sh -c "multica --version; claude --version; gh auth status; echo \$ANTHROPIC_BASE_URL"
# 验证 3：backend 日志出现 executor 的 runtime heartbeat
docker compose -f docker-compose.selfhost.yml logs backend | grep "daemon heartbeat"
# 验证 4（端到端）：web 建 agent（选 executor 注册的 runtime）→ 指派任务 → 观察执行与 git 提交
```

### 已知要点（踩坑记录）

- **`daemon start` 默认后台化**——容器场景必须 `--foreground`（entrypoint 已处理），否则容器主进程退出 → Restarting 循环
- **`gh auth login --with-token` 在 `GH_TOKEN` 环境变量模式下返回非零**——entrypoint 用非阻塞 `gh auth status` 验证（GH_TOKEN 已自动生效，无需持久化）
- **multica CLI 必须与 server 同版本**——从自家 backend 镜像 COPY（不要用官方 Release 产物或社区镜像里带的官方 CLI）
- **`.dockerignore` 会排除 `/deploy/`**——镜像构建需要 `!/deploy/executor/` 放行（已配置）
- 镜像默认源建议 ACR（国内服务器拉取）；compose 默认是 GHCR，服务器 `.env` 需设 `MULTICA_EXECUTOR_IMAGE=registry.cn-hangzhou.aliyuncs.com/nothing/multica-executor`
- 社区基础镜像（`ghcr.io/sapk/multica-agent-claude`）工具链更全（Podman/Playwright），但 multica CLI 版本不匹配且无 gh——如切换需覆盖 multica CLI 并加 gh 定制层
- **Claude Code 拒绝 root 下 bypassPermissions**（安全硬限制）——`IS_SANDBOX=1` 声明容器沙箱环境（executor 是隔离容器，合理）
- **任务沙箱后端**：multica CLI/dsh 默认要求 `workspace-write` 沙箱（bubblewrap/Landlock）。Alibaba Cloud Linux 容器内 bwrap 不可用（namespace 被主机层限制，seccomp/label 放开也无效）且内核 LSM 无 landlock → 必须给 agent 配 `DSH_PERMISSION_MODE=danger-full-access`（dsh）或等价的 consumer 配置
- **dsh 的 multica profile 是 npm 包 `dsh-profile-multica`**，plugin 管理需要 pnpm（镜像已装）；profile 装在 `$DSH_HOME`（/root/.dsh，非持久化卷，entrypoint 幂等重装）
- **验证基线（SIT 实测）**：claude（全栈开发工程师）与 dsh（Mika）均可在 executor 内完成「领取任务 → multica CLI → DeepSeek 调用 → 回复回传」全闭环

## 风险与合规

1. **License（最高优先级）**：本项目为 Multica License（Apache 2.0 + 附加条件）——**内部单组织使用免费；向第三方提供托管服务（即使免费）需商业授权；UI 不可去品牌化**（移除 LOGO 需书面 waiver）。对外交付前必须先确认形态
2. **邮件必配**：验证码登录是唯一认证路径，无 SMTP/Resend 则无法登录
3. **WS 反代必配**：见上，漏配 = realtime/daemon 静默失效
4. **镜像 tag 固定**：不用 `latest`，保证可回滚
5. **不要改 0.0.0.0 绑定**：Docker 绕过主机防火墙，裸端口会暴露公网
