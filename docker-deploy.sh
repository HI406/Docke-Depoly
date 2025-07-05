#!/bin/bash

# 定义颜色和样式
RED='\033[1;31m'     # 红色，用于错误信息
GREEN='\033[1;32m'   # 绿色，用于成功信息
YELLOW='\033[1;33m'  # 黄色，用于提示信息
BLUE='\033[1;34m'    # 蓝色，用于进度信息
NC='\033[0m'         # 无颜色，重置终端颜色
BOLD=$(tput bold)    # 加粗样式
NORMAL=$(tput sgr0)  # 正常样式

# 获取终端宽度并计算进度条宽度
TERM_WIDTH=$(tput cols)
PROGRESS_WIDTH=$((TERM_WIDTH - 20)) # 留出空间显示百分比等信息

# 初始化全局变量
COMPOSE_FILE=""              # Compose 文件路径
HASH_FILE="image_hashes.txt" # 哈希文件路径
RETRY_LIMIT=3                # 最大重试次数
MIRROR_REGISTRY=""           # 镜像源地址
DEFAULT_MIRROR="https://hub-mirror.c.163.com" # 默认镜像源
SPECIAL_VERSIONS="latest|main" # 特殊版本标签

# 格式化时间显示（秒数 -> 时:分:秒）
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))
    if [ $hours -gt 0 ]; then
        printf "%dh%02dm%02ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm%02ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# 格式化文件大小（B、KB、MB、GB）
format_file_size() {
    local size=$1
    # 检查输入是否为有效数字
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}警告: 无法获取文件大小，返回 0B${NC}" >&2
        printf "0B"
        return
    fi
    if [ $size -lt 1024 ]; then
        printf "%dB" $size
    elif [ $size -lt $((1024 * 1024)) ]; then
        printf "%.2fKB" $(echo "scale=2; $size / 1024" | bc 2>/dev/null || echo "0")
    elif [ $size -lt $((1024 * 1024 * 1024)) ]; then
        printf "%.2fMB" $(echo "scale=2; $size / (1024 * 1024)" | bc 2>/dev/null || echo "0")
    else
        printf "%.2fGB" $(echo "scale=2; $size / (1024 * 1024 * 1024)" | bc 2>/dev/null || echo "0")
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查sudo权限
check_sudo() {
    # 检查当前用户是否具有sudo权限
    if ! sudo -n true 2>/dev/null; then
        echo -e "${RED}✗ 当前用户没有sudo权限${NC}"
        echo -e "${YELLOW}请获取sudo权限后再执行脚本${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 当前用户有sudo权限${NC}"
}

# 检查网络状态
check_network() {
    # 测试基本网络连接
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        # 测试Docker Hub访问
        if curl --connect-timeout 5 -s https://hub.docker.com >/dev/null 2>&1; then
            echo "great" # 可访问Docker Hub
        elif ping -c 1 -W 2 baidu.com >/dev/null 2>&1; then
            echo "good"  # 可联网但无法访问Docker Hub
        else
            echo "bad"   # 网络异常
        fi
    else
        echo "bad"       # 完全不可联网
    fi
}

# 设置镜像源
set_mirror_source() {
    local status=$1
    case "$status" in
        "great")
            # 使用官方Docker Hub
            MIRROR_REGISTRY=""
            echo -e "${GREEN}使用官方Docker Hub镜像源${NC}"
            ;;
        "good")
            # 提示用户输入镜像源，提供默认值
            echo -e "${YELLOW}检测到可联网但无法访问Docker Hub${NC}"
            echo -e "${GREEN}请输入国内镜像源地址 (默认: ${DEFAULT_MIRROR})${NC}"
            read -p "镜像源地址 [回车使用默认]: " user_mirror
            MIRROR_FORMATTED=$(echo "$user_mirror" | sed -e 's|^https\?://||' -e 's|/$||')
            MIRROR_REGISTRY=${MIRROR_FORMATTED:-$DEFAULT_MIRROR}
            # 清理镜像源地址（移除协议和尾部斜杠）
            MIRROR_REGISTRY=$(echo "$MIRROR_REGISTRY" | sed -e 's|^https\?://||' -e 's|/$||')
            # 验证镜像源有效性
            if ! curl --connect-timeout 5 -s "$MIRROR_REGISTRY" >/dev/null 2>&1; then
                echo -e "${RED}警告: 镜像源 ${MIRROR_REGISTRY} 不可访问，使用默认源${NC}"
                MIRROR_REGISTRY=$(echo "$DEFAULT_MIRROR" | sed -e 's|^https\?://||' -e 's|/$||')
            fi
            echo -e "${GREEN}使用镜像源: ${MIRROR_REGISTRY}${NC}"
            ;;
        *)
            # 离线状态不使用镜像源
            MIRROR_REGISTRY=""
            ;;
    esac
}

