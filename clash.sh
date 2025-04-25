#!/bin/bash

# ==================== 终端控制 ====================
# 初始化终端设置
init_terminal() {
    # 保存原始终端设置
    original_stty=$(stty -g 2>/dev/null || true)

    # 设置终端为规范模式
    stty sane 2>/dev/null || true

    # 启用光标显示
    printf "\033[?25h"

    # 清除所有格式化
    printf "\033[0m"

    # 清屏并将光标移到首位
    printf "\033[2J\033[H"
}

# 清理终端设置
cleanup_terminal() {
    # 恢复原始终端设置
    [ -n "$original_stty" ] && stty "$original_stty" 2>/dev/null || true

    # 确保光标可见
    printf "\033[?25h"

    # 重置所有格式化
    printf "\033[0m"

    # 清除屏幕并将光标移到开头
    printf "\033[2J\033[H"
}

# 设置终端清理trap
setup_terminal_trap() {
    # 修改INT处理，只进行终端清理但不停止clash进程
    trap 'cleanup_terminal; printf "\n退出脚本...\n"; exit 130' INT
    trap 'cleanup_terminal' EXIT
}

# 初始化终端
init_terminal
setup_terminal_trap

# ==================== 日志系统 ====================
# 日志级别
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# 当前日志级别
CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO

# 日志文件
LOG_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/clash-shell.log"

# 日志函数
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ $level -ge $CURRENT_LOG_LEVEL ]; then
        case $level in
        $LOG_LEVEL_DEBUG) level_str="DEBUG" ;;
        $LOG_LEVEL_INFO) level_str="INFO " ;;
        $LOG_LEVEL_WARN) level_str="WARN " ;;
        $LOG_LEVEL_ERROR) level_str="ERROR" ;;
        esac

        echo "[$timestamp] $level_str: $message" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] $level_str: $message"
    fi
}

# 错误处理函数
handle_error() {
    local error_code=$1
    local error_message=$2

    log $LOG_LEVEL_ERROR "$error_message (错误代码: $error_code)"

    case $error_code in
    1) log $LOG_LEVEL_ERROR "权限错误：请检查是否有足够的权限" ;;
    2) log $LOG_LEVEL_ERROR "文件系统错误：无法访问必要的文件或目录" ;;
    3) log $LOG_LEVEL_ERROR "网络错误：无法连接到服务器或下载文件" ;;
    4) log $LOG_LEVEL_ERROR "配置错误：配置文件格式错误或缺少必要配置" ;;
    *) log $LOG_LEVEL_ERROR "未知错误" ;;
    esac

    # 清理临时文件或恢复之前的状态
    cleanup_on_error
}

# 错误清理函数
cleanup_on_error() {
    log $LOG_LEVEL_DEBUG "执行错误清理..."
    # 停止正在运行的进程
    stop_clash 2>/dev/null

    # 恢复之前的代理设置
    if [ -f "/tmp/clash_proxy_backup" ]; then
        sudo cp "/tmp/clash_proxy_backup" /etc/environment
        rm "/tmp/clash_proxy_backup"
    fi
}

# 初始化日志
init_logging() {
    # 创建日志目录和文件（如果不存在）
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # 创建或清空日志文件
    touch "$LOG_FILE" 2>/dev/null && : >"$LOG_FILE" 2>/dev/null || true

    # 设置日志文件权限
    chmod 644 "$LOG_FILE" 2>/dev/null || true

    log $LOG_LEVEL_INFO "Clash Shell 启动"
    log $LOG_LEVEL_INFO "系统信息: $(uname -a)"
    log $LOG_LEVEL_INFO "脚本版本: 1.0.0"
}

# 检查权限并尝试获取
check_and_get_privileges() {
    # 如果已经是 root，直接返回
    if [ $(id -u) -eq 0 ]; then
        return 0
    fi

    # 检查是否可以使用 sudo
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            # sudo 可用且已经有权限
            return 0
        else
            echo "需要管理员权限来运行此脚本"
            # 尝试获取 sudo 权限
            if sudo -v; then
                return 0
            fi
        fi
    else
        # 如果没有 sudo，检查是否有 doas（OpenBSD 风格的权限提升）
        if command -v doas >/dev/null 2>&1; then
            if doas true; then
                alias sudo='doas'
                return 0
            fi
        fi
    fi

    echo "错误：无法获取管理员权限。请使用 sudo 或 root 账户运行此脚本。"
    exit 1
}

# 初始化日志系统
init_logging

# 替换原来的权限检查
if ! check_and_get_privileges; then
    log $LOG_LEVEL_ERROR "权限检查失败"
    exit 1
fi

# cd 到脚本所在目录
cd "$(dirname "$(readlink -f "$0")")"

# 处理开机启动的参数在脚本末尾

# ==================== 变量定义 ====================
# 将配置文件路径修改为脚本所在目录，解决权限问题
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="$script_dir/config.ini"
declare -A config_array # 声明关联数组

# 定义基础目录
init_dir="$script_dir/init"
core_dir="$script_dir/core"

profiles_dir="$(dirname "$(readlink -f "$0")")/config"
home_dir="$HOME/.config/mihomo"

# 获取脚本的完整路径
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

