#!/bin/bash

# cd 到脚本所在目录
cd "$(dirname "$(readlink -f "$0")")"

# ==================== 变量定义 ====================
config_file="config.ini"
profiles_dir="$(dirname "$(readlink -f "$0")")/config"
home_dir="$HOME/.config/mihomo"
init_dir="$(dirname "$(readlink -f "$0")")/init"
core_dir="$(dirname "$(readlink -f "$0")")/core"
declare -A config_array  # 声明关联数组

# ==================== 初始化 ====================

# 如果home_dir不存在，则创建
if [[ ! -d $home_dir ]]; then
    mkdir -p "$home_dir"
fi
# 如果home_dir下的geoip.metadb文件不存在，则从init_dir目录复制
if [[ ! -f "$home_dir/geoip.metadb" ]]; then
    cp "$init_dir/geoip.metadb" "$home_dir"
fi
# 如果profiles_dir不存在，则创建
if [[ ! -d $profiles_dir ]]; then
    mkdir -p "$profiles_dir"
fi
# 如果core目录不存在，则创建
if [[ ! -d $core_dir ]]; then
    mkdir -p "$core_dir"
fi

# 如果配置文件不存在，则创建一个空的
if [[ ! -f $config_file ]]; then
    touch "$config_file"
fi
# 判断config_file下的.config.yaml文件是否存在，不存在则创建
if [[ ! -f "$profiles_dir/.config.yaml" ]]; then
    cat >"$profiles_dir/.config.yaml" <<EOF
mixed-port: 7890
allow-lan: false
external-controller: 127.0.0.1:50832
secret: cbd6e156-ad9d-4e45-8c39-78c48a5a095d
EOF
fi                                             

# 判断系统是amd64还是arm64
if [[ $(uname -m) == "x86_64" ]]; then
    echo "系统是amd64"
    # 如果core目录下的mihomo-core不存在，则从init_dir目录复制mihomo-linux-amd64到core目录并命名为mihomo-core
    if [[ ! -f "$core_dir/mihomo-core" ]]; then
        cp "$init_dir/binaries/x86_64/mihomo-linux-amd64" "$core_dir/mihomo-core"
    fi
    # 如果core目录下的yq不存在，则从init_dir目录复制yq到core目录
    if [[ ! -f "$core_dir/yq" ]]; then
        cp "$init_dir/binaries/x86_64/yq_linux_amd64" "$core_dir"/yq
    fi
    # 如果core目录下的jq不存在，则从init_dir目录复制jq到core目录
    if [[ ! -f "$core_dir/jq" ]]; then
        cp "$init_dir/binaries/x86_64/jq-linux-amd64" "$core_dir/jq"
    fi
elif [[ $(uname -m) == "aarch64" ]] || [[ $(uname -m) == "arm64" ]]; then
    echo "系统是arm64"
    # 如果core目录下的mihomo-core不存在，则从init_dir目录复制mihomo-linux-arm64到core目录并命名为mihomo-core
    if [[ ! -f "$core_dir/mihomo-core" ]]; then
        cp "$init_dir/binaries/arm64/mihomo-linux-arm64" "$core_dir/mihomo-core"
    fi
    # 如果core目录下的yq不存在，则从init_dir目录复制yq到core目录
    if [[ ! -f "$core_dir/yq" ]]; then
        cp "$init_dir/binaries/arm64/yq_linux_arm64" "$core_dir"/yq
    fi
    # 如果core目录下的jq不存在，则从init_dir目录复制jq到core目录
    if [[ ! -f "$core_dir/jq" ]]; then
        cp "$init_dir/binaries/arm64/jq-linux-arm64" "$core_dir/jq"
    fi
else
    echo "请自行下载对应的mihomo-core,yq,以及jq文件到core目录"
fi

yq(){
    chmod +x $core_dir/yq
    "$core_dir/yq" "$@"
}
jq(){
    chmod +x $core_dir/jq
    "$core_dir/jq" "$@"
}
# 创建分割行
create_line(){
    echo ""
    echo ""
    echo "===================================="
}

# ==================== 配置处理 ====================
# 函数：读取config.ini到数组
read_config_to_array() {
    while IFS="=" read -r key value; do
        # 忽略空行
        if [[ -z $key ]]; then
            continue
        fi
        # 去除首尾空格
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 添加到关联数组中
        config_array["$key"]=$value
    done < "$config_file"
}