# 转换镜像地址
convert_image_address() {
    local image=$1
    # 如果没有镜像源，直接返回原始镜像
    if [ -z "$MIRROR_REGISTRY" ]; then
        echo "$image"
        return
    fi
    # 分离镜像名称和标签
    local image_name=${image%%:*}
    local image_tag=${image#*:}
    [ "$image_name" == "$image_tag" ] && image_tag="latest"
    # 处理官方镜像（library）
    if [[ "$image_name" == *"/"* ]]; then
        echo "${MIRROR_REGISTRY}/${image_name}:${image_tag}"
    else
        echo "${MIRROR_REGISTRY}/library/${image_name}:${image_tag}"
    fi
}

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local progress=$((current * PROGRESS_WIDTH / total))
    local bar=""
    for ((i=0; i<progress; i++)); do bar+="█"; done
    for ((i=progress; i<PROGRESS_WIDTH; i++)); do bar+="░"; done
    printf "\r${BLUE}[%s] %d%%${NC}" "$bar" "$percent"
}

# 获取简单镜像名称，包含版本号
get_versioned_image_name() {
    local image=$1
    # 提取镜像名称的最后一部分，包含版本号（如 langgenius/dify-api:1.5.1 -> dify-api.1.5.1）
    local name=$(echo "$image" | awk -F'/' '{print $NF}' | sed 's/:/./')
    echo "$name"
}

# 处理错误并重试
handle_error() {
    local step=$1
    local cmd=$2
    local retry_count=0
    local start_time=$(date +%s)
    # 打印将要执行的命令
    echo -e "${YELLOW}执行命令: ${NC}${BOLD}$cmd${NORMAL}"
    while [ $retry_count -lt $RETRY_LIMIT ]; do
        if eval "$cmd" 2>/tmp/error.log; then
            local end_time=$(date +%s)
            echo -e "  ${GREEN}✓ 完成 (耗时: $(format_duration $((end_time - start_time))))${NC}"
            rm -f /tmp/error.log
            return 0
        else
            retry_count=$((retry_count + 1))
            echo -e "\n${RED}✗ $step 失败 (尝试 $retry_count/$RETRY_LIMIT)${NC}"
            echo -e "${RED}错误详情: $(cat /tmp/error.log)${NC}"
            read -rp "是否重试? [y/n]: " retry_choice
            [[ "$retry_choice" != "y" ]] && { echo -e "${RED}操作已取消${NC}"; exit 1; }
        fi
    done
    echo -e "${RED}错误: 超过最大重试次数${NC}"
    exit 1
}

# 获取自动启动的镜像列表
get_image_list() {
    local compose_file=$1
    local json_output
    # 使用docker compose config的JSON输出模式
    json_output=$(sudo docker compose -f "$compose_file" config --format json 2>/tmp/error.log)
    if [ -z "$json_output" ]; then
        echo -e "${RED}错误: 无法解析docker-compose文件${NC}"
        echo -e "${RED}错误详情: $(cat /tmp/error.log)${NC}"
        exit 1
    fi
    # 使用jq（如果可用）提取自动启动的镜像
    if command_exists jq; then
        echo "$json_output" | jq -r '.services[] | select(.restart != "no" and .restart != "on-failure:0" and .image != null) | .image' | grep -v '^$' | sort | uniq
    else
        # 回退到grep，严格匹配image字段
        echo "$json_output" | grep -oP '"image": "\K[^"]+' | grep -v '^$' | sort | uniq
    fi
}

# 检查镜像是否已存在
image_exists() {
    local image=$1
    sudo docker images -q "$image" | grep -q . && return 0 || return 1
}

