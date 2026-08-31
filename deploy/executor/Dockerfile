# Agent executor image: multica CLI + daemon + Claude Code + GitHub CLI.
#
# Design borrowed from sapk/multica-docker-env (MIT):
#   - multica CLI is COPY'd from the backend image, so daemon and server
#     always share the same tag → no version drift, no local Go build.
#   - tini as PID 1 so SIGTERM reaches the daemon on container stop.
# Fork-specific: GitHub CLI (git auth), Claude Code routed to DeepSeek via
# ANTHROPIC_BASE_URL at runtime.

# ── multica CLI source: backend image (same tag as the deployed server) ──
ARG MULTICA_IMAGE=ghcr.io/utter-office/multica-backend
ARG MULTICA_TAG=utter-main
FROM ${MULTICA_IMAGE}:${MULTICA_TAG} AS multica

FROM node:22-slim

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# git + certs + Claude Code deps (rg/jq) + SSH repos + large files + tini
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl jq ripgrep \
      openssh-client git-lfs \
      tini \
    && apt-get purge -y curl \
    && rm -rf /var/lib/apt/lists/*

# multica CLI（与 server 同一镜像 tag，版本天然一致）
COPY --from=multica /app/multica /usr/local/bin/multica

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

COPY deploy/executor/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# tini 保证容器停止时 daemon 收到 SIGTERM 优雅退出
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