# 函数：将数组写回config.ini
write_array_to_config() {
    echo "" > $config_file  # 清空文件
    # 遍历关联数组并输出到文件
    for key in "${!config_array[@]}"; do
        # 写入键值对
        echo "$key=${config_array[$key]}" >> "$config_file"
    done
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

    # 直接更新简单字段
    yq eval -i ".mixed-port = $mixed_port" "$home_dir/$profile"
    yq eval -i ".port = $port" "$home_dir/$profile"
    yq eval -i ".socks-port = $socks_port" "$home_dir/$profile"

    # 使用yq的文件合并功能来更新dns和tun块
    yq eval -i ". *+ load(\"$init_dir/dns.yaml\")" "$home_dir/$profile"
    yq eval -i ". *+ load(\"$init_dir/tun.yaml\")" "$home_dir/$profile"

}
# 使用default启动clash
start_clash() {
    stop_clash # 先停止clash
    local profile="${config_array["default"]}"
    copy_default_to_home
    replace_config
    echo "启动clash: $profile"
    chmod +x $core_dir/mihomo-core
    setsid $core_dir/mihomo-core -f "$home_dir/$profile" >log.txt 2>&1 &
    disown $!


    # 如果启动失败，输出错误信息
    if [ $? -ne 0 ]; then
        echo "启动clash失败"
    else
        echo "启动clash成功"
        get_api_url
        sleep 1
    fi

}

# 停止clash
stop_clash() {
    pkill -f "mihomo-core"
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
    read -p "输入订阅地址: " url
    local config_dir="$(dirname "$(readlink -f "$0")")/config"
    mkdir -p "$config_dir"
    wget --content-disposition -P "$profiles_dir" "$url"
    filename=$(ls -t "$profiles_dir" | head -n 1)
    set_config "default" "$filename"
    show_main_menu
}


# 设置系统代理
enable_proxy() {
    echo "http_proxy=\"http://127.0.0.1:7890\"" | sudo tee -a /etc/environment > /dev/null
    echo "https_proxy=\"https://127.0.0.1:7890\"" | sudo tee -a /etc/environment > /dev/null
    echo "Proxy enabled: http://127.0.0.1:7890"
}
disable_proxy() {
    sudo sed -i '/http_proxy/d' /etc/environment
    sudo sed -i '/https_proxy/d' /etc/environment
    echo "Proxy disabled"
}
check_proxy() {
    if grep -q "http_proxy" /etc/environment; then
        echo "Current HTTP Proxy:"
        grep -w "http_proxy" /etc/environment
    fi
    if grep -q "https_proxy" /etc/environment; then
        echo "Current HTTPS Proxy:"
        grep -w "https_proxy" /etc/environment
    fi
}
set_proxy()
{
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



# ==================== 主菜单 ====================
# 显示主菜单供用户选择，输入相应的菜单项执行相应的函数
show_main_menu(){
    create_line
    # 如果config目录除了.config.yaml没有其他的配置文件，则提示用户下载配置文件
    if [ "$(ls -I .config.yaml "$profiles_dir" | wc -l)" -eq 0 ]; then
        echo "还没有任何配置文件，请先下载配置文件，或把配置文件放到$config_dir 目录下并重启此程序"
        download_url
        return
    fi
    # 如果数组的default字段为空，或者default字段的配置文件不存在，或者内容是.config.yaml，则提示用户选择配置文件
    if [[ -z ${config_array["default"]} || ! -f "$profiles_dir/${config_array["default"]}" || "${config_array["default"]}" = ".config.yaml" ]]; then
        show_profiles_menu
        return
    fi

    if is_clash_running; then
        echo -e "\e[32m1. 重启Clash(正在运行，配置文件:  ${config_array["default"]})\e[0m"
    else
        echo "1. 启动clash(配置文件: ${config_array["default"]})"
    fi

    echo "2. 停止clash"
    echo "3. 线路选择"
    echo "4. 配置文件管理"
    # echo "5. 设置"
    echo "0. 退出"
    read -p "请选择: " choice
    case $choice in
    1)
        start_clash
        sleep 1
        show_main_menu
        ;;
    2)
        stop_clash
        sleep 1
        show_main_menu
        ;;
    3)  show_groups_menu
        ;;
    4)
        show_profiles_menu
        ;;
    # 5)
    #     show_settings_menu
    #     ;;
    0)
        write_array_to_config
        exit 0
        ;;
    *)
        echo "无效的选项"
        show_main_menu
        ;;
    esac
}
show_profiles_menu(){
    create_line
    echo "请选择使用哪个配置："
    local files=($(ls -I .config.yaml "$profiles_dir"))
    local current_profile="${config_array["default"]}"
    for i in "${!files[@]}"; do
        if [ "${files[$i]}" = "$current_profile" ]; then
            echo -e "\e[32m$((i+1)). ${files[$i]} (当前配置)\e[0m"
        else
            echo "$((i+1)). ${files[$i]}"
        fi
    done
    echo "$(( ${#files[@]} + 1 )). 从URL下载配置"
    echo "0. 返回主菜单"
    read -p "请选择配置文件序号: " choice

    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    elif [ "$choice" -eq "$(( ${#files[@]} + 1 ))" ]; then
        download_url
        return
    fi

    local selected_file="${files[$((choice-1))]}"
    # 如果选择的序号不存在，则返回
    if [ -z "$selected_file" ]; then
        echo "无效的序号"
        show_profiles_menu
        return
    fi
    selecte_profile "$selected_file"
    show_main_menu
}