# 检查setsid命令是否可用
check_setsid() {
    if command -v setsid >/dev/null 2>&1; then
        log $LOG_LEVEL_DEBUG "setsid命令可用"
        return 0
    else
        log $LOG_LEVEL_ERROR "错误：setsid命令不可用，请先安装setsid"
        echo "错误：setsid命令不可用，请先安装setsid。在大多数Linux系统上，可以通过以下命令安装："
        echo "  - Debian/Ubuntu: sudo apt-get install util-linux"
        echo "  - CentOS/RHEL: sudo yum install util-linux"
        echo "  - Alpine: sudo apk add util-linux"
        echo "  - Arch Linux: sudo pacman -S util-linux"
        return 1
    fi
}

# ==================== 初始化 ====================
# 初始化配置文件
init_config_file() {
    # 确保配置文件所在目录存在
    mkdir -p "$(dirname "$config_file")" 2>/dev/null || sudo mkdir -p "$(dirname "$config_file")" 2>/dev/null

    # 确保配置文件存在
    if [ ! -f "$config_file" ]; then
        touch "$config_file" 2>/dev/null || sudo touch "$config_file" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法创建配置文件: $config_file"
            return 1
        }
        # 设置适当的权限
        chmod 644 "$config_file" 2>/dev/null || sudo chmod 644 "$config_file" 2>/dev/null
        # 写入默认配置
        cat >"$config_file" <<EOF
# Clash配置文件
default=.config.yaml
mixed-port=7890
port=7891
socks-port=7892
EOF
        log $LOG_LEVEL_INFO "创建默认配置文件: $config_file"
    fi
    return 0
}

# ==================== 初始化 ====================
# 初始化配置目录
init_config_dirs() {
    # 创建必要的目录
    for dir in "$core_dir" "$profiles_dir"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" 2>/dev/null || {
                echo "无法创建目录: $dir"
                return 1
            }
        fi
    done

    # 确保核心目录存在
    if [ ! -d "$core_dir" ]; then
        mkdir -p "$core_dir" 2>/dev/null || {
            echo "无法创建核心目录: $core_dir"
            return 1
        }
    fi

    # 如果没有配置文件，创建默认配置
    if [ ! -f "$profiles_dir/.config.yaml" ]; then
        mkdir -p "$profiles_dir" 2>/dev/null || {
            echo "无法创建配置目录: $profiles_dir"
            return 1
        }
        if ! cat >"$profiles_dir/.config.yaml" <<'EOF'; then
mixed-port: 7890
allow-lan: false
external-controller: 127.0.0.1:50832
secret: $(openssl rand -hex 16)
EOF
            echo "无法创建默认配置文件"
            return 1
        fi
    fi
    # 复制必要的文件
    if [ ! -f "$home_dir/geoip.metadb" ] && [ -f "$init_dir/geoip.metadb" ]; then
        mkdir -p "$home_dir" 2>/dev/null || {
            echo "无法创建主目录: $home_dir"
            return 1
        }
        cp "$init_dir/geoip.metadb" "$home_dir/" || {
            echo "无法复制 geoip.metadb 文件"
            return 1
        }
    fi

    # 输出创建的目录信息用于调试
    log $LOG_LEVEL_DEBUG "初始化目录:"
    log $LOG_LEVEL_DEBUG "core_dir: $core_dir"
    log $LOG_LEVEL_DEBUG "profiles_dir: $profiles_dir"
    log $LOG_LEVEL_DEBUG "home_dir: $home_dir"

    return 0
}

# 在脚本开始部分调用初始化函数
if ! init_config_dirs; then
    echo "初始化配置目录失败，请检查权限"
    exit 1
fi

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
    x86_64 | amd64)
        echo "amd64"
        ;;
    aarch64 | arm64)
        echo "arm64"
        ;;
    armv7* | armv8* | armhf)
        echo "armv7"
        ;;
    arm*)
        echo "arm"
        ;;
    i386 | i686)
        echo "386"
        ;;
    mips64)
        echo "mips64"
        ;;
    mips)
        echo "mips"
        ;;
    *)
        echo "unknown"
        return 1
        ;;
    esac
}

