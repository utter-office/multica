# Executor full image (default for docker compose): base + Claude Code + dsh.
# Builds on the three-layer split — see Dockerfile.base / .claude / .dsh.
#
#   docker build --build-arg BASE_IMAGE=... --build-arg BASE_TAG=utter-main -t multica-executor .

ARG BASE_IMAGE=ghcr.io/utter-office/multica-executor-base
ARG BASE_TAG=utter-main
FROM ${BASE_IMAGE}:${BASE_TAG}

# Claude Code（agent 执行器；如需锁定版本改为 @anthropic-ai/claude-code@<version>）
RUN npm install -g @anthropic-ai/claude-code

# DeepSeek Harness（dsh，DeepSeek 原生 agent CLI；developer preview，迭代快）
# pnpm：dsh 的 plugin 管理依赖；multica profile 由 entrypoint 幂等安装
RUN npm install -g @deepseek-ai/dsh pnpm

# runtime 专属卷
VOLUME ["/root/.claude", "/root/.dsh"]

# ENTRYPOINT 继承 base（tini → entrypoint.sh）