show_groups_menu(){
    create_line
    echo "请选择要修改哪个线路组："
    # {"proxies":[{"alive":true,"all":["日常推荐1-台湾","日常推荐2-香港","日常推荐3-香港","日常推荐4-台湾","香港","台湾","新加坡","新加坡2","日本","日本2","美国","美国2","美国3","欧洲-英国","韩国","韩国2","加拿大","俄罗斯","土耳其","印度","阿根廷-小带宽","澳大利亚-悉尼","马来西亚","菲律宾（测试）","印尼（测试）","越南（测试）","泰国（测试）"],"extra":{},"hidden":false,"history":[],"icon":"","name":"Proxy","now":"日常推荐1-台湾","tfo":false,"type":"Selector","udp":true,"xudp":false},{"alive":true,"all":["DIRECT","REJECT","日常推荐1-台湾","日常推荐2-香港","日常推荐3-香港","日常推荐4-台湾","香港","台湾","新加坡","新加坡2","日本","日本2","美国","美国2","美国3","欧洲-英国","韩国","韩国2","加拿大","俄罗斯","土耳其","印度","阿根廷-小带宽","澳大利亚-悉尼","马来西亚","菲律宾（测试）","印尼（测试）","越南（测试）","泰国（测试）","Proxy"],"extra":{},"hidden":false,"history":[],"icon":"","name":"GLOBAL","now":"DIRECT","tfo":false,"type":"Selector","udp":true,"xudp":false}]}
    local response=$(get_request "/group")
    local groups
    mapfile -t groups < <(echo "$response" | jq -r '.proxies[] | .name')
    for i in "${!groups[@]}"; do
        local now=$(echo "$response" | jq -r ".proxies[$i].now")
        echo "$((i + 1)). ${groups[i]} (当前线路: $now)"
    done
    echo "0. 返回主菜单"
    read -p "请选择线路组序号: " choice
    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    fi
    local selected_group="${groups[$((choice-1))]}"
    if [ -z "$selected_group" ]; then
        echo "无效的序号"
        show_groups_menu
        return
    fi
    show_proxies_menu "$selected_group"
}

show_proxies_menu(){
    create_line
    local group_name=$1
    echo "${group_name}要使用哪条线路："
    local response=$(get_request "/group")
    local proxies
    mapfile -t proxies < <(echo "$response" | jq -r ".proxies[] | select(.name == \"$group_name\") | .all[]")
    for i in "${!proxies[@]}"; do
        local now=$(echo "$response" | jq -r ".proxies[] | select(.name == \"$group_name\") | .now")
        if [ "${proxies[i]}" = "$now" ]; then
            echo -e "\e[32m$((i + 1)). ${proxies[i]} (当前线路)\e[0m"
        else
            echo "$((i + 1)). ${proxies[i]}"
        fi
    done
    echo "0. 返回主菜单"
    read -p "请选择线路序号: " choice
    if [ "$choice" -eq 0 ]; then
        show_main_menu
        return
    fi
    local selected_proxy="${proxies[$((choice-1))]}"
    if [ -z "$selected_proxy" ]; then
        echo "无效的序号"
        show_proxies_menu "$group_name"
        return
    fi
    put_request "/proxies/${group_name}" "{\"name\":\"$selected_proxy\"}"
    show_proxies_menu "$group_name"
}
show_settings_menu(){
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
show_main_menu