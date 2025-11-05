#!/bin/bash
CONFIG_FILE="/etc/docker/daemon.json"
BACKUP_FILE="/etc/docker/daemon.json.bak_$(date +%Y%m%d%H%M%S)"

echo "请输入内网镜像机地址（格式：192.168.100.222:5000）"
read -p "内网镜像机 IP:PORT: " REGISTRY

if [ -z "$REGISTRY" ]; then
    echo "❌ 未输入内容，已退出。"
    exit 1
fi

# 确保 jq 存在
if ! command -v jq >/dev/null 2>&1; then
    echo "正在安装 jq..."
    apt update -y && apt install -y jq
fi

# 如果 daemon.json 不存在则创建空文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo "{}" > "$CONFIG_FILE"
    echo "⚠️ 未检测到 daemon.json，已创建新文件。"
fi

# 检查 daemon.json 是否是合法 JSON
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "⚠️ 检测到 daemon.json 格式错误，正在重置为标准结构..."
    cat <<EOF > "$CONFIG_FILE"
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "registry-mirrors": [],
  "insecure-registries": [],
  "runtimes": {
    "nvidia": {
      "path": "/var/lib/vastai_kaalia/latest/kaalia_docker_shim",
      "runtimeArgs": []
    }
  }
}
EOF
fi

# 如果 registry-mirrors 或 insecure-registries 是字符串，则强制重置为数组
jq '
  if (type == "object") then
    if (.["registry-mirrors"] | type != "array") then .["registry-mirrors"] = [] else . end |
    if (.["insecure-registries"] | type != "array") then .["insecure-registries"] = [] else . end
  else
    {
      "exec-opts": ["native.cgroupdriver=cgroupfs"],
      "registry-mirrors": [],
      "insecure-registries": [],
      "runtimes": {
        "nvidia": {
          "path": "/var/lib/vastai_kaalia/latest/kaalia_docker_shim",
          "runtimeArgs": []
        }
      }
    }
  end
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# 备份原文件
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "✅ 已备份原配置文件到: $BACKUP_FILE"

# 使用 jq 追加（防止重复）
tmp_file=$(mktemp)
jq --arg REG "http://$REGISTRY" --arg INSEC "$REGISTRY" '
  .["registry-mirrors"] = (.["registry-mirrors"] // []) |
  if ($REG | IN(.["registry-mirrors"][])) then . else .["registry-mirrors"] += [$REG] end
  |
  .["insecure-registries"] = (.["insecure-registries"] // []) |
  if ($INSEC | IN(.["insecure-registries"][])) then . else .["insecure-registries"] += [$INSEC] end
' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

echo "✅ 已更新 $CONFIG_FILE："
cat "$CONFIG_FILE" | jq .

# 重启 Docker
echo "🚀 正在重启 Docker..."
systemctl daemon-reload
systemctl restart docker

if systemctl is-active --quiet docker; then
    echo "✅ Docker 已成功重启。"
else
    echo "❌ Docker 重启失败，请检查日志。"
fi

# ⚙️ 静默删除自身
SCRIPT_PATH="$(realpath "$0")"
echo "🧹 正在清理脚本文件..."
rm -f "$SCRIPT_PATH" && echo "✅ 已删除脚本: $SCRIPT_PATH"
