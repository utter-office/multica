#!/bin/bash
# executor 容器入口：multica 登录 → gh 认证验证 → 启动 daemon（前台主进程）
# 环境变量：MULTICA_PAT（必填）、MULTICA_SERVER_URL（默认 http://backend:8080）、
#           GH_TOKEN（必填，GitHub PAT，repo 写权限）、ANTHROPIC_API_KEY（LLM 认证）
set -e

# multica 登录（登录态持久化在 /root/.multica 卷，重复执行幂等覆盖）
multica login --token "$MULTICA_PAT" --server-url "${MULTICA_SERVER_URL:-http://backend:8080}"

# gh 认证：GH_TOKEN 环境变量已生效（gh 与 git credential helper 均自动读取），
# 无需 auth login 持久化。注意：GH_TOKEN 模式下 `gh auth login --with-token`
# 返回非零（环境变量模式拒绝覆盖），所以这里只验证不登录。
if ! gh auth status >/dev/null 2>&1; then
  echo "warning: gh auth status failed — 检查 GH_TOKEN 是否有效" >&2
fi

# DeepSeek Harness multica profile（幂等：dsh 存在且 probe 通过则跳过）。
# base 镜像可能不含 dsh（claude-only variant），用 command -v 先行判断。
# /root/.dsh 不在持久化卷内，容器重建后需重新安装。
if command -v dsh >/dev/null 2>&1 && ! dsh --profile multica --probe >/dev/null 2>&1; then
  echo "installing dsh multica profile (dsh-profile-multica)..."
  dsh plugin --profile multica add dsh-profile-multica >/dev/null 2>&1 \
    || echo "warning: dsh multica profile install failed — dsh runtime unavailable" >&2
fi

# 启动 daemon（--foreground：daemon start 默认后台化会让容器主进程退出，
# 容器场景必须前台运行；tini 负责 SIGTERM 优雅退出）
exec multica daemon start --foreground
