#!/bin/bash
# executor 容器入口：multica 登录 → gh 认证 → 启动 daemon（前台主进程）
# 环境变量：MULTICA_PAT（必填）、MULTICA_SERVER_URL（默认 http://backend:8080）、
#           GH_TOKEN（必填，GitHub PAT，repo 写权限）、ANTHROPIC_API_KEY（Claude Code 无头认证）
set -e

# multica 登录（登录态持久化在 /root/.multica 卷，重复执行幂等覆盖）
multica login --token "$MULTICA_PAT" --server-url "${MULTICA_SERVER_URL:-http://backend:8080}"

# gh 认证：容器内 git push/pull 走 gh credential helper
echo "$GH_TOKEN" | gh auth login --with-token

# 启动 daemon（--foreground：daemon start 默认后台化会让容器主进程退出，
# 容器场景必须前台运行；tini 负责 SIGTERM 优雅退出）
exec multica daemon start --foreground
