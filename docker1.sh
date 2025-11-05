#!/bin/bash

# AxisAI - Docker镜像加速配置与VastAI服务管理工具
# 用于配置内网镜像加速并管理VastAI服务

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_FILE="/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"
SCRIPT_PATH="$(readlink -f "$0")"

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用root权限运行此脚本${NC}"
    echo "使用方法: sudo $0"
    exit 1
fi

# 打印标题
clear
echo -e "${BLUE}=========================================="
echo "         AxisAI 配置管理工具"
echo "==========================================${NC}"
echo ""

# 主菜单
echo "请选择要执行的操作："
echo ""
echo "  1) 配置内网镜像加速"
echo "  2) 重启VastAI服务"
echo "  3) 配置镜像加速并重启VastAI"
echo "  0) 退出"
echo ""

while true; do
    read -p "请输入选项 [0-3]: " MENU_CHOICE
    
    case $MENU_CHOICE in
        1|2|3|0)
            break
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入${NC}"
            ;;
    esac
done

if [ "$MENU_CHOICE" = "0" ]; then
    echo -e "${YELLOW}退出程序${NC}"
    exit 0
fi

CONFIGURE_MIRROR=false
RESTART_VASTAI=false

case $MENU_CHOICE in
    1)
        CONFIGURE_MIRROR=true
        ;;
    2)
        RESTART_VASTAI=true
        ;;
    3)
        CONFIGURE_MIRROR=true
        RESTART_VASTAI=true
        ;;
esac

