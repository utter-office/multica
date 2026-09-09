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

# Claude Code 官方插件幂等 seed（claude/full 变体才有 claude，command -v 先行判断）。
# 镜像构建时已把插件 bake 进 /root/.claude，但 compose 的 executor_claude named volume
# 在卷已存在时会遮蔽 bake 内容（copy-up 只在卷首次创建为空时发生），
# 所以这里按 cache 目录存在性逐插件补装；失败仅告警，下次容器启动重试。
if command -v claude >/dev/null 2>&1; then
  if [ ! -d "$HOME/.claude/plugins/marketplaces/claude-plugins-official" ]; then
    claude plugin marketplace add anthropics/claude-plugins-official >/dev/null 2>&1 \
      || echo "warning: claude plugin marketplace add failed — retry next start" >&2
  fi
  # 注意：官方 marketplace 无通用 mysql 插件，需要时另行评估
  for p in context7 superpowers github redis-development playwright; do
    if [ -d "$HOME/.claude/plugins/cache/claude-plugins-official/$p" ]; then
      continue
    fi
    claude plugin install -y "$p@claude-plugins-official" >/dev/null 2>&1 \
      && echo "claude plugin $p installed" \
      || echo "warning: claude plugin $p install failed — retry next start" >&2
  done
fi

# DeepSeek Harness multica profile。按内容幂等：profile 必须携带
# @multica-ai/dsh-runtime（MUL-6186 修复载体，负责把 mat_ 任务 token 窄转发
# 穿过 dsh 的凭证剥除），旧版 dsh-profile-multica（无豁免）若残留在匿名卷里
# 会被移除。base 镜像可能不含 dsh（claude-only variant），用 command -v 先行
# 判断；/opt/multica-dsh-runtime 仅在 dsh/full 变体镜像内存在。
if command -v dsh >/dev/null 2>&1 && [ -d /opt/multica-dsh-runtime ]; then
  if [ ! -d /root/.dsh/profiles/multica/node_modules/@multica-ai/dsh-runtime ]; then
    echo "installing dsh multica profile (@multica-ai/dsh-runtime)..."
    dsh plugin --profile multica remove dsh-profile-multica >/dev/null 2>&1 || true
    dsh plugin --profile multica add /opt/multica-dsh-runtime >/dev/null 2>&1 \
      || echo "warning: dsh multica profile install failed — dsh runtime unavailable" >&2
  fi
  dsh --profile multica --probe >/dev/null 2>&1 \
    || echo "warning: dsh multica profile probe failed — check /opt/multica-dsh-runtime" >&2
fi

# 启动 daemon（--foreground：daemon start 默认后台化会让容器主进程退出，
# 容器场景必须前台运行；tini 负责 SIGTERM 优雅退出）
exec multica daemon start --foreground
