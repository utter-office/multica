# ── Stage 1: 编译 multica CLI（与 server 同源码，保证 daemon/server 版本一致）──
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY server/go.mod server/go.sum ./server/
RUN cd server && go mod download
COPY server/ ./server/
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w" -o /multica ./cmd/multica

# ── Stage 2: 运行时 ──
FROM node:22-slim

# 基础工具：git + 证书 + Claude Code 依赖的系统工具（rg/jq）
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl jq ripgrep \
    && apt-get purge -y curl \
    && rm -rf /var/lib/apt/lists/*

# multica CLI（Stage 1 编译产物）
COPY --from=builder /multica /usr/local/bin/multica

# Claude Code（agent 执行器；如需锁定版本改为 @anthropic-ai/claude-code@<version>）
RUN npm install -g @anthropic-ai/claude-code

# GitHub CLI（git 提交/PR 凭据；版本锁定）
ADD https://github.com/cli/cli/releases/download/v2.74.0/gh_2.74.0_linux_amd64.tar.gz /tmp/
RUN tar xzf /tmp/gh_*.tar.gz -C /usr/local --strip-components=1 && rm /tmp/gh_*.tar.gz

# git 身份与凭据集成（提交显示为 utter.office）
RUN git config --global user.name "utter.office" \
    && git config --global user.email "utter.office@trustinlab.com" \
    && git config --global credential.helper "!gh auth git-credential"

# 环境：时区/编码、任务工作目录、关闭 daemon 自动更新（避免拉到官方新版本破坏版本匹配）
ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    MULTICA_WORKSPACES_ROOT=/workspaces \
    MULTICA_DAEMON_AUTO_UPDATE=false

# 持久化：daemon 配置/登录态、任务工作目录、Claude Code 会话
VOLUME ["/workspaces", "/root/.multica", "/root/.claude"]

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