# 服务器A功能
server_a_functions() {
    echo -e "${GREEN}=== 当前为服务器A (可联网) ===${NC}"
    local start_time=$(date +%s)
    # 查找Compose文件
    [ -f "docker-compose.yaml" ] && COMPOSE_FILE="docker-compose.yaml" || COMPOSE_FILE="docker-compose.yml"
    [ ! -f "$COMPOSE_FILE" ] && { echo -e "${RED}错误: 未找到docker-compose文件${NC}"; exit 1; }
    echo -e "${GREEN}使用Compose文件: $COMPOSE_FILE${NC}"

    # 获取镜像列表
    mapfile -t IMAGES < <(get_image_list "$COMPOSE_FILE")
    [ ${#IMAGES[@]} -eq 0 ] && { echo -e "${RED}错误: 未找到有效镜像定义${NC}"; exit 1; }
    local total=${#IMAGES[@]}
    echo -e "${GREEN}发现 $total 个镜像${NC}"
    echo -e "${YELLOW}镜像列表:${NC}"
    for img in "${IMAGES[@]}"; do echo "  - $img"; done

    # 拉取镜像
    echo -e "\n\n${YELLOW}开始拉取镜像...${NC}"
    local current=0
    for img in "${IMAGES[@]}"; do
        current=$((current + 1))
        echo -e "\n${BLUE}[$current/$total] 拉取镜像: $img${NC}"
        # 验证镜像名称是否有效
        [ -z "$img" ] && { echo -e "${RED}错误: 镜像名称为空${NC}"; exit 1; }
        local pull_image=$(convert_image_address "$img")
        [ "$pull_image" != "$img" ] && echo -e "  使用镜像源: ${YELLOW}$pull_image${NC}"
        handle_error "拉取镜像" "sudo docker pull \"$pull_image\""
        [ "$pull_image" != "$img" ] && handle_error "标记镜像" "sudo docker tag \"$pull_image\" \"$img\""
        show_progress $current $total
    done

    # 保存镜像
    echo -e "\n\n${YELLOW}开始保存镜像...${NC}"
    current=0
    for img in "${IMAGES[@]}"; do
        current=$((current + 1))
        local img_file="$(get_versioned_image_name "$img").tar"
        local image_tag=${img#*:}
        [ "$img" == "${img%:*}" ] && image_tag="latest"
        echo -e "\n${BLUE}[$current/$total] 保存镜像: $img_file${NC}"
        # 检查是否已存在同名tar文件
        if [ -f "$img_file" ]; then
            if [[ "$image_tag" =~ ^($SPECIAL_VERSIONS)$ ]]; then
                echo -e "  ${YELLOW}检测到特殊版本 ($image_tag)，删除现有 $img_file 并重新保存${NC}"
                rm -f "$img_file"
            else
                echo -e "  ${YELLOW}检测到具体版本 ($image_tag)，跳过保存 $img_file${NC}"
                show_progress $current $total
                continue
            fi
        fi
        handle_error "保存镜像" "sudo docker save -o \"$img_file\" \"$img\""
        echo -e "  ${YELLOW}设置 $img_file 权限为664${NC}"
        chmod 664 "$img_file" 2>/tmp/error.log || { echo -e "${RED}错误: 设置 $img_file 权限失败\n错误详情: $(cat /tmp/error.log)${NC}"; exit 1; }
        show_progress $current $total
    done

    # 生成哈希值
    echo -e "\n\n${YELLOW}开始生成文件哈希...${NC}"
    # 删除现有的image_hashes.txt以避免自我引用
    [ -f "$HASH_FILE" ] && { rm -f "$HASH_FILE"; echo -e "${YELLOW}已删除现有 $HASH_FILE${NC}"; }
    # 初始化files数组，仅包含docker-compose文件和tar文件
    local files=("$COMPOSE_FILE")
    for img in "${IMAGES[@]}"; do
        files+=("$(get_versioned_image_name "$img").tar")
    done
    # 创建新的image_hashes.txt
    > "$HASH_FILE"
    current=0
    for file in "${files[@]}"; do
        current=$((current + 1))
        echo -e "\n${BLUE}[$current/${#files[@]}] 计算哈希: $file${NC}"
        local start_time=$(date +%s)
        [ ! -f "$file" ] && { echo -e "${RED}错误: 文件 $file 不存在${NC}"; exit 1; }
        local hash=$(sha256sum "$file" | awk '{print $1}')
        echo "$file $hash" >> "$HASH_FILE"
        echo -e "  ${YELLOW}哈希值: $hash${NC}"
        # 获取文件大小
        local size
        size=$(stat -f %z "$file" 2>/dev/null)
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(stat -c %s "$file" 2>/dev/null)
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(ls -l -- "$file" 2>/dev/null | awk '{print $5}' || echo "0")
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            if command_exists du; then
                size=$(du -b -- "$file" 2>/dev/null | awk '{print $1}' || echo "0")
            else
                size=0
            fi
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}警告: 无法获取文件 $file 的大小，显示为 0B${NC}" >&2
        fi
        local formatted_size=$(format_file_size $size)
        echo -e "  ${YELLOW}文件大小: $formatted_size${NC}"
        echo -e "  ${GREEN}✓ 完成 (耗时: $(format_duration $((end_time - start_time))))${NC}"
        show_progress $current ${#files[@]}
    done
    # 设置image_hashes.txt权限
    echo -e "\n  ${YELLOW}设置 $HASH_FILE 权限为664${NC}"
    chmod 664 "$HASH_FILE" 2>/tmp/error.log || { echo -e "${RED}错误: 设置 $HASH_FILE 权限失败\n错误详情: $(cat /tmp/error.log)${NC}"; exit 1; }

    local end_time=$(date +%s)
    # 包含image_hashes.txt在需要复制的文件列表中
    local copy_files=("${files[@]}" "$HASH_FILE")
    echo -e "\n${GREEN}✓ 服务器A操作完成 (耗时: $(format_duration $((end_time - start_time))))${NC}"
    echo -e "${YELLOW}请将以下文件复制到服务器B:${NC}"
    # 计算最长文件名长度以对齐输出
    local max_length=0
    for file in "${copy_files[@]}"; do
        length=${#file}
        [ $length -gt $max_length ] && max_length=$length
    done
    # 计算文件大小并对齐输出
    for file in "${copy_files[@]}"; do
        # 尝试多种方法获取文件大小
        local size
        size=$(stat -f %z "$file" 2>/dev/null)
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(stat -c %s "$file" 2>/dev/null)
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(ls -l -- "$file" 2>/dev/null | awk '{print $5}' || echo "0")
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            if command_exists du; then
                size=$(du -b -- "$file" 2>/dev/null | awk '{print $1}' || echo "0")
            else
                size=0
            fi
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}警告: 无法获取文件 $file 的大小，显示为 0B${NC}" >&2
        fi
        local formatted_size=$(format_file_size $size)
        printf "  - %-${max_length}s %s\n" "$file" "$formatted_size"
    done
}

# 服务器B功能
server_b_functions() {
    echo -e "${GREEN}=== 当前为服务器B (离线环境) ===${NC}"
    local start_time=$(date +%s)
    # 检查哈希文件
    [ ! -f "$HASH_FILE" ] && { echo -e "${RED}错误: 缺少哈希文件 $HASH_FILE${NC}"; exit 1; }
    # 查找Compose文件
    [ -f "docker-compose.yaml" ] && COMPOSE_FILE="docker-compose.yaml" || COMPOSE_FILE="docker-compose.yml"
    [ ! -f "$COMPOSE_FILE" ] && { echo -e "${RED}错误: 未找到docker-compose文件${NC}"; exit 1; }
    echo -e "${GREEN}使用Compose文件: $COMPOSE_FILE${NC}"

    # 校验文件完整性
    echo -e "\n\n${YELLOW}开始校验文件完整性...${NC}"
    local total_files=$(wc -l < "$HASH_FILE")
    local current_file=0
    while IFS=' ' read -r file expected_hash; do
        current_file=$((current_file + 1))
        echo -e "\n${BLUE}[$current_file/$total_files] 校验文件: $file${NC}"
        local start_time=$(date +%s)
        [ ! -f "$file" ] && { echo -e "${RED}错误: 文件缺失 $file${NC}"; exit 1; }
        local actual_hash=$(sha256sum "$file" | awk '{print $1}')
        echo -e "  ${YELLOW}哈希值: $actual_hash${NC}"
        # 获取文件大小
        local size
        size=$(stat -f %z "$file" 2>/dev/null)
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(stat -c %s "$file" 2>/dev/null)
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            size=$(ls -l -- "$file" 2>/dev/null | awk '{print $5}' || echo "0")
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            if command_exists du; then
                size=$(du -b -- "$file" 2>/dev/null | awk '{print $1}' || echo "0")
            else
                size=0
            fi
        fi
        if ! [[ "$size" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}警告: 无法获取文件 $file 的大小，显示为 0B${NC}" >&2
        fi
        local formatted_size=$(format_file_size $size)
        echo -e "  ${YELLOW}文件大小: $formatted_size${NC}"
        [ "$actual_hash" != "$expected_hash" ] && { echo -e "${RED}错误: 文件校验失败 $file\n  期望: $expected_hash\n  实际: $actual_hash${NC}"; exit 1; }
        local end_time=$(date +%s)
        echo -e "  ${GREEN}✓ 校验通过 (耗时: $(format_duration $((end_time - start_time))))${NC}"
        show_progress $current_file $total_files
    done < "$HASH_FILE"

    # 获取镜像列表
    mapfile -t IMAGES < <(get_image_list "$COMPOSE_FILE")
    [ ${#IMAGES[@]} -eq 0 ] && { echo -e "${RED}错误: 未找到有效镜像定义${NC}"; exit 1; }
    local total=${#IMAGES[@]}
    echo -e "\n${GREEN}发现 $total 个镜像${NC}"
    echo -e "${YELLOW}镜像列表:${NC}"
    for img in "${IMAGES[@]}"; do echo "  - $img"; done

    # 加载镜像
    echo -e "\n\n${YELLOW}开始加载镜像...${NC}"
    current=0
    for img in "${IMAGES[@]}"; do
        current=$((current + 1))
        local img_file="$(get_versioned_image_name "$img").tar"
        local image_tag=${img#*:}
        [ "$img" == "${img%:*}" ] && image_tag="latest"
        echo -e "\n${BLUE}[$current/$total] 加载镜像: $img_file${NC}"
        # 检查镜像是否已存在，且非特殊版本
        if image_exists "$img" && [[ ! "$image_tag" =~ ^($SPECIAL_VERSIONS)$ ]]; then
            echo -e "  ${YELLOW}镜像 $img 已存在，跳过加载${NC}"
            show_progress $current $total
            continue
        fi
        # 对于特殊版本，强制加载并显示提示
        if [[ "$image_tag" =~ ^($SPECIAL_VERSIONS)$ ]]; then
            echo -e "  ${YELLOW}检测到特殊版本 ($image_tag)，强制加载 $img_file${NC}"
        fi
        # 设置tar文件权限
        echo -e "  ${YELLOW}设置 $img_file 权限为664${NC}"
        chmod 664 "$img_file" 2>/tmp/error.log || { echo -e "${RED}错误: 设置 $img_file 权限失败\n错误详情: $(cat /tmp/error.log)${NC}"; exit 1; }
        handle_error "加载镜像" "sudo docker load -i \"$img_file\""
        show_progress $current $total
    done

    # 输出总耗时
    local end_time=$(date +%s)
    echo -e "\n${GREEN}✓ 服务器B操作完成 (总耗时: $(format_duration $((end_time - start_time))))${NC}"
    # 询问是否启动服务
    echo -e "${YELLOW}是否执行 'sudo docker compose up -d' 启动服务? [y/n]:${NC}"
    read -rp "" choice
    if [[ "$choice" == "y" ]]; then
        echo -e "\n${YELLOW}启动Docker服务...${NC}"
        handle_error "启动服务" "sudo docker compose -f \"$COMPOSE_FILE\" up -d"
        echo -e "\n${GREEN}✓ 服务启动成功${NC}"
        echo -e "${YELLOW}运行状态:${NC}"
        sudo docker compose -f "$COMPOSE_FILE" ps
    else
        echo -e "${YELLOW}已跳过服务启动，您可稍后 cd 到 $(pwd) 并手动执行 'sudo docker compose up -d'${NC}"
    fi
}

# 主函数
main() {
    local total_start_time=$(date +%s)
    # 输出系统信息
    echo -e "${BOLD}${GREEN}===== 离线 Docker Compose 部署助手脚本 =====${NORMAL}"
    echo -e "${GREEN}>>> Powered by ${YELLOW}${BOLD}WeiQ_Orz${NORMAL}${GREEN} <<<"
    echo -e "服务器类型: ${BOLD}$(uname -a)${NORMAL}"
    echo -e "Docker版本: ${BOLD}$(docker --version 2>/dev/null || echo '未安装')${NORMAL}"
    echo -e "Docker Compose版本: ${BOLD}$(docker compose version 2>/dev/null || echo '未安装')${NORMAL}"
    echo -e "当前路径: ${BOLD}$(pwd)${NORMAL}"
    echo -e "可用空间: ${BOLD}$(df -h . | awk 'NR==2 {print $4}')${NORMAL}"

    # 检查sudo权限
    check_sudo
    # 检查网络状态
    NETWORK_STATUS=$(check_network)
    echo -e "网络状态: ${BOLD}${NETWORK_STATUS}${NORMAL}"
    # 设置镜像源
    set_mirror_source "$NETWORK_STATUS"

    # 根据网络状态执行相应功能
    case "$NETWORK_STATUS" in
        "great"|"good") server_a_functions ;;
        "bad") server_b_functions ;;
        *) echo -e "${RED}未知网络状态${NC}"; exit 1 ;;
    esac

    local total_end_time=$(date +%s)
    echo -e "\n${GREEN}✓ 脚本执行完成 (总耗时: $(format_duration $((total_end_time - total_start_time))))${NC}"
}

# 执行主函数
main