# 复制相应架构的二进制文件
copy_arch_binaries() {
    local arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then
        log $LOG_LEVEL_ERROR "不支持的系统架构: $(uname -m)"
        log $LOG_LEVEL_ERROR "请手动下载对应的mihomo-core、yq以及jq文件到core目录"
        return 1
    fi

    local arch_dir
    case "$arch" in
    "amd64") arch_dir="x86_64" ;;
    "arm64") arch_dir="arm64" ;;
    *) arch_dir="$arch" ;;
    esac

    # 检查二进制文件目录是否存在
    if [ ! -d "$init_dir/binaries/$arch_dir" ]; then
        log $LOG_LEVEL_ERROR "未找到对应架构($arch)的二进制文件目录: $init_dir/binaries/$arch_dir"
        return 1
    fi

    # 创建核心目录（如果不存在）
    mkdir -p "$core_dir" 2>/dev/null || {
        log $LOG_LEVEL_ERROR "无法创建核心目录: $core_dir"
        return 1
    }

    # 复制对应架构的二进制文件
    case "$arch" in
    "amd64")
        cp "$init_dir/binaries/$arch_dir/mihomo-linux-amd64" "$core_dir/mihomo-core" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 mihomo-core"
            return 1
        }
        cp "$init_dir/binaries/$arch_dir/yq_linux_amd64" "$core_dir/yq" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 yq"
            return 1
        }
        cp "$init_dir/binaries/$arch_dir/jq-linux-amd64" "$core_dir/jq" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 jq"
            return 1
        }
        ;;
    "arm64")
        cp "$init_dir/binaries/$arch_dir/mihomo-linux-arm64" "$core_dir/mihomo-core" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 mihomo-core"
            return 1
        }
        cp "$init_dir/binaries/$arch_dir/yq_linux_arm64" "$core_dir/yq" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 yq"
            return 1
        }
        cp "$init_dir/binaries/$arch_dir/jq-linux-arm64" "$core_dir/jq" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法复制 jq"
            return 1
        }
        ;;
    *)
        log $LOG_LEVEL_ERROR "架构 $arch 暂不支持"
        return 1
        ;;
    esac

    # 设置执行权限
    chmod +x "$core_dir"/* 2>/dev/null || {
        log $LOG_LEVEL_ERROR "无法设置执行权限"
        return 1
    }

    log $LOG_LEVEL_INFO "成功复制并设置二进制文件权限"
    return 0
}

# 在初始化部分使用新的架构检测函数
echo "检测系统架构..."
arch=$(detect_arch)
if [ "$?" -eq 0 ]; then
    echo "系统架构: $arch"
    copy_arch_binaries
else
    echo "无法确定系统架构，请手动设置"
fi

yq() {
    chmod +x $core_dir/yq
    "$core_dir/yq" "$@"
}
jq() {
    chmod +x $core_dir/jq
    "$core_dir/jq" "$@"
}
# 创建分割行
create_line() {
    printf "\n%s\n" "====================================="
}

# ==================== 配置处理 ====================
# 函数：读取config.ini到数组
read_config_to_array() {
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        log $LOG_LEVEL_WARN "配置文件不存在，将创建默认配置"
        init_config_file
        return $?
    fi

    # 检查是否有读取权限
    if [ ! -r "$config_file" ]; then
        # 尝试修改权限
        chmod 644 "$config_file" 2>/dev/null || sudo chmod 644 "$config_file" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法获取配置文件读取权限: $config_file"
            return 1
        }
    fi

    # 读取配置文件
    while IFS="=" read -r key value; do
        # 忽略空行和注释行
        if [[ -z $key || $key == \#* ]]; then
            continue
        fi
        # 去除首尾空格
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 添加到关联数组中
        config_array["$key"]=$value
    done <"$config_file"

    return 0
}

# 函数：将数组写回config.ini
write_array_to_config() {
    # 确保有权限写入配置文件
    if [ ! -w "$config_file" ]; then
        # 尝试修改权限
        chmod 644 "$config_file" 2>/dev/null || sudo chmod 644 "$config_file" 2>/dev/null || {
            log $LOG_LEVEL_ERROR "无法获取配置文件写入权限: $config_file"
            return 1
        }
    fi

    # 创建临时文件并写入
    local temp_file=$(mktemp)
    for key in "${!config_array[@]}"; do
        # 写入键值对到临时文件
        echo "$key=${config_array[$key]}" >>"$temp_file"
    done

    # 替换原文件
    mv "$temp_file" "$config_file" 2>/dev/null || sudo mv "$temp_file" "$config_file" 2>/dev/null || {
        log $LOG_LEVEL_ERROR "无法更新配置文件: $config_file"
        rm "$temp_file" 2>/dev/null
        return 1
    }

    return 0
}

# 设置数组指定键的值，并写入配置文件
set_config() {
    local key=$1
    local value=$2
    config_array["$key"]=$value
    write_array_to_config
}

# 函数：设置配置默认值，如果配置不存在则设置默认值
set_default_config() {
    # 设置默认值,如果general.port不存在就设置默认值
    if [[ -z ${config_array["default"]} || ! -f "$profiles_dir/${config_array["default"]}" ]]; then
        set_config "default" ".config.yaml"
    fi
    # 设置默认值,如果mix-port不存在就设置默认值
    if [[ -z ${config_array["mixed-port"]} ]]; then
        set_config "mixed-port" "7890"
    fi
    # 设置默认值,如果port不存在就设置默认值
    if [[ -z ${config_array["port"]} ]]; then
        set_config "port" "7891"
    fi
    # 设置默认值,如果socks-port不存在就设置默认值
    if [[ -z ${config_array["socks-port"]} ]]; then
        set_config "socks-port" "7892"
    fi
}

# ==================== api接口处理 ====================
# 函数：从default中获取external-controller和secret存入apiurl和secret
get_api_url() {
    local profile="${config_array["default"]}"
    if [[ -z $profile ]]; then
        echo "请先选择一个配置文件"
        return
    fi
    local apiurl=$(grep -oP "external-controller: \K[^\n]+" "$profiles_dir/$profile")
    local secret=$(grep -oP "secret: \K[^\n]+" "$profiles_dir/$profile")
    set_config "apiurl" "$apiurl"
    set_config "secret" "$secret"
}
# 封装get请求，参数为url
get_request() {
    url=$1
    local apiurl=${config_array["apiurl"]}
    local secret=${config_array["secret"]}
    local response=$(curl -s -X GET http://"$apiurl$url" -H "Authorization: Bearer $secret")
    echo "$response"
}
# 封装put请求，参数为url和data
put_request() {
    local url=$1
    local data=$2
    echo "put请求：$url"
    echo "put请求数据：$data"
    local apiurl=${config_array["apiurl"]}
    local secret=${config_array["secret"]}
    local response=$(curl -s -X PUT http://"$apiurl$url" -H "Authorization: Bearer $secret" -d "$data")
    echo "$response"
}
# 封装patch请求，参数为url和data
patch_request() {
    local url=$1
    local data=$2
    local apiurl=${config_array["apiurl"]}
    local secret=${config_array["secret"]}
    local response=$(curl -s -X PATCH http://"$apiurl$url" -H "Authorization: Bearer $secret" -d "$data")
    echo "$response"
}

# ==================== Clash处理 ====================
# 把default字段的文件复制到home_dir下
copy_default_to_home() {
    local profile="${config_array["default"]}"
    \cp -r "$profiles_dir/$profile" "$home_dir"
}
# 替换配置文件里的一些设置字段
replace_config() {
    local profile="${config_array["default"]}"
    local mixed_port="${config_array["mixed-port"]}"
    local port="${config_array["port"]}"
    local socks_port="${config_array["socks-port"]}"

    # 创建临时配置文件
    local temp_config=$(mktemp)
    cp "$home_dir/$profile" "$temp_config"

    # 使用try-catch风格的错误处理
    {
        # 验证原始配置文件格式
        if ! yq eval . "$temp_config" >/dev/null 2>&1; then
            log $LOG_LEVEL_ERROR "配置文件格式错误"
            rm "$temp_config"
            return 1
        fi

        # 更新端口配置
        yq eval -i ".mixed-port = $mixed_port" "$temp_config"
        yq eval -i ".port = $port" "$temp_config"
        yq eval -i ".socks-port = $socks_port" "$temp_config"
        yq eval -i '.log-level = "debug"' "$temp_config"

        # 如果存在DNS和TUN配置文件，则尝试合并
        if [ -f "$init_dir/dns.yaml" ]; then
            yq eval -i ". *+ load(\"$init_dir/dns.yaml\")" "$temp_config"
        fi
        if [ -f "$init_dir/tun.yaml" ]; then
            yq eval -i ". *+ load(\"$init_dir/tun.yaml\")" "$temp_config"
        fi

        # 验证修改后的配置文件格式
        if ! yq eval . "$temp_config" >/dev/null 2>&1; then
            log $LOG_LEVEL_ERROR "配置文件修改后格式错误"
            rm "$temp_config"
            return 1
        fi

        # 配置文件验证成功，移动到最终位置
        mv "$temp_config" "$home_dir/$profile"
        chmod 644 "$home_dir/$profile"

        return 0
    } || {
        # 清理临时文件
        [ -f "$temp_config" ] && rm "$temp_config"
        return 1
    }

}
# 使用default启动clash
start_clash() {
    stop_clash
    local profile="${config_array["default"]}"
    local log_dir="$home_dir/logs"
    local pid_file="$home_dir/clash.pid"

    # 1. 检查和创建必要的目录
    for dir in "$core_dir" "$home_dir" "$log_dir"; do
        if ! mkdir -p "$dir" 2>/dev/null; then
            sudo mkdir -p "$dir" || {
                handle_error 2 "无法创建目录: $dir"
                return 1
            }
            sudo chown -R "$USER:$USER" "$dir"
        fi
    done

    # 2. 检查必要文件
    if [ ! -f "$core_dir/mihomo-core" ]; then
        handle_error 2 "核心文件不存在: mihomo-core"
        return 1
    fi

    if [ ! -f "$profiles_dir/$profile" ]; then
        handle_error 2 "配置文件不存在: $profile"
        return 1
    fi

    # 3. 复制和处理配置文件
    if ! copy_default_to_home; then
        handle_error 2 "无法复制配置文件"
        return 1
    fi

    if ! replace_config; then
        handle_error 4 "配置文件处理失败"
        return 1
    fi

    # 4. 设置权限
    sudo chmod 755 "$core_dir/mihomo-core" || {
        handle_error 1 "无法设置执行权限"
        return 1
    }

    log $LOG_LEVEL_INFO "正在启动 clash..."

    # 6. 检查setsid命令是否可用，如果不可用则直接退出
    if ! check_setsid; then
        return 1
    fi

    # 7. 启动进程，使用setsid创建新会话，完全脱离当前终端会话
    mkdir -p "$log_dir" 2>/dev/null || sudo mkdir -p "$log_dir" 2>/dev/null
    touch "$log_dir/clash.log" 2>/dev/null || sudo touch "$log_dir/clash.log" 2>/dev/null
    sudo chmod 777 "$log_dir" "$log_dir/clash.log" 2>/dev/null

    setsid sudo "$core_dir/mihomo-core" -f "$home_dir/$profile" -d "$home_dir" >"$log_dir/clash.log" 2>&1 &
    local pid=$!

    # 7. 等待并验证进程
    sleep 2
    if ! ps -p $pid >/dev/null; then
        handle_error 1 "clash 进程启动失败，请检查日志: $log_dir/clash.log"
        return 1
    fi

    # 8. 保存 PID
    echo $pid >"$pid_file"
    log $LOG_LEVEL_INFO "clash 启动成功 (PID: $pid)"

    # 9. 更新 API 配置
    get_api_url
    sleep 1
    return 0
}

# 停止clash
stop_clash() {
    # 使用sudo提升权限
    sudo pkill -f "mihomo-core" 2>/dev/null || pkill -f "mihomo-core" 2>/dev/null
    echo "clash已停止"
}

# 选择配置文件
selecte_profile() {
    local profile=$1
    set_config "default" "$profile"
    put_request "/configs?force=true" "{\"path\":\"$profiles_dir/$profile\",\"payload\": \"\"}"
    get_api_url
    echo "已选择配置文件: $profile"
}

# 下载配置文件
download_url() {
    read -p "输入订阅地址: " -e url
    local config_dir="$(dirname "$(readlink -f "$0")")/config"
    mkdir -p "$config_dir"
    wget --content-disposition -P "$profiles_dir" "$url"
    filename=$(ls -t "$profiles_dir" | head -n 1)
    set_config "default" "$filename"
    show_main_menu
}

# 设置系统代理
enable_proxy() {
    # 尝试设置系统级代理
    if [ -w /etc/environment ]; then
        echo "http_proxy=\"http://127.0.0.1:7890\"" | sudo tee -a /etc/environment >/dev/null
        echo "https_proxy=\"https://127.0.0.1:7890\"" | sudo tee -a /etc/environment >/dev/null
    fi

    # 设置用户级代理配置
    local proxy_config="\nexport http_proxy=\"http://127.0.0.1:7890\"\nexport https_proxy=\"https://127.0.0.1:7890\""

    # 为不同的 shell 添加配置
    for rc_file in ~/.bashrc ~/.zshrc ~/.profile; do
        if [ -f "$rc_file" ]; then
            if ! grep -q "http_proxy" "$rc_file"; then
                echo -e "$proxy_config" >>"$rc_file"
            fi
        fi
    done

    # 立即生效
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="https://127.0.0.1:7890"

    echo "Proxy enabled: http://127.0.0.1:7890"
}

disable_proxy() {
    # 移除系统级代理
    if [ -w /etc/environment ]; then
        sudo sed -i '/http_proxy/d' /etc/environment
        sudo sed -i '/https_proxy/d' /etc/environment
    fi

    # 移除用户级代理配置
    for rc_file in ~/.bashrc ~/.zshrc ~/.profile; do
        if [ -f "$rc_file" ]; then
            sed -i '/http_proxy/d' "$rc_file"
            sed -i '/https_proxy/d' "$rc_file"
        fi
    done

    # 立即失效
    unset http_proxy
    unset https_proxy

    echo "Proxy disabled"
}

check_proxy() {
    local proxy_enabled=false

    # 检查系统级代理
    if [ -f /etc/environment ] && grep -q "http_proxy" /etc/environment; then
        echo "System-wide proxy enabled:"
        grep -w "http_proxy\|https_proxy" /etc/environment
        proxy_enabled=true
    fi

    # 检查用户级代理
    for rc_file in ~/.bashrc ~/.zshrc ~/.profile; do
        if [ -f "$rc_file" ] && grep -q "http_proxy" "$rc_file"; then
            echo "User-level proxy enabled in $rc_file:"
            grep -w "http_proxy\|https_proxy" "$rc_file"
            proxy_enabled=true
        fi
    done

    # 检查当前环境变量
    if [ -n "$http_proxy" ] || [ -n "$https_proxy" ]; then
        echo "Current session proxy:"
        echo "http_proxy=$http_proxy"
        echo "https_proxy=$https_proxy"
        proxy_enabled=true
    fi

    if [ "$proxy_enabled" = false ]; then
        echo "No proxy configuration found"
    fi
}
set_proxy() {
    # 判断check_proxy是否为空,如果为空则执行enable_proxy，否则执行disable_proxy
    if [ -z "$(check_proxy)" ]; then
        enable_proxy
    else
        disable_proxy
    fi
}

# 判断clash是否在运行
is_clash_running() {
    if pgrep -f "mihomo-core" >/dev/null; then
        return 0
    else
        return 1
    fi
}

# 检测系统使用的初始化系统
detect_init_system() {
    if pidof systemd >/dev/null 2>&1; then
        echo "systemd"
    elif [ -f /etc/init.d ]; then
        echo "sysvinit"
    elif [ -d /etc/openrc ]; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

# 检查是否已设置开机启动
is_autostart_enabled() {
    local init_system=$(detect_init_system)
    case $init_system in
    "systemd")
        # 所有系统都使用系统级服务
        systemctl is-enabled clash.service &>/dev/null
        return $?
        ;;
    "openrc")
        rc-status default | grep -q "clash"
        return $?
        ;;
    "sysvinit")
        [ -x /etc/init.d/clash ]
        return $?
        ;;
    *)
        # fallback到用户级自启动
        [ -f ~/.config/autostart/clash.desktop ]
        return $?
        ;;
    esac
}

# 设置开机启动
enable_autostart() {
    local script_path=$(readlink -f "${BASH_SOURCE[0]}")
    local init_system=$(detect_init_system)

    case $init_system in
    "systemd")
        # 所有系统都使用系统级服务（需要root权限）
        sudo mkdir -p /etc/systemd/system/
        sudo tee /etc/systemd/system/clash.service >/dev/null <<EOF
[Unit]
Description=Clash Proxy Client
After=network.target

[Service]
Type=oneshot
ExecStartPre=/bin/chmod +x $script_path
ExecStart=$script_path autostart
RemainAfterExit=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl enable clash.service
        ;;
    "openrc")
        # 创建OpenRC服务
        sudo tee /etc/init.d/clash >/dev/null <<EOF
#!/sbin/openrc-run

name=clash
command="$script_path"
command_args="autostart"
pidfile="/var/run/clash.pid"
command_background="yes"

start_pre() {
    chmod +x "$script_path"
}

depend() {
    need net
}
EOF
        sudo chmod +x /etc/init.d/clash
        sudo rc-update add clash default
        ;;
    "sysvinit")
        # 创建SysVinit服务
        sudo tee /etc/init.d/clash >/dev/null <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          clash
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Clash Proxy Client
### END INIT INFO

SCRIPT="$script_path autostart"

case "\$1" in
  start)
    chmod +x $script_path
    \$SCRIPT
    ;;
  stop)
    pkill -f "mihomo-core"
    ;;
  *)
    echo "Usage: /etc/init.d/clash {start|stop}"
    exit 1
    ;;
esac
exit 0
EOF
        sudo chmod +x /etc/init.d/clash
        sudo update-rc.d clash defaults
        ;;
    *)
        # Fallback：创建桌面环境自启动项
        mkdir -p ~/.config/autostart
        cat >~/.config/autostart/clash.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Clash
Exec=bash -c "chmod +x $script_path && sudo $script_path autostart"
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
        ;;
    esac

    set_config "autostart" "true"
    echo "已设置开机启动"
}

# 关闭开机启动
disable_autostart() {
    local init_system=$(detect_init_system)

    case $init_system in
    "systemd")
        # 所有系统都使用系统级服务
        sudo systemctl disable clash.service 2>/dev/null
        sudo rm -f /etc/systemd/system/clash.service
        ;;
    "openrc")
        sudo rc-update del clash default
        sudo rm -f /etc/init.d/clash
        ;;
    "sysvinit")
        sudo update-rc.d clash remove
        sudo rm -f /etc/init.d/clash
        ;;
    *)
        rm -f ~/.config/autostart/clash.desktop
        ;;
    esac

    set_config "autostart" "false"
    echo "已关闭开机启动"
}

# 线路延迟测试，传入一个线路名称
test_delay() {
    local proxy=$1
    # 设置更短的超时时间并添加超时处理
    local response
    response=$(timeout 2 curl -s -X GET "http://${config_array[apiurl]}/proxies/$proxy/delay?url=http://www.gstatic.com/generate_204&timeout=1000" \
        -H "Authorization: Bearer ${config_array[secret]}" 2>/dev/null)

    if [ $? -eq 124 ]; then
        echo "null"
        return
    fi

    local delay=$(echo "$response" | jq -r '.delay' 2>/dev/null)
    if [ -z "$delay" ] || [ "$delay" = "null" ]; then
        echo "null"
    else
        echo "$delay"
    fi
}

# 输出clash目前的状态
show_clash_status() {
    # 保存光标位置
    printf "\033[s"

    # 清除从光标到屏幕末尾的内容
    printf "\033[J"

    # 状态栏 (使用非格式化字符)
    printf "\n%s\n" "======================================"
    if is_clash_running; then
        printf "\033[32m%-50s\033[0m\n" "Clash正在运行，配置文件: ${config_array["default"]}"
        printf "%-50s\n" "当前各个线路组的线路选择："

        # 获取并处理组信息
        local response=$(get_request "/group" 2>/dev/null)
        if [ -n "$response" ]; then
            local groups
            mapfile -t groups < <(echo "$response" | jq -r '.proxies[] | .name' 2>/dev/null)
            if [ ${#groups[@]} -gt 0 ]; then
                printf "\n" # 添加空行增加可读性
                for i in "${!groups[@]}"; do
                    local now=$(echo "$response" | jq -r ".proxies[$i].now" 2>/dev/null)
                    if [[ $now == "DIRECT" ]]; then
                        printf "%-20s %-30s\n" "${groups[i]}" "(当前线路: $now)"
                    else
                        delay=$(test_delay "${now}" 2>/dev/null)
                        if [[ $delay == "null" ]]; then
                            printf "%-20s %-30s\n" "${groups[i]}" "(当前线路: $now, 延迟: 超时)"
                        else
                            printf "%-20s %-30s\n" "${groups[i]}" "(当前线路: $now, 延迟: ${delay}ms)"
                        fi
                    fi
                done
                printf "\n" # 添加空行增加可读性
            fi
        fi
    else
        printf "\033[31m%-50s\033[0m\n" "Clash未运行，配置文件: ${config_array["default"]}"
    fi
    printf "%s\n" "------------------------------------"
}

# ==================== 主菜单 ====================
# 显示主菜单供用户选择，输入相应的菜单项执行相应的函数
show_main_menu() {
    # 初始化终端设置
    init_terminal

    # 设置清理trap
    setup_terminal_trap

    # 如果config目录除了.config.yaml没有其他的配置文件，则提示用户下载配置文件
    if [ "$(ls -I .config.yaml "$profiles_dir" 2>/dev/null | wc -l)" -eq 0 ]; then
        echo "还没有任何配置文件，请先下载配置文件，或把配置文件放到$config_dir 目录下并重启此程序"
        download_url
        return
    fi

    # 如果数组的default字段为空，或者default字段的配置文件不存在，或者内容是.config.yaml，则提示用户选择配置文件
    if [[ -z ${config_array["default"]} || ! -f "$profiles_dir/${config_array["default"]}" || "${config_array["default"]}" = ".config.yaml" ]]; then
        show_profiles_menu
        return
    fi

    # 显示状态
    show_clash_status # 显示菜单选项
    printf "\n%-30s\n" "选项菜单:"
    printf "%-50s\n" "======================================"

    # 使用固定宽度确保对齐
    if is_clash_running; then
        printf "%-30s\n" "1. 重启 Clash"
    else
        printf "%-30s\n" "1. 启动 Clash"
    fi

    printf "%-30s\n" "2. 停止 Clash"
    printf "%-30s\n" "3. 线路选择"
    printf "%-30s\n" "4. 配置文件管理"

    # 开机启动选项
    if is_autostart_enabled; then
        printf "%-30s\n" "5. 关闭开机启动"
    else
        printf "%-30s\n" "5. 开机启动"
    fi
    printf "%-30s\n" "0. 退出"
    printf "%-50s\n" "======================================"

    # 使用 read 命令读取输入，添加提示符固定宽度
    printf "%-30s" "请选择 (0-5): "
    read -r choice
    printf "\n" # 添加换行确保输出格式正确
    # 检查输入是否为数字
    if ! [[ "$choice" =~ ^[0-5]$ ]]; then
        printf "\n无效的选项，请输入 0-5 之间的数字\n"
        sleep 1
        show_main_menu
        return
    fi

    case $choice in
    1)
        printf "\n正在处理...\n"
        if start_clash; then
            printf "\033[0m" # 重置终端属性
            sleep 1
            exec bash "$SCRIPT_PATH"
        else
            printf "\033[0m" # 重置终端属性
            printf "启动失败，按回车继续..."
            read -r
            exec bash "$SCRIPT_PATH"
        fi
        ;;
    2)
        printf "\n正在停止 Clash...\n"
        stop_clash
        printf "\033[0m" # 重置终端属性
        sleep 1
        show_main_menu
        ;;
    3)
        printf "\033[0m" # 重置终端属性
        show_groups_menu
        ;;
    4)
        printf "\033[0m" # 重置终端属性
        show_profiles_menu
        ;;
    5)
        if is_autostart_enabled; then
            printf "\n正在关闭开机启动...\n"
            disable_autostart
        else
            printf "\n正在设置开机启动...\n"
            enable_autostart
        fi
        sleep 1
        show_main_menu
        ;;
    0)
        printf "\n正在保存配置并退出...\n"
        write_array_to_config
        trap - INT # 重置 Ctrl+C 处理
        exit 0
        ;;
    esac
}
show_profiles_menu() {
    create_line
    echo "请选择使用哪个配置："
    local files=($(ls -I .config.yaml "$profiles_dir"))
    local current_profile="${config_array["default"]}"
    for i in "${!files[@]}"; do
        if [ "${files[$i]}" = "$current_profile" ]; then
            echo -e "\e[32m$((i + 1)). ${files[$i]} (当前配置)\e[0m"
        else
            echo "$((i + 1)). ${files[$i]}"
        fi
    done
    echo "$((${#files[@]} + 1)). 从URL下载配置"
    echo "0. 返回主菜单"
    read -p "请选择配置文件序号: " choice

    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    elif [ "$choice" -eq "$((${#files[@]} + 1))" ]; then
        download_url
        return
    fi

    local selected_file="${files[$((choice - 1))]}"
    # 如果选择的序号不存在，则返回
    if [ -z "$selected_file" ]; then
        echo "无效的序号"
        show_profiles_menu
        return
    fi
    selecte_profile "$selected_file"
    show_main_menu
}

show_groups_menu() {
    create_line
    echo "请选择要修改哪个线路组："
    # {"proxies":[{"alive":true,"all":["日常推荐1-台湾","日常推荐2-香港","日常推荐3-香港","日常推荐4-台湾","香港","台湾","新加坡","新加坡2","日本","日本2","美国","美国2","美国3","欧洲-英国","韩国","韩国2","加拿大","俄罗斯","土耳其","印度","阿根廷-小带宽","澳大利亚-悉尼","马来西亚","菲律宾（测试）","印尼（测试）","越南（测试）","泰国（测试）"],"extra":{},"hidden":false,"history":[],"icon":"","name":"Proxy","now":"日常推荐1-台湾","tfo":false,"type":"Selector","udp":true,"xudp":false},{"alive":true,"all":["DIRECT","REJECT","日常推荐1-台湾","日常推荐2-香港","日常推荐3-香港","日常推荐4-台湾","香港","台湾","新加坡","新加坡2","日本","日本2","美国","美国2","美国3","欧洲-英国","韩国","韩国2","加拿大","俄罗斯","土耳其","印度","阿根廷-小带宽","澳大利亚-悉尼","马来西亚","菲律宾（测试）","印尼（测试）","越南（测试）","泰国（测试）","Proxy"],"extra":{},"hidden":false,"history":[],"icon":"","name":"GLOBAL","now":"DIRECT","tfo":false,"type":"Selector","udp":true,"xudp":false}]}

    local response=$(get_request "/group")
    local groups
    mapfile -t groups < <(echo "$response" | jq -r '.proxies[] | .name')
    for i in "${!groups[@]}"; do
        local now=$(echo "$response" | jq -r ".proxies[$i].now")
        if [[ $now == "DIRECT" ]]; then
            echo "$((i + 1)). ${groups[i]} (当前线路: $now)"
        else
            delay=$(test_delay ${now})
            if [[ $delay == "null" ]]; then
                echo -e "$((i + 1)). ${groups[i]} (当前线路: $now, 延迟: \033[31mtimeout\033[0m)"
            else
                echo -e "$((i + 1)). ${groups[i]} (当前线路: $now, 延迟: \033[32m${delay}\033[0mms)"
            fi
        fi
    done

    echo "0. 返回主菜单"
    read -p "请选择线路组序号: " choice
    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    fi
    local selected_group="${groups[$((choice - 1))]}"
    if [ -z "$selected_group" ]; then
        echo "无效的序号"
        show_groups_menu
        return
    fi
    show_proxies_menu "$selected_group"
}

show_proxies_menu() {
    create_line
    local group_name=$1
    echo "${group_name}要使用哪条线路："
    local response=$(get_request "/group")
    local proxies
    mapfile -t proxies < <(echo "$response" | jq -r ".proxies[] | select(.name == \"$group_name\") | .all[]")
    for i in "${!proxies[@]}"; do
        local now=$(echo "$response" | jq -r ".proxies[] | select(.name == \"$group_name\") | .now")
        # 获取线路延迟
        delay=$(test_delay ${proxies[i]})
        if [[ $delay == "null" ]]; then
            delaystr="\033[31mtimeout\033[0m"
        else
            delaystr="\033[32m${delay}\033[0mms"
        fi

        # direct线路
        if [ "${proxies[i]}" = "DIRECT" ]; then
            echo -e "$((i + 1)). ${proxies[i]}"
        elif [ "${proxies[i]}" = "$now" ]; then
            echo -e "\e[32m$((i + 1)). ${proxies[i]} (当前线路)\e[0m \t延迟: $delaystr"
        else
            echo -e "$((i + 1)). ${proxies[i]} \t延迟: $delaystr"
        fi
    done
    echo "0. 返回主菜单"
    read -p "请选择线路序号: " choice
    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    fi
    local selected_proxy="${proxies[$((choice - 1))]}"
    if [ -z "$selected_proxy" ]; then
        echo "无效的序号"
        show_proxies_menu "$group_name"
        return
    fi
    put_request "/proxies/${group_name}" "{\"name\":\"$selected_proxy\"}"
    show_proxies_menu "$group_name"
}
show_settings_menu() {
    create_line
    echo "选择你要进行的设置："
    # 判断设置系统代理
    if [ -z "$(check_proxy)" ]; then
        echo "1. 开启系统代理(当前已关闭)"
    else
        echo "1. 关闭系统代理(当前已开启)"
    fi
    echo "0. 返回主菜单"
    read -p "请选择: " choice
    case $choice in
    1)
        set_proxy
        ;;
    0)
        show_main_menu
        ;;
    *)
        echo "无效的选项"
        show_settings_menu
        ;;
    esac
}

# 测试读取config.ini到数组
read_config_to_array
set_default_config

# 主程序循环
main_loop() {
    # 初始化终端
    init_terminal

    # 设置退出时的清理
    trap 'cleanup_terminal; echo "正在退出..."; exit 0' EXIT
    # 修改 INT/TERM trap 以在退出前移除 INT trap，保持后台进程运行
    trap 'cleanup_terminal; printf "\\n接收到中断信号，退出脚本...\\n"; trap - INT; exit 130' INT TERM

    # 测试读取配置文件
    read_config_to_array
    set_default_config

    # 进入主循环前先初始化配置文件
    if ! init_config_file; then
        log $LOG_LEVEL_ERROR "无法初始化配置文件，请检查权限"
        echo "错误：无法初始化配置文件，请检查权限或手动创建配置文件: $config_file"
        exit 1
    fi

    # 进入主循环
    while true; do
        show_main_menu
        # 每次循环都确保终端属性被重置
        printf "\\033[0m"
        stty sane 2>/dev/null || true
    done
}

# 替换脚本末尾的直接调用
# show_main_menu

# 处理开机启动的参数
if [[ "$1" == "autostart" ]]; then
    # 开机启动模式直接启动clash
    cd "$(dirname "$(readlink -f "$0")")"
    start_clash
    exit 0
fi

main_loop
