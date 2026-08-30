#!/bin/bash
# SIT 部署脚本 — 拉取最新镜像并重启 multica 服务
# 仿 utter-office deploy-sit.sh；与 utter-office 共用同一台服务器与 ACR，但 compose 用独立目录
# 用法: bash deploy-sit.sh
set -e

SIT_HOST="root@39.105.35.182"
# 注意: /www/server/panel/data/compose/utter-office 是 utter-office 的 compose，multica 在独立目录
COMPOSE_DIR="/www/server/panel/data/compose/multica"
# compose 服务名（与 docker-compose.selfhost.yml 的服务名一致）
SERVICES="backend frontend"

echo "🚀 部署 SIT 环境 (multica)..."
ssh "$SIT_HOST" "cd $COMPOSE_DIR && docker compose pull $SERVICES && docker compose up -d $SERVICES --force-recreate"
echo "✅ 部署完成"
echo ""
echo "验证服务（端口仅绑定 127.0.0.1 回环，需在服务器本机 curl）:"
echo "  Backend: ssh $SIT_HOST \"cd $COMPOSE_DIR && docker compose port backend 8080\" 后回环 curl /health"
echo "  Frontend: ssh $SIT_HOST \"cd $COMPOSE_DIR && docker compose port frontend 3000\" 后回环 curl /"
echo ""
echo "等待迁移与启动完成（backend 容器启动时自动执行 ./migrate up，无需手动导 SQL）:"
ssh "$SIT_HOST" "cd $COMPOSE_DIR && for i in \$(seq 1 60); do code=\$(curl -s -o /dev/null -w '%{http_code}' \"http://127.0.0.1:\$(docker compose port backend 8080 | sed 's/.*://' | tr -d ' ')/readyz\"); if [ \"\$code\" = \"200\" ]; then echo \"✅ backend /readyz 返回 200\"; break; fi; sleep 2; done"
ssh "$SIT_HOST" "curl -s -o /dev/null -w 'frontend=%{http_code}\n' http://127.0.0.1:\$(cd $COMPOSE_DIR && docker compose port frontend 3000 | sed 's/.*://' | tr -d ' ')/"