# ==================== 配置镜像加速 ====================
if [ "$CONFIGURE_MIRROR" = true ]; then
    echo ""
    echo -e "${BLUE}=========================================="
    echo "       配置内网镜像加速"
    echo "==========================================${NC}"
    echo ""

    # 交互式输入内网IP地址
    while true; do
        read -p "请输入内网镜像仓库IP地址: " MIRROR_IP
        
        # 验证IP地址格式
        if [[ $MIRROR_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # 验证每个八位组是否在0-255范围内
            valid=true
            IFS='.' read -ra ADDR <<< "$MIRROR_IP"
            for i in "${ADDR[@]}"; do
                if [ $i -gt 255 ]; then
                    valid=false
                    break
                fi
            done
            
            if [ "$valid" = true ]; then
                break
            else
                echo -e "${RED}错误: IP地址格式不正确，请重新输入${NC}"
            fi
        else
            echo -e "${RED}错误: IP地址格式不正确，请重新输入${NC}"
        fi
    done

    # 询问端口（可选）
    read -p "请输入镜像仓库端口 [默认: 5000]: " MIRROR_PORT
    MIRROR_PORT=${MIRROR_PORT:-5000}

    # 构建镜像URL
    MIRROR_URL="http://${MIRROR_IP}:${MIRROR_PORT}"
    REGISTRY_ADDR="${MIRROR_IP}:${MIRROR_PORT}"

    echo ""
    echo -e "${YELLOW}配置信息:${NC}"
    echo "  镜像地址: $MIRROR_URL"
    echo "  不安全注册表: $REGISTRY_ADDR"
    echo ""

    # 检查是否已存在该IP配置
    if [ -f "$DAEMON_JSON" ]; then
        echo "检查是否存在重复配置..."
        
        DUPLICATE_CHECK=$(python3 << EOF
import json
import sys

try:
    with open('$DAEMON_JSON', 'r') as f:
        config = json.load(f)
    
    # 检查 registry-mirrors 中是否已有该IP
    mirrors = config.get('registry-mirrors', [])
    for mirror in mirrors:
        if '$MIRROR_IP' in mirror:
            print('DUPLICATE_MIRROR')
            sys.exit(0)
    
    # 检查 insecure-registries 中是否已有该IP
    insecure = config.get('insecure-registries', [])
    for reg in insecure:
        if '$MIRROR_IP' in reg:
            print('DUPLICATE_INSECURE')
            sys.exit(0)
    
    print('NO_DUPLICATE')
    
except Exception as e:
    print('ERROR')
    sys.exit(1)
EOF
)
        
        if [ "$DUPLICATE_CHECK" = "DUPLICATE_MIRROR" ] || [ "$DUPLICATE_CHECK" = "DUPLICATE_INSECURE" ]; then
            echo -e "${YELLOW}警告: 检测到配置中已存在该IP地址 ($MIRROR_IP)${NC}"
            echo -e "${YELLOW}为避免重复配置，将跳过添加操作${NC}"
            echo ""
            echo "当前配置内容:"
            echo "----------------------------"
            cat "$DAEMON_JSON"
            echo "----------------------------"
            echo ""
            CONFIGURE_MIRROR=false
        fi
    fi

    # 如果没有重复，继续配置
    if [ "$CONFIGURE_MIRROR" = true ]; then
        # 确认
        read -p "确认添加此配置? (y/n): " CONFIRM
        if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}操作已取消${NC}"
            CONFIGURE_MIRROR=false
        else
            echo ""
            echo "开始配置..."

            # 创建docker目录（如果不存在）
            mkdir -p /etc/docker

            # 备份原配置文件
            if [ -f "$DAEMON_JSON" ]; then
                echo "备份原配置文件到: $BACKUP_FILE"
                cp "$DAEMON_JSON" "$BACKUP_FILE"
                
                # 使用Python处理JSON（更可靠）
                python3 << EOF
import json
import sys

try:
    # 读取现有配置
    with open('$DAEMON_JSON', 'r') as f:
        config = json.load(f)
    
    # 添加或更新registry-mirrors
    if 'registry-mirrors' not in config:
        config['registry-mirrors'] = []
    
    # 检查是否已存在该镜像
    if '$MIRROR_URL' not in config['registry-mirrors']:
        config['registry-mirrors'].append('$MIRROR_URL')
        print('已添加镜像地址到registry-mirrors')
    else:
        print('镜像地址已存在，跳过添加')
    
    # 添加或更新insecure-registries（用于HTTP访问）
    if 'insecure-registries' not in config:
        config['insecure-registries'] = []
    
    registry_addr = '$REGISTRY_ADDR'
    if registry_addr not in config['insecure-registries']:
        config['insecure-registries'].append(registry_addr)
        print('已添加到insecure-registries（允许HTTP访问）')
    else:
        print('insecure-registries已包含该地址')
    
    # 写入配置
    with open('$DAEMON_JSON', 'w') as f:
        json.dump(config, f, indent=2)
    
    print('配置文件更新成功')
    
except Exception as e:
    print(f'错误: {e}', file=sys.stderr)
    sys.exit(1)
EOF
                
                if [ $? -ne 0 ]; then
                    echo -e "${RED}配置更新失败，正在恢复备份...${NC}"
                    cp "$BACKUP_FILE" "$DAEMON_JSON"
                    exit 1
                fi
                
            else
                # 创建新配置文件
                echo "创建新的配置文件"
                cat > "$DAEMON_JSON" << EOF
{
  "registry-mirrors": [
    "$MIRROR_URL"
  ],
  "insecure-registries": [
    "$REGISTRY_ADDR"
  ]
}
EOF
            fi

            echo ""
            echo -e "${GREEN}配置文件已更新${NC}"
            echo ""
            echo "当前配置内容:"
            echo "----------------------------"
            cat "$DAEMON_JSON"
            echo "----------------------------"
            echo ""

            # 重启Docker服务
            echo "正在重启Docker服务..."
            systemctl daemon-reload
            systemctl restart docker
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Docker服务重启成功!${NC}"
                echo ""
                echo "验证配置:"
                docker info | grep -A 10 "Registry Mirrors" 2>/dev/null || echo "配置已应用"
            else
                echo -e "${RED}Docker服务重启失败，请检查日志${NC}"
                echo "查看日志: journalctl -u docker -n 50"
                exit 1
            fi
        fi
    fi
fi

# ==================== 重启VastAI服务 ====================
if [ "$RESTART_VASTAI" = true ] || [ "$CONFIGURE_MIRROR" = true ]; then
    echo ""
    echo -e "${BLUE}=========================================="
    echo "       VastAI 服务管理"
    echo "==========================================${NC}"
    echo ""
    
    # 检查vastai服务是否存在
    if systemctl list-unit-files | grep -q vastai.service; then
        read -p "是否重启VastAI服务? (y/n): " RESTART_VASTAI_CONFIRM
        
        if [[ $RESTART_VASTAI_CONFIRM =~ ^[Yy]$ ]]; then
            echo "正在后台重启VastAI服务..."
            systemctl restart vastai &>/dev/null &
            
            # 等待一下确认启动
            sleep 2
            
            if systemctl is-active --quiet vastai; then
                echo -e "${GREEN}VastAI服务已启动${NC}"
            else
                echo -e "${YELLOW}VastAI服务正在启动中...${NC}"
                echo "查看状态: systemctl status vastai"
            fi
        else
            echo -e "${YELLOW}已跳过VastAI服务重启${NC}"
        fi
    else
        echo -e "${YELLOW}未检测到VastAI服务，跳过重启${NC}"
    fi
fi

# ==================== 完成并自毁 ====================
echo ""
echo -e "${GREEN}=========================================="
echo "         所有操作已完成!"
echo "==========================================${NC}"
echo ""

if [ -f "$BACKUP_FILE" ]; then
    echo "备份文件: $BACKUP_FILE"
fi

echo ""
echo -e "${YELLOW}正在删除脚本自身...${NC}"
sleep 1

# 删除脚本自身
rm -f "$SCRIPT_PATH"

echo -e "${GREEN}脚本已删除，感谢使用 AxisAI!${NC}"
echo ""

