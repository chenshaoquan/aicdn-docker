#!/bin/bash
# AxisAI Installer Wrapper
# Auto-download and execute the encoded version

set -e

ENCODED_URL="https://raw.githubusercontent.com/chenshaoquan/aicdn-docker/main/AxisAI_encoded.txt"

# Check root permission
if [ "$EUID" -ne 0 ]; then 
    echo -e "\033[0;31m错误: 请使用root权限运行此脚本\033[0m"
    echo "使用方法: sudo bash <(curl -fsSL ...)"
    exit 1
fi

# Download and execute the encoded script
echo "正在加载 AxisAI 配置工具..."
echo ""

if command -v curl &> /dev/null; then
    curl -fsSL "$ENCODED_URL" | base64 -d | bash
elif command -v wget &> /dev/null; then
    wget -qO- "$ENCODED_URL" | base64 -d | bash
else
    echo -e "\033[0;31m错误: 未找到 curl 或 wget 命令\033[0m"
    exit 1
fi
