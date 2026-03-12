#!/bin/bash
# deploy.sh - 自动化部署脚本
# Root 执行，创建最终用户并初始化环境
# 处理仓库根目录本身是 vpn 的情况

set -e

# -------------------------
# 加载配置
# -------------------------
source "./config.sh"

echo "==== [DEPLOY] Starting deployment ===="

# -------------------------
# 安装必要工具
# -------------------------
apt update
apt install -y certbot git curl ufw apt-transport-https ca-certificates gnupg lsb-release software-properties-common

# 安装 Docker（安全版）
# -------------------------
echo "==== [INFO] Checking Docker installation ===="
if command -v docker &>/dev/null; then
    echo "[INFO] Docker is already installed: $(docker --version)"
    echo "[INFO] Skipping Docker installation to avoid overwriting custom settings."
else
    echo "[INFO] Docker not found. Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    echo "[INFO] Docker installation completed: $(docker --version)"
fi
# ================================
# 设置时区和时间同步
# ================================
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

if command -v timedatectl >/dev/null 2>&1; then
    echo "==== Setting timezone to $TIMEZONE ===="
    timedatectl set-timezone "$TIMEZONE"
else
    echo "timedatectl not found, skipping timezone setup."
fi
# -------------------------
# 创建最终用户
# -------------------------
# 1. 创建新用户（如果不存在）
if ! id "$DEPLOY_USER" &>/dev/null; then
    adduser --gecos "" "$DEPLOY_USER"
	# 准备用户目录
	mkdir -p /home/$DEPLOY_USER
	chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER
fi

# 2. 将新用户加入 docker 用户组
usermod -aG docker "$DEPLOY_USER"

# 3. 给该用户 sudo 权限（可选）
usermod -aG sudo "$DEPLOY_USER"

# 4. 设置 SSH 公钥登录
SSH_KEY_SRC="$HOME/.ssh/authorized_keys"
SSH_DIR="/home/$DEPLOY_USER/.ssh"

mkdir -p "$SSH_DIR"

if [ -f "$SSH_KEY_SRC" ]; then
    cp "$SSH_KEY_SRC" "$SSH_DIR/"
    chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    echo "SSH key copied to $DEPLOY_USER"
else
    echo "Warning: $SSH_KEY_SRC does not exist. Skipping SSH key setup."
fi
# -------------------------
# 5. 设置环境变量
# -------------------------
# 生成 docker compose 使用的 UID/GID
# -------------------------
echo "[INFO] Generating .env for $DEPLOY_USER..."

DEPLOY_UID=$(id -u "$DEPLOY_USER")
DEPLOY_GID=$(id -g "$DEPLOY_USER")

cat > /home/$DEPLOY_USER/.env <<EOF
DEPLOY_UID=$DEPLOY_UID
DEPLOY_GID=$DEPLOY_GID
EOF

chown $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.env
# -------------------------
# 移动仓库内容到用户目录
# -------------------------
echo "[INFO] Copying repository contents to /home/$DEPLOY_USER..."

LOG_DIR="$(dirname "$LOG_FILE")"

mkdir -p "$LOG_DIR"
mkdir -p "/home/$DEPLOY_USER/s-ui/db"
mkdir -p "/home/$DEPLOY_USER/tailscale"
# rsync 时排除用户数据和配置目录
rsync -a \
    --exclude='s-ui/db/' \
    --exclude='deploy_all.sh' \
    --exclude='*.md' \
    --exclude='.git' \
    ./ /home/$DEPLOY_USER/
#rsync -a --exclude='deploy_all.sh' --exclude='.git' --exclude='*.md' ./ /home/$DEPLOY_USER/
chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER

# -------------------------
# 配置防火墙
# -------------------------
echo "[INFO] Configuring UFW..."
echo "[INFO] Resetting UFW..."
# 清理所有 UFW 规则并禁用
ufw --force reset
echo "[INFO] Setting default policies..."
# 默认拒绝所有传入，允许所有传出
ufw default deny incoming
ufw default allow outgoing
echo "[INFO] Allowing required ports..."
# 允许需要的端口
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 8443/udp
#ufw allow 3478/udp
ufw allow 41641/udp
if ! ufw status | grep -q "Status: active"; then
    ufw --force enable
fi

# ================================
# 申请证书, 成功后再复制
# ================================

echo "==== Obtaining Let's Encrypt certificates..."

if certbot certonly --standalone \
    $(printf -- "-d %s " "${DOMAINLIST[@]}") \
    --non-interactive \
    --agree-tos \
    -m "$USER_EMAIL"
then
    echo "==== Certificate obtained successfully."

    echo "==== Copying certificates..."

    mkdir -p "$CERT_DST"

    rsync -a --copy-links "$CERT_SRC"/ "$CERT_DST"/

    # 修改权限
    chown -R $DEPLOY_USER:$DEPLOY_USER "$CERT_DST"

    echo "==== Certificates copied successfully."
else
    echo "!!!! Certificate obtain failed. Skipping copy step."
fi

echo "[INFO] Generating docker-compose.yml..."

cat > /home/$DEPLOY_USER/docker-compose.yml <<EOF
services:
  nginx:
    image: nginx:latest
    container_name: ${NGINX_CONTAINER}
    restart: unless-stopped
    environment:
      - TZ=${TIMEZONE}
    ports:
      - "443:443/tcp"
    volumes:
      - /home/$DEPLOY_USER/Nginx/conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${CERT_DST}:/etc/nginx/certbot:ro
    depends_on:
      - ${SINGBOX_CONTAINER}

  s-ui:
    image: alireza7/s-ui
    container_name: ${SINGBOX_CONTAINER}
    restart: unless-stopped
    environment:
      - TZ=${TIMEZONE}
    volumes:
      - /home/$DEPLOY_USER/s-ui/db:/app/db
      - ${CERT_DST}:/app/cert:ro
    tty: true
    ports:
      - "443:443/udp"
      - "8443:8443/udp"
    entrypoint: "./entrypoint.sh"

  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    network_mode: "host"           # 必须 host 模式
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - /home/$DEPLOY_USER/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    command: ["tailscaled", "--state=/var/lib/tailscale/tailscaled.state"]

EOF

chown $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/docker-compose.yml
echo "[INFO] docker-compose.yml generated."

# -------------------------
# 配置 sudo NOPASSWD 给最终用户
# -------------------------
echo "[INFO] Configuring sudoers..."
echo "Defaults:$DEPLOY_USER !use_pty" > /etc/sudoers.d/$DEPLOY_USER
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD: /usr/bin/sha256sum, /usr/bin/rsync, /bin/chown, /bin/chmod, /usr/bin/docker" >> /etc/sudoers.d/$DEPLOY_USER
chmod 440 /etc/sudoers.d/$DEPLOY_USER

# -------------------------
# smart_run.sh 可执行
# -------------------------
chmod +x "/home/$DEPLOY_USER/smart_run.sh"
# -------------------------
# 配置 crontab（目标用户下）
# -------------------------
echo "[INFO] Setting crontab for smart_run.sh..."
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * *}"
CRON_JOB="$CRON_SCHEDULE /home/$DEPLOY_USER/smart_run.sh"
sudo -u $DEPLOY_USER bash -c "(crontab -l 2>/dev/null | grep -v 'smart_run.sh'; echo '$CRON_JOB') | crontab -"

# -------------------------
echo "==== [DEPLOY] Deployment complete! ===="
echo "Next steps:"
echo "1. Switch to user: su - $DEPLOY_USER"
echo "2. Run docker compose up -d for initial sync"
echo "3. Run docker exec -it tailscale tailscale up"
