#!/bin/bash
# config.sh - 部署配置文件

# 最终用户
DEPLOY_USER="sui"
USER_EMAIL="xxx@gmail.com"

# 时区
TIMEZONE="America/Los_Angeles"

# 这个值必须和 Nginx stream map 配置里的 SNI 一致
SNI="www.microsoft.com"

# 域名列表(1个或多个)
DOMAINLIST=("xxx.duckdns.org")

# 证书目录
CERT_SRC="/etc/letsencrypt/live/${DOMAINLIST[0]}"
CERT_DST="/home/$DEPLOY_USER/cert"

# Docker 容器名
NGINX_CONTAINER="nginx"
SINGBOX_CONTAINER="s-ui"

# 日志文件
LOG_FILE="/home/$DEPLOY_USER/log/smart_run.log"

# 定期检查证书
CRON_SCHEDULE="0 3 * * *"
