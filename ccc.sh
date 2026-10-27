#!/bin/bash

# encoding=utf-8
# line ending=\n

# wget https://raw.githubusercontent.com/zero-ljz/debian-server-toolkit/main/ccc.sh
# apt insall sudo
# bash ./ccc.sh

# 获取系统信息
ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/') # amd64
OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | sed 's/"//g') # debian
OS_VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | sed 's/"//g') # 11
OS_VERSION_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2) # bullseye

LOG_FILE="/var/log/ccc_script.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a "$LOG_FILE"
}

system_init(){
    # 执行这个函数需用sudo
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装必备组件 && 系统配置------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    echo -e "\n\n\n 配置语言"
    read -t 5 -p "是否继续？ (y):" answer
    if [[ "$answer" == "y" || $? -eq 142 ]]; then
        # dpkg-reconfigure locales
        # 启用一个区域设置
        sudo sed -i '/^# zh_CN.UTF-8 UTF-8$/s/^#//' /etc/locale.gen
        # 生成区域设置
        sudo locale-gen
        # 设置系统环境的默认区域
        sudo update-locale LANG=zh_CN.UTF-8
    fi

    echo -e "\n\n\n 配置时区"
    read -t 5 -p "是否继续？ (y):" answer
    if [[ "$answer" == "y" || $? -eq 142 ]]; then
        # dpkg-reconfigure tzdata
        sudo timedatectl set-timezone Asia/Shanghai
    fi

    echo -e "\n\n\n 设置ssh 120*720=86400 24小时不断开连接"
    read -t 5 -p "是否继续？ (y):" answer
    if [[ "$answer" == "y" || $? -eq 142 ]]; then
        sudo cp "/etc/ssh/sshd_config" "/etc/ssh/sshd_config-OLD-$(date +%y%m%d-%H%M%S)"
        sudo sed -i 's/^#\?TCPKeepAlive.*/TCPKeepAlive yes/' /etc/ssh/sshd_config
        sudo sed -i 's|#ClientAliveInterval 0|ClientAliveInterval 120|g' /etc/ssh/sshd_config
        sudo sed -i 's|#ClientAliveCountMax 3|ClientAliveCountMax 720|g' /etc/ssh/sshd_config
        sudo systemctl restart sshd
    fi

    if [ ! -f "/swapfile" ]; then
        echo -e "\n\n\n设置 Swap"
        read -t 5 -p "是否继续？ (y):" answer
        if [[ "$answer" == "y" || $? -eq 142 ]]; then
            total_memory_mb=$(grep MemTotal /proc/meminfo | awk '{print int($2 / 1024)}')
            swapfile_length=$(($total_memory_mb * 2))
            log "正在创建 Swap 文件..."
            if sudo fallocate -l ${swapfile_length}M /swapfile 2>/dev/null; then
                log "使用 fallocate 预分配空间成功"
            else
                log "fallocate 失败，正在使用 dd 写入连续块（这可能需要一些时间）..."
                sudo dd if=/dev/zero of=/swapfile bs=1M count=${swapfile_length} status=none
            fi
            sudo chmod 600 /swapfile
            # 格式化为交换分区
            sudo mkswap /swapfile
            # 将文件添加到系统的/etc/fstab文件中，以便在系统启动时自动挂载
            echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
            # 启用交换文件
            sudo swapon /swapfile
        fi
    fi

    if [ ! -f "/etc/systemd/zram-generator.conf" ]; then
        echo -e "\n\n\n开启 ZRAM 内存压缩 (高并发服务器不建议开启)"
        read -t 5 -p "是否继续？ (y):" answer
        if [[ "$answer" == "y" || $? -eq 142 ]]; then
            sudo apt update && sudo apt install -y systemd-zram-generator
            sudo tee /etc/systemd/zram-generator.conf <<EOF >/dev/null
[zram0]
zram-size = ram * 0.75
compression-algorithm = zstd
swap-priority = 100
EOF
            sudo systemctl daemon-reload
            sudo systemctl start systemd-zram-setup@zram0.service
            echo "ZRAM 配置完成，当前状态："
            sudo swapon --show
        fi
    fi

    if [ -z "$(lsmod | grep bbr)" ]; then
        echo -e "\n\n\n启用 Google BBR"
        read -t 5 -p "是否继续？ (y):" answer
        if [[ "$answer" == "y" || $? -eq 142 ]]; then
            sudo sh -c 'echo net.core.default_qdisc=fq >> /etc/sysctl.conf'
            sudo sh -c 'echo net.ipv4.tcp_congestion_control=bbr >> /etc/sysctl.conf'
            echo -e "\n\n\n从配置文件加载内核参数（需要管理员）"
            sudo sysctl -p
        fi
    fi

    echo -e "\n\n\n 安装必备组件"
    read -t 5 -p "是否继续？ (y):" answer
    if [[ "$answer" == "y" || $? -eq 142 ]]; then
        sudo apt -y install openssl aptitude telnet perl lsof
        sudo apt -y install sqlite3 lua5.3
        sudo apt install -y \
        curl \
        wget \
        git \
        vim \
        nano \
        htop \
        tmux \
        tree \
        unzip \
        zip \
        net-tools \
        dnsutils \
        ca-certificates \
        gnupg
    fi

}

install_python(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [version]"
        return
    fi
    
    echo -e "\n\n\n------------------------------安装 Python + pyenv + UV ------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local version=${1:-3.10.11} # 3.12.10

    # sudo apt -y install python3 python3-pip python3-venv python3-dev python3-setuptools

    # debian编译依赖包集合
    sudo apt update && sudo apt install build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev uuid-dev -y
    # 安装pyenv
    curl https://pyenv.run | bash
    # 注入环境变量并写入 ~/.bashrc
    if ! grep -q "pyenv init" ~/.bashrc; then
        echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
        echo 'export PATH="$HOME/.pyenv/bin:$PATH"' >> ~/.bashrc
        echo 'eval "$(pyenv init - bash)"' >> ~/.bashrc
        echo 'eval "$(pyenv virtualenv-init -)"' >> ~/.bashrc
    fi
    # 让当前脚本运行环境中临时生效，以便后续执行 pyenv 命令
    export PATH="$HOME/.pyenv/bin:$PATH"
    eval "$(pyenv init - bash)"
    eval "$(pyenv virtualenv-init -)"
    # 执行编译安装
    pyenv install ${version}
    pyenv global ${version}

    if read -t 5 -p "是否使用pypi中国大陆镜像源？ (y): " answer && [ "$answer" == "y" ]; then
        pip config set global.index-url https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
    fi

    # 已过时
    # sudo apt install -y pipx
    # pipx ensurepath

    # 安装uv
    curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_supervisor(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装 Supervisor 进程管理器------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return
    
    # 使用系统包管理器安装，避免现代操作系统上的 PEP 668 pip 全局安装限制
    sudo apt update && sudo apt install -y supervisor
    
    # 确保配置支持 *.ini 后缀，且是幂等的（避免多次运行脚本重复追加）
    if [ -f "/etc/supervisor/supervisord.conf" ]; then
        if ! grep -q '\*\.ini' /etc/supervisor/supervisord.conf; then
            sudo sed -i 's|files = /etc/supervisor/conf.d/\*.conf|files = /etc/supervisor/conf.d/*.conf /etc/supervisor/conf.d/*.ini|g' /etc/supervisor/supervisord.conf
        fi
    fi
    
    sudo systemctl daemon-reload
    sudo systemctl enable supervisor
    sudo systemctl start supervisor
    log "Supervisor 已通过 Systemd 成功启动并设置开机自启"
}

create_supervisor(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} app_name \"command\" working_dir"
        return
    fi

    local app_name="$1"
    local command="$2"
    local working_dir="${3:-"/usr/local/bin/"}"

    sudo tee /etc/supervisor/conf.d/${app_name}.ini <<EOF >/dev/null
[program:${app_name}]
directory=${working_dir}
command=${command}
;user=root
autostart=true
autorestart=true       ; 如果进程终止,自动重启
;startsecs=10          ; 进程启动后等待n秒钟如果没有退出则视为启动成功
;priority=999          ; 启动优先级
stderr_logfile=/var/log/${app_name}.err
stdout_logfile=/var/log/${app_name}.log
;stdout_logfile_maxbytes=2MB
;stderr_logfile_maxbytes=2MB
;environment=CODENATION_ENV=prod,DEBUG=false,ENVIRONMENT=production
;numprocs=1            ; 启动进程数
;startretries=3        ; 启动重试次数
;process_name=%(program_name)s_%(process_num)02d
EOF

    # 重新读取配置文件
    sudo supervisorctl reread
    # 应用更改
    sudo supervisorctl update

    # supervisorctl restart ${app_name}
    # 重载配置和重启所有进程
    # supervisorctl reload
    # 重启匹配的命令行的进程
    # pkill -f 'supervisord -c /etc/supervisor/supervisord.conf'
}

create_service(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} app_name command working_dir"
        return
    fi

    local app_name="$1"
    local command="$2"
    local working_dir="${3:-"/usr/local/bin/"}"

    sudo touch /etc/systemd/system/${app_name}.service
    sudo chmod 755 /etc/systemd/system/${app_name}.service
    sudo tee /etc/systemd/system/${app_name}.service <<EOF >/dev/null
[Unit]
Description=${app_name}
# 确保网络完全在线后再启动（比普通的 network.target 更稳，防止应用启动时因网络未就绪报错）
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 建议：如果应用不需要特殊系统权限，将 root 改为低权限用户（如 nobody）
User=root
WorkingDirectory=$working_dir
ExecStart=$command

# 核心续命三件套
Restart=always
RestartSec=5
# 防止程序死循环崩溃时无限重启把 CPU 飙满，如果 60 秒内重启超过 5 次则彻底停止
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target

EOF
}

install_docker(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    
    echo -e "\n\n\n------------------------------安装 Docker------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    # curl -fsSL https://get.docker.com -o get-docker.sh
    # sh get-docker.sh

    local host="download.docker.com"
    read -t 5 -p "是否使用中国大陆镜像？ (y): " answer && [ "$answer" == "y" ] && host="mirrors.ustc.edu.cn/docker-ce"

    echo -e "\n\n\n 安装包以允许sudo apt通过HTTPS使用存储库"
    sudo apt-get update && sudo apt-get -y install ca-certificates curl gnupg
    
    echo -e "\n\n\n 添加 Docker 的官方 GPG 密钥"
    sudo mkdir -m 0755 -p /etc/apt/keyrings
    curl -fsSL https://${host}/linux/${OS_ID}/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo -e "\n\n\n 设置存储库"
    echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://${host}/linux/${OS_ID} "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    echo -e "\n\n\n 安装 Docker Engine、containerd 和 Docker Compose"
    sudo apt-get update && sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if read -t 5 -p "是否使用中国大陆注册表？ (y): " answer && [ "$answer" == "y" ]; then
        sudo tee /etc/docker/daemon.json <<EOF >/dev/null
{
  "registry-mirrors": [
    "https://docker.1panel.live",
    "https://docker.1panel.dev",
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io"
  ]
}
EOF
        # 备用 http://mirrors.ustc.edu.cn http://hub.daocloud.io
    fi
}

install_nodejs(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [version]"
        return
    fi
    
    echo -e "\n\n\n------------------------------安装 Nodejs + nvm + pnpm ------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local version=${1:-24} # 22
    
    sudo apt -y install npm
    # 使用版本管理器安装nodejs https://learn.microsoft.com/zh-cn/windows/dev-environment/javascript/nodejs-on-wsl?source=recommendations
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash

    # 运行以下操作可以不用重启终端就能使用nvm
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
    # 安装Nodejs 24 LTS
    nvm install ${version}
    nvm use ${version}

    # npm install -g yarn
    npm install -g pnpm

    # 查看全局包，并且只显示顶级包，而不会列出其依赖项
    #npm list -g --depth 0

    # npm config set registry https://registry.npmjs.org/
    # npm config set registry https://registry.npmmirror.com
}

_valid_domain_name(){
    local domain="${1:-}"
    [[ ${#domain} -le 253 && "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

create_ssl() (
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} domain_name"
        return
    fi

    if [ "$#" -ne 1 ] || ! _valid_domain_name "$1"; then
        log "ERROR: Provide one valid domain name."
        return 1
    fi
    local domain_name="$1"
    local acme_dir="/var/www/challenges/${domain_name}/"
    local current_script
    current_script=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    local SSL_DIR="/var/ssl"
    local ACCOUNT_KEY="$SSL_DIR/account.key"
    local DOMAIN_KEY="$SSL_DIR/${domain_name}.key"
    local DOMAIN_FULLCHAIN_CRT="$SSL_DIR/${domain_name}.fullchain.crt"
    local DOMAIN_CSR="$SSL_DIR/${domain_name}.csr"

    if [ "${CRON_EXECUTION:-}" = "1" ] && sudo test -s "$DOMAIN_FULLCHAIN_CRT" &&
        sudo openssl x509 -checkend 2592000 -noout -in "$DOMAIN_FULLCHAIN_CRT" >/dev/null 2>&1; then
        return 0
    fi

    local -a nginx_command
    if command -v docker >/dev/null 2>&1 && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx1'; then
        nginx_command=(sudo docker exec nginx1 nginx)
    elif command -v nginx >/dev/null 2>&1; then
        nginx_command=(sudo nginx)
    else
        log "ERROR: No running nginx1 container or host nginx found; cannot reload the certificate."
        return 1
    fi

    sudo install -d -m 0755 -o root -g root "$SSL_DIR" "$acme_dir" || return 1
    local work_dir
    work_dir=$(sudo mktemp -d "$SSL_DIR/.acme-${domain_name}.XXXXXX") || return 1
    # root 创建的 0700 临时目录，避免执行其他用户预先放置的程序。
    trap 'sudo rm -rf -- "$work_dir"' EXIT
    local ACME_TINY="$work_dir/acme_tiny.py"
    local TMP_FULLCHAIN_CRT="$work_dir/fullchain.crt"

    # 先生成完整密钥再以硬链接发布；并发申请也不会覆盖已有密钥。
    local key bits
    for key in "$ACCOUNT_KEY" "$DOMAIN_KEY"; do
        if ! sudo test -e "$key"; then
            bits=2048
            [ "$key" = "$ACCOUNT_KEY" ] && bits=4096
            sudo openssl genrsa -out "$work_dir/new.key" "$bits" || return 1
            sudo chmod 600 "$work_dir/new.key" || return 1
            sudo ln -- "$work_dir/new.key" "$key" || { sudo test -s "$key" || return 1; }
            sudo rm -- "$work_dir/new.key" || return 1
        fi
        sudo openssl pkey -in "$key" -noout >/dev/null || return 1
    done

    log "Generate CSR..."
    sudo openssl req -new -sha256 -key "$DOMAIN_KEY" -subj "/" \
        -addext "subjectAltName=DNS:${domain_name}" -out "$work_dir/domain.csr" || return 1
    sudo install -m 0644 "$work_dir/domain.csr" "$DOMAIN_CSR" || return 1
    if ! sudo wget --quiet -O "$ACME_TINY" https://raw.githubusercontent.com/diafygi/acme-tiny/master/acme_tiny.py; then
        log "ERROR: ACME client download failed; no client executed."
        return 1
    fi
    # 同时检查签发程序和证书写入的状态；挑战文件需能被 Nginx 读取。
    if ! (set -o pipefail
        sudo sh -c 'umask 022; exec /usr/bin/python3 "$@"' sh "$ACME_TINY" \
            --account-key "$ACCOUNT_KEY" --csr "$work_dir/domain.csr" --acme-dir "$acme_dir" |
            sudo tee "$TMP_FULLCHAIN_CRT" >/dev/null
    ); then
        log "ERROR: SSL generation failed; existing certificate preserved."
        return 1
    fi
    sudo openssl x509 -checkend 0 -noout -in "$TMP_FULLCHAIN_CRT" >/dev/null || return 1
    # x509 -checkhost 在域名不匹配时仍可能返回 0；verify 会正确返回失败。
    sudo openssl verify -verify_hostname "$domain_name" -partial_chain \
        -trusted "$TMP_FULLCHAIN_CRT" "$TMP_FULLCHAIN_CRT" >/dev/null || return 1
    local cert_public_key domain_public_key
    cert_public_key=$(sudo openssl x509 -pubkey -noout -in "$TMP_FULLCHAIN_CRT") || return 1
    domain_public_key=$(sudo openssl pkey -pubout -in "$DOMAIN_KEY") || return 1
    if [ "$cert_public_key" != "$domain_public_key" ]; then
        log "ERROR: Certificate does not match the domain key."
        return 1
    fi

    local had_certificate=0
    if sudo test -e "$DOMAIN_FULLCHAIN_CRT"; then
        sudo cp -p -- "$DOMAIN_FULLCHAIN_CRT" "$work_dir/previous.crt" || return 1
        had_certificate=1
    fi
    sudo chmod 644 "$TMP_FULLCHAIN_CRT" || return 1
    sudo mv -f -- "$TMP_FULLCHAIN_CRT" "$DOMAIN_FULLCHAIN_CRT" || return 1
    if ! "${nginx_command[@]}" -t || ! "${nginx_command[@]}" -s reload; then
        if [ "$had_certificate" -eq 1 ]; then
            if ! sudo mv -f -- "$work_dir/previous.crt" "$DOMAIN_FULLCHAIN_CRT"; then
                trap - EXIT
                log "ERROR: Reload and restore failed; recover the previous certificate from $work_dir/previous.crt."
                return 1
            fi
        else
            sudo rm -f -- "$DOMAIN_FULLCHAIN_CRT" || return 1
        fi
        log "ERROR: Nginx validation/reload failed; renewal is not complete."
        return 1
    fi

    # 签发并重载成功后才登记定时任务，路径中的空格使用 shell 转义。
    if [[ "$current_script" == *$'\n'* || "$current_script" == *%* ]]; then
        log "ERROR: Certificate installed, but cron cannot use a script path containing a newline or %."
        return 1
    fi
    local cron_job cron_contents
    printf -v cron_job '15 3 * * * CRON_EXECUTION=1 bash %q create_ssl %q' "$current_script" "$domain_name"
    if ! cron_contents=$(sudo sh -c 'LC_ALL=C crontab -l 2>"$1"' sh "$work_dir/cron.err"); then
        if ! sudo grep -q '^no crontab for ' "$work_dir/cron.err"; then
            log "ERROR: Certificate installed, but the existing crontab could not be read; no cron changes made."
            return 1
        fi
        cron_contents=""
    fi
    if ! grep -Fxq -- "$cron_job" <<< "$cron_contents"; then
        printf '%s\n%s\n' "$cron_contents" "$cron_job" | sudo crontab - || return 1
    fi
    log "Certificate installed and Nginx reloaded. Enable HTTPS: bash \"${current_script}\" enable_https ${domain_name} [--redirect]"
)

create_proxy(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then 
        log "Usage: ${FUNCNAME} domain_name local_port|upstream_url"
        log "Examples: ${FUNCNAME} proxy.example.com 1234 | ${FUNCNAME} proxy.example.com https://example.com"
        log "Upstream: http(s)://hostname[:port] (no path); bare hostnames default to HTTPS."
        return
    fi

    if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        log "Usage: ${FUNCNAME} domain_name local_port|upstream_url"
        return 1
    fi

    local domain_name="$1"
    local target="$2"
    local upstream_url upstream_host upstream_port
    local proxy_host='$host'
    local proxy_ssl_config=""

    if [[ "$target" =~ ^[0-9]+$ ]]; then
        upstream_port="$target"
        upstream_url="http://127.0.0.1:${upstream_port}"
    else
        # 未指定协议的远程域名默认使用 HTTPS。
        [[ "$target" == *://* ]] || target="https://${target}"
        local upstream_pattern='^(https?)://([a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?)(:([0-9]+))?/?$'
        if [[ ! "$target" =~ $upstream_pattern ]]; then
            log "ERROR: Upstream must be a local port or http(s)://hostname[:port] without a path."
            return 1
        fi
        upstream_host="${BASH_REMATCH[2]}"
        upstream_port="${BASH_REMATCH[5]}"
        upstream_url="${target%/}"
        proxy_host="${upstream_host}${upstream_port:+:${upstream_port}}"
        if [[ "$upstream_url" == https://* ]]; then
            # TLS SNI 只包含主机名，不包含端口。
            proxy_ssl_config="
        proxy_ssl_server_name on;
        proxy_ssl_name ${upstream_host};"
        fi
    fi

    if [ -n "$upstream_port" ]; then
        if [ "${#upstream_port}" -gt 5 ] || (( 10#$upstream_port < 1 || 10#$upstream_port > 65535 )); then
            log "ERROR: Upstream port must be between 1 and 65535."
            return 1
        fi
    fi

    local config_file="/etc/nginx/conf.d/${domain_name}.conf"
    local backup_file=""
    # 先备份，兼容直接在 conf.d 目录中执行；备份不参与 Nginx 配置加载。
    if sudo test -e "$config_file"; then
        backup_file=$(sudo mktemp "${config_file}.bak.XXXXXX") || return 1
        if ! sudo cp -p -- "$config_file" "$backup_file"; then
            sudo rm -f -- "$backup_file"
            log "ERROR: Could not back up ${config_file}; no changes made."
            return 1
        fi
    fi

    cat >"${domain_name}.conf" <<EOF || return 1
# 反向代理配置

# 引入 upstream 配置
#include upstream.conf;

# 定义反向代理
server {
    listen 80;
    listen  [::]:80;
    server_name ${domain_name};

    # 日志记录
    access_log /var/log/nginx/${domain_name}.access.log;
    error_log /var/log/nginx/${domain_name}.error.log;

    # if (\$scheme = http ) {
    #     return 301 https://\$host\$request_uri;
    # }

    # SSL/TLS 配置
    # listen 443 ssl;
    # listen [::]:443 ssl;
    # ssl_certificate /var/ssl/${domain_name}.fullchain.crt;
    # ssl_certificate_key /var/ssl/${domain_name}.key;
    # ssl_protocols TLSv1.2 TLSv1.3;

    # 申请证书需要用到的配置
    location /.well-known/acme-challenge/ {
        alias /var/www/challenges/${domain_name}/;
        try_files \$uri =404;
    }

    location / {
        # 设置代理缓存
        #proxy_cache my_cache;
        #proxy_cache_valid 200 10m;

        #add_header Content-Security-Policy upgrade-insecure-requests;
        proxy_http_version 1.1;
        proxy_pass_header Server;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host ${proxy_host};
        proxy_redirect off;
        proxy_pass ${upstream_url};${proxy_ssl_config}

        # WebSocket 转发支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # wordpress容器需要设置
        # proxy_redirect off;

        # 安全配置
        # 设置请求头
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # 设置请求大小限制
    # client_max_body_size 10m;

    # 设置连接超时
    # proxy_connect_timeout 5s;
    # proxy_read_timeout 10s;

    # 健康检查
    # check interval=30s rise=2 fall=3 timeout=5s;

    # 防止直接访问代理
    # deny all;
}

EOF

    if ! sudo test "./${domain_name}.conf" -ef "$config_file"; then
        sudo cp -- "./${domain_name}.conf" "$config_file" || return 1
    fi

    local host_nginx=0 container_nginx=0 validation_failed=0
    # 所有可用实例校验通过后才重载，防止部分实例先加载了待回滚配置。
    if command -v nginx >/dev/null 2>&1; then
        host_nginx=1
        sudo nginx -t || validation_failed=1
    fi
    if command -v docker >/dev/null 2>&1 && sudo docker ps --format '{{.Names}}' | grep -qx 'nginx1'; then
        container_nginx=1
        sudo docker exec nginx1 nginx -t || validation_failed=1
    fi
    if [ "$validation_failed" -eq 1 ]; then
        if [ -n "$backup_file" ]; then
            if ! sudo cp -p -- "$backup_file" "$config_file"; then
                log "ERROR: Nginx validation and restore failed. Restore ${config_file} from ${backup_file} manually."
                return 1
            fi
        elif ! sudo rm -f -- "$config_file"; then
            log "ERROR: Nginx validation failed; remove ${config_file} manually."
            return 1
        fi
        log "ERROR: Nginx validation failed; previous config restored (new config removed on first creation)."
        return 1
    fi
    if [ "$host_nginx" -eq 1 ]; then sudo nginx -s reload || return 1; fi
    if [ "$container_nginx" -eq 1 ]; then sudo docker exec nginx1 nginx -s reload || return 1; fi
    return 0
}

enable_https(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} domain_name [--redirect]"
        log "Enable HTTPS in a create_proxy config; --redirect also redirects HTTP to HTTPS."
        return
    fi
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--redirect" ]; }; then
        log "Usage: ${FUNCNAME} domain_name [--redirect]"
        return 1
    fi

    local domain_name="$1"
    if [[ ! "$domain_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
        log "ERROR: Invalid domain name."
        return 1
    fi
    local config_file="/etc/nginx/conf.d/${domain_name}.conf"
    local certificate="/var/ssl/${domain_name}.fullchain.crt"
    local private_key="/var/ssl/${domain_name}.key"
    local redirect=0
    [ "${2:-}" = "--redirect" ] && redirect=1

    if ! sudo test -f "$config_file"; then
        log "ERROR: Config not found: ${config_file}"
        return 1
    fi
    if ! sudo test -s "$certificate" || ! sudo test -s "$private_key"; then
        log "ERROR: Certificate or private key missing/empty. Run create_ssl ${domain_name} first."
        return 1
    fi

    # 优先使用 deploy_nginx 创建的容器，否则使用宿主机 Nginx。
    local -a nginx_command
    if command -v docker >/dev/null 2>&1 && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nginx1'; then
        nginx_command=(sudo docker exec nginx1 nginx)
    elif command -v nginx >/dev/null 2>&1; then
        nginx_command=(sudo nginx)
    else
        log "ERROR: No running nginx1 container or host nginx executable found."
        return 1
    fi

    local temp_file backup_file
    temp_file=$(mktemp) || return 1
    # 处理模板中的 TLS 配置和完整的三行跳转块；旧模板补齐 IPv6 监听。
    # 缺少模板项或包含多个 server 块时拒绝修改，避免误改自定义配置。
    if ! sudo awk -v domain="$domain_name" -v redirect="$redirect" '
        function clean(line) {
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            return line
        }
        function uncomment(line) {
            sub(/#[ \t]?/, "", line)
            return line
        }
        BEGIN {
            settings["listen 443 ssl;"] = 1
            settings["listen [::]:443 ssl;"] = 1
            settings["ssl_certificate /var/ssl/" domain ".fullchain.crt;"] = 1
            settings["ssl_certificate_key /var/ssl/" domain ".key;"] = 1
            settings["ssl_protocols TLSv1.2 TLSv1.3;"] = 1
        }
        FNR == NR {
            if (clean($0) == "listen [::]:443 ssl;") ipv6++
            next
        }
        {
            line = clean($0)
            if (line == "server {") servers++
            if (line == "server_name " domain ";") names++
            if (line in settings) {
                seen[line]++
                $0 = uncomment($0)
            }
            if (line == "listen 443 ssl;" && !ipv6) {
                print $0
                print "    listen [::]:443 ssl;"
                seen["listen [::]:443 ssl;"]++
                next
            }
            if (redirect && line == "if ($scheme = http ) {") {
                redirects++
                print uncomment($0)
                if ((getline action) != 1 || clean(action) != "return 301 https://$host$request_uri;") exit 1
                if ((getline closing) != 1 || clean(closing) != "}") exit 1
                print uncomment(action)
                print uncomment(closing)
                next
            }
            print
        }
        END {
            for (setting in settings) if (seen[setting] != 1) exit 1
            if (servers != 1 || names != 1 || (redirect && redirects != 1)) exit 1
        }
    ' "$config_file" "$config_file" > "$temp_file"; then
        rm -f -- "$temp_file"
        log "ERROR: Config does not match the create_proxy HTTPS template; no changes made."
        return 1
    fi

    # 备份不以 .conf 结尾，避免被 Nginx 当作站点配置加载。
    if ! backup_file=$(sudo mktemp "${config_file}.bak.XXXXXX"); then
        rm -f -- "$temp_file"
        return 1
    fi
    if ! sudo cp -p -- "$config_file" "$backup_file"; then
        rm -f -- "$temp_file"
        sudo rm -f -- "$backup_file"
        log "ERROR: Could not back up ${config_file}; no changes made."
        return 1
    fi

    if ! sudo cp -- "$temp_file" "$config_file" || ! "${nginx_command[@]}" -t || ! "${nginx_command[@]}" -s reload; then
        rm -f -- "$temp_file"
        if sudo cp -p -- "$backup_file" "$config_file"; then
            log "ERROR: HTTPS activation failed; original config restored from ${backup_file}."
        else
            log "ERROR: HTTPS activation and restore failed. Restore ${config_file} from ${backup_file} manually."
        fi
        return 1
    fi

    rm -f -- "$temp_file"
    log "HTTPS enabled for ${domain_name}. Backup: ${backup_file}"
}

_deploy_database_container() (
    local container="$1" volume="$2" password_file="$3" password_variable="$4"
    shift 4
    local password password_temp=""
    trap '[ -z "$password_temp" ] || rm -f -- "$password_temp"' EXIT

    sudo docker info >/dev/null || return 1
    if sudo docker container inspect "$container" >/dev/null 2>&1; then
        log "ERROR: Container $container already exists; its data and saved password were preserved."
        return 1
    fi
    if [ -e "$password_file" ]; then
        if [ ! -f "$password_file" ] || [ ! -s "$password_file" ]; then
            log "ERROR: $password_file must contain the existing database password."
            return 1
        fi
        password=$(cat -- "$password_file") || return 1
        if [ -z "$password" ] || [[ "$password" == *$'\n'* || "$password" == *$'\r'* ]]; then
            log "ERROR: $password_file must contain one non-empty password line."
            return 1
        fi
    elif sudo docker volume inspect "$volume" >/dev/null 2>&1; then
        log "ERROR: Volume $volume already exists. Restore its original password in $password_file before redeploying."
        return 1
    else
        password=$(openssl rand -hex 16) || return 1
        password_temp=$(mktemp "${password_file}.tmp.XXXXXX") || return 1
        printf '%s\n' "$password" > "$password_temp" || return 1
        # 初始化数据前持久保存新密码，失败重试仍可复用；绝不覆盖已有文件。
        if ! ln -- "$password_temp" "$password_file"; then
            log "ERROR: Could not save $password_file without overwriting an existing file; deployment stopped."
            return 1
        fi
    fi

    sudo docker network inspect network1 >/dev/null 2>&1 || sudo docker network create network1 || return 1
    sudo docker volume create "$volume" >/dev/null || return 1
    sudo docker run -d --name "$container" --restart=always --network network1 \
        --env "${password_variable}=${password}" "$@"
)

deploy_mysql(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi
    
    local port=${1:-3306}
    log "安装 MySQL"
    # docker run -dp ${port}:3306 --name mysql1 --restart=always --network network1 --network-alias mysql -v mysql-data:/var/lib/mysql \
    # -e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} \
    # -e TZ=Asia/Shanghai \
    # -e MYSQL_USER=user1 \
    # -e MYSQL_PASSWORD=123 \
    # -e MYSQL_DATABASE=db1 \
    # -e MYSQL_CHARSET=utf8mb4 \
    # -e MYSQL_COLLATION=utf8mb4_unicode_ci \
    # mysql:5.7-debian \
    # --character-set-server=utf8mb4 \
    # --collation-server=utf8mb4_unicode_ci

    _deploy_database_container mysql1 mysql-data MYSQL_ROOT_PASSWORD.txt MARIADB_ROOT_PASSWORD \
        -p "${port}:3306" \
        --network-alias mysql \
        -v mysql-data:/var/lib/mysql \
        --env TZ=Asia/Shanghai \
        --env MARIADB_USER=user1 \
        --env MARIADB_PASSWORD=123 \
        --env MARIADB_DATABASE=db1 \
        --env MARIADB_CHARSET=utf8mb4 \
        --env MARIADB_COLLATION=utf8mb4_unicode_ci \
        mariadb:10.6-jammy \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci || return 1

    # 旧版本
    # docker exec -it mysql1 sed -i -E 's/max_connections(\s*)= [0-9]+/max_connections\1= 1000/g' /etc/mysql/my.cnf
    # docker exec -it mysql1 sed -i -E 's/wait_timeout(\s*)= [0-9]+/wait_timeout\1= 86400/g' /etc/mysql/my.cnf

    sudo docker exec mysql1 sed -i -E 's/max_connections(\s*)= [0-9]+/max_connections\1= 1000/g' /etc/mysql/mariadb.conf.d/50-server.cnf || return 1
    sudo docker exec mysql1 sed -i -E 's/wait_timeout(\s*)= [0-9]+/wait_timeout\1= 86400/g' /etc/mysql/mariadb.conf.d/50-server.cnf
}

create_database(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} domain_name"
        return
    fi
    
    if [ "$#" -ne 1 ] || ! _valid_domain_name "$1"; then
        log "ERROR: Provide one valid domain name."
        return 1
    fi
    local domain_name="$1" MYSQL_ROOT_PASSWORD
    MYSQL_ROOT_PASSWORD=$(cat MYSQL_ROOT_PASSWORD.txt) || return 1
    [ -n "$MYSQL_ROOT_PASSWORD" ] || return 1

    # 将创建数据库的sql语句写入sql文件并通过-i参数和<输入重定向符号传递给容器内的命令执行
    local db_password
    db_password=$(openssl rand -hex 16) || return 1
    local db_user=${domain_name//./_}
    if [ "${#db_user}" -gt 61 ]; then
        log "ERROR: The generated database name exceeds MariaDB's 64-character limit."
        return 1
    fi
    
    cat >"${domain_name}.sql" <<EOF || return 1
CREATE DATABASE \`${db_user}_db\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
CREATE USER '${db_user}'@'%' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON \`${db_user}_db\`.* TO '${db_user}'@'%';
FLUSH PRIVILEGES;
EOF

    local cmd
    printf -v cmd 'mysql -h 127.0.0.1 -P 3306 -u root --password=%q < %q' "$MYSQL_ROOT_PASSWORD" "${domain_name}.sql"
    log "请执行${cmd}创建数据库和用户 mysql://${db_user}:${db_password}@mysql:3306/${db_user}_db"
    log "在容器内创建需执行 sudo docker exec -i mysql1 ${cmd}"
}

deploy_redis(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi
    
    local port=${1:-6379}
    sudo docker network inspect network1 >/dev/null 2>&1 || sudo docker network create network1

    sudo mkdir -p /opt/redis1
    sudo chmod 777 /opt/redis1
    log "安装 Redis" 
    sudo docker run -dp "${port}:6379" \
        --name redis1 \
        --restart=always \
        --network network1 \
        --network-alias redis \
        -v /opt/redis1:/data \
        -e TZ=Asia/Shanghai \
        redis:7.2-bookworm \
        redis-server --save 60 1 --loglevel warning --requirepass "123qweQ!"
    # 传给redis服务器的启动参数：若每60秒至少有一个键被修改了1次，就将数据持久化到磁盘，只记录警告及更高级别的日志
    # 连接字符串
    # redis://default:123qweQ!@localhost:6379/0
    # 连接方式：redis-cli
    # docker run -it --network redis --rm redis redis-cli -h redis1
}

deploy_postgres(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi
    
    local port=${1:-5432}
    log "安装 PostgreSQL"
    _deploy_database_container postgres1 postgre-data PGSQL_ROOT_PASSWORD.txt POSTGRES_PASSWORD \
        -p "${port}:5432" \
        --network-alias postgres \
        -e TZ=Asia/Shanghai \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_DB=postgres \
        -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C" \
        -e PGDATA=/var/lib/postgresql/data \
        -v postgre-data:/var/lib/postgresql/data \
        postgres:16-bookworm -c shared_buffers=256MB -c max_connections=200
}

deploy_rabbitmq(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi
    
    local port=${1:-5672}
    sudo docker network inspect network1 >/dev/null 2>&1 || sudo docker network create network1

    log "安装 RabbitMQ"
    sudo docker run -dp "${port}:5672" -p 15672:15672 \
        --name rabbitmq1 \
        --restart=always \
        --network network1 \
        --network-alias rabbitmq \
        -e TZ=Asia/Shanghai \
        -e RABBITMQ_DEFAULT_USER=user1 \
        -e RABBITMQ_DEFAULT_PASS=123qwe123@ \
        rabbitmq
}

create_default_vhost(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    sudo mkdir -p /var/www/html
    sudo touch /var/www/html/index.html
    sudo chmod 755 /var/www/html/index.html
    sudo tee /var/www/html/index.html <<EOF >/dev/null
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
    <meta charset="UTF-8">
    <link rel="icon" href="data:,">
    <title>404 Not Found</title>
</head>
<body>
    <center><h1>404 未找到站点</h1></center><hr>
    <center><p>抱歉，您访问的站点不存在。</p></center>
    <hr><center>nginx</center>
</body>
EOF

    sudo tee /etc/nginx/conf.d/default.conf << 'EOF' >/dev/null
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  root /var/www/html;

  index index.html index.htm index.nginx-debian.html;

  server_name _;

  location / {
   try_files $uri $uri/ =404;
  }
}
EOF
}

deploy_nginx(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    
    log "安装 Nginx"
    # 修改后的检测逻辑
    if sudo ss -tulpn | grep -q ':80 '; then
        log "错误: 宿主机 80 端口已被监听（占用），请先停止相关服务后再部署！"
        return 1
    fi
    sudo docker run -d \
        --name nginx1 \
        --restart=always \
        --network host \
        -v /var/www:/var/www \
        -v /var/ssl:/var/ssl \
        -v /etc/nginx/conf.d:/etc/nginx/conf.d \
        -e TZ=Asia/Shanghai \
        nginx:stable-bullseye

    create_default_vhost
    sudo docker exec nginx1 nginx -t && sudo docker exec nginx1 nginx -s reload
}

deploy_portainer(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [local_port]"
        return
    fi
    
    echo -e "\n\n\n------------------------------部署 Portainer------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local local_port=${1:-9000}
    # https://docs.portainer.io/start/install/server/docker/linux
    sudo docker volume create portainer_data
    sudo docker run -d -p "${local_port}:9000" \
        --name portainer1 \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        -e TZ=Asia/Shanghai \
        portainer/portainer-ce
    # 汉化版
    # docker run -d -p ${local_port}:9000 --name portainer1 --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data -e TZ=Asia/Shanghai 6053537/portainer
}

deploy_wordpress(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [local_port]"
        return
    fi
    
    echo -e "\n\n\n------------------------------部署 Wordpress------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local local_port=${1:-8000}
    sudo mkdir -p /opt/wordpress1
    sudo chmod 777 /opt/wordpress1
    sudo docker run -dp "127.0.0.1:${local_port}:80" \
        --name wordpress1 \
        --restart=always \
        --network network1 \
        -v /opt/wordpress1:/var/www/html \
        -e TZ=Asia/Shanghai \
        -e WORDPRESS_CONFIG_EXTRA="define( 'FORCE_SSL_ADMIN', true ); if( strpos( \$_SERVER['HTTP_X_FORWARDED_PROTO'], 'https') !== false ) { \$_SERVER['HTTPS'] = 'on'; }" \
        wordpress
}

deploy_gitea(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [local_port] [ssh_port]"
        return
    fi
    
    echo -e "\n\n\n------------------------------部署 Gitea------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local local_port=${1:-3000}
    local ssh_port=${2:-222}
    sudo docker info >/dev/null || return 1
    if sudo docker container inspect gitea1 >/dev/null 2>&1; then
        log "ERROR: gitea1 already exists. Preserve its volumes and follow the README migration steps before recreating it."
        return 1
    fi
    # rootless 镜像固定以 1000:1000 运行，USER_UID/USER_GID 不会更改此用户。
    sudo install -d -m 0755 -o 1000 -g 1000 /opt/gitea/data /opt/gitea/config || return 1
    sudo docker run -d \
        --name gitea1 \
        --restart=always \
        -p "127.0.0.1:${local_port}:3000" -p "${ssh_port}:2222" \
        -v /opt/gitea/data:/var/lib/gitea \
        -v /opt/gitea/config:/etc/gitea \
        -v /etc/timezone:/etc/timezone:ro \
        -v /etc/localtime:/etc/localtime:ro \
        gitea/gitea:1-rootless
    # rootless版默认监听2222, 否则监听22

    # 对外展示的 SSH_PORT 应与 ssh_port 一致；rootless 的 SSH_LISTEN_PORT 为 2222。

    # ssh://git@git.iapp.run:222/zero-ljz/repo.git
}


install_aria2(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    echo -e "\n\n\n------------------------------安装 Aria2------------------------------"
    echo "是否继续？ (y)" && read -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return
    sudo apt -y install aria2 || return 1
    sudo mkdir -p /etc/aria2/ || return 1
    sudo touch /etc/aria2/aria2.session || return 1
    sudo wget -O /etc/aria2/aria2.conf https://1fxdpq.dm.files.1drv.com/y4mIiwJL9lNeIdO8lXxaVlJ8CgaezUd3kIe7r8ZcAFytG78pUdSN0RprxwsYBW87AwMyXDAtEc3mLeTYBWHf_D4ngSWtjlCGvsoyA9YVs5Vs2X5taFFJmyl-5VgrMoj4EIKg0PsNXX-U6WC5INaaAK8fCrltwvj0lM0cRW0CuHSfxyAJZ0HaNph3kBqMCrtTwO5M_XR22RkpTRzolxlli3TxQ || return 1

    echo -e "\n\n\n 使用 systemd 守护 Aria2c RPC Server 进程"
    create_service aria2c "aria2c --conf-path=/etc/aria2/aria2.conf" /etc/aria2/ || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable aria2c || return 1
    sudo systemctl restart aria2c
    # 防火墙需要放行6800

}


install_frp(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    echo -e "\n\n\n------------------------------安装 Frp------------------------------"
    echo -e "\n\n\n下载 Frp 二进制包"
    wget --no-check-certificate -O "frp_0.58.0_linux_${ARCH}.tar.gz" "https://github.com/fatedier/frp/releases/download/v0.58.0/frp_0.58.0_linux_${ARCH}.tar.gz" || return 1
    sudo tar xzvf "frp_0.58.0_linux_${ARCH}.tar.gz" -C /usr/local/bin/ || return 1
    sudo mv "/usr/local/bin/frp_0.58.0_linux_${ARCH}" /usr/local/bin/frp || return 1

    sudo tee /usr/local/bin/frp/frps.ini <<EOF >/dev/null || return 1
[common]
bind_addr = 0.0.0.0
bind_port = 7000

vhost_http_port = 8080

dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = admin

EOF

}

install_frps()
{
    install_frp || return 1

    echo -e "\n\n\n 使用 systemd 守护 Frps 进程"
    create_service frps "/usr/local/bin/frp/frps -c /usr/local/bin/frp/frps.ini" /usr/local/bin/frp || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable frps || return 1
    sudo systemctl restart frps
}


install_gost(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装 Gost 隧道工具------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return
    
    # 更新系统并安装解压工具
    sudo apt update && sudo apt install -y wget gzip || return 1

    # 下载最新的 gost 2.11.5 版本（这是最经典的稳定版本）
    wget "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-${ARCH}-2.11.5.gz" || return 1

    # 解压并重命名
    gzip -d "gost-linux-${ARCH}-2.11.5.gz" || return 1
    mv "gost-linux-${ARCH}-2.11.5" gost || return 1

    # 赋予执行权限并移动到系统目录
    chmod +x gost || return 1
    sudo mv gost /usr/local/bin/ || return 1
    
    echo -e "\n\n\n 生成配置文件"
    sudo mkdir -p /etc/gost || return 1
    
    sudo tee /etc/gost/config.json << 'EOF' >/dev/null || return 1
{
"Debug": true,
"Retries": 3,
"ServeNodes": [
    "tcp://:9999/111.111.111.111:8888",
    "udp://:9999/111.111.111.111:8888",

    "tcp://:7777/111.111.111.111:5555",
    "udp://:7777/111.111.111.111:5555"
]
}
EOF

    # 在中转机上执行，把本地的 9999 端口流量转发到高延迟机的 8888 端口
    # /usr/local/bin/gost -L tcp://:9999/111.111.111.111:8888 -L udp://:9999/111.111.111.111:8888

    echo -e "\n\n\n 使用 Systemd 配置 Gost 开机自启"
    GOST_BIN=$(which gost || echo "/usr/local/bin/gost")
    create_service "gost" "${GOST_BIN} -C /etc/gost/config.json" "/etc/gost" || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable gost || return 1
    sudo systemctl start gost || return 1
    log "Gost 已通过 Systemd 成功启动并设置开机自启"
}







docker_build_run() (
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} repo_url port_port"
        return
    fi
    
    if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        log "Usage: ${FUNCNAME} repo_url port_port"
        return 1
    fi
    local url="$1" p="$2"
    local repo="${url%/}"
    repo="${repo##*/}"
    repo="${repo##*:}"
    repo="${repo%.git}"
    if [[ ! "$repo" =~ ^[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*$ ]]; then
        log "ERROR: Repository name must be a valid lowercase Docker image name."
        return 1
    fi

    # bash /root/ccc.sh docker_build_run https://github.com/zero-ljz/iapp.git 777:8000
    # 只清理本次创建的临时目录，不删除源仓库或当前目录中的同名目录。
    local work_dir
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ccc-build.XXXXXX") || return 1
    trap 'rm -rf -- "$work_dir"' EXIT
    git clone -- "$url" "$work_dir/source" || return 1
    sudo docker build -t "$repo" "$work_dir/source" || return 1

    # 克隆和构建成功后才替换旧容器，保留旧镜像供恢复。
    if sudo docker container inspect "${repo}1" >/dev/null 2>&1; then
        sudo docker rm -f "${repo}1" || return 1
    fi
    sudo docker run -p "$p" --name "${repo}1" "$repo" || return 1
    sudo docker exec -it "${repo}1" sh
)

deploy_debian() {
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    # 创建空的 Debian 容器并保持运行
    sudo docker run -d --name debian1 --network host debian:bullseye sleep infinity || return 1

    local commands=$(cat <<EOF
set -e
apt-get update
apt-get -y install --no-install-recommends wget curl nano micro
rm -rf /var/lib/apt/lists/*
EOF
    )
    sudo docker exec debian1 bash -c "$commands"
}

deploy_python_app() {
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} repo_url http_port command"
        return
    fi
    # sudo docker rm -f iapp && sudo bash ccc.sh deploy_python_app https://github.com/zero-ljz/iapp.git 8000 "python3 -m gunicorn -w 2 -b 0.0.0.0:8000 -k gevent app:app"
    local repo_url="${1:-}"
    local http_port="${2:-8000}"
    local command="${3:-"python3 -m gunicorn -b 0.0.0.0:8000 app:app"}"
    local repo="${repo_url##*/}" repo_arg commands
    repo="${repo%.git}"
    if [[ ! "$repo" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        log "ERROR: Provide a repository URL with a valid repository name."
        return 1
    fi
    printf -v repo_arg '%q' "$repo_url"
    commands=$(cat <<EOF

set -e
apt-get update
apt-get -y install --no-install-recommends git wget ca-certificates
if [ -d .git ]; then git pull; else git clone ${repo_arg} .; fi
# pip config set global.index-url https://pypi.mirrors.ustc.edu.cn/simple/
python3 -m pip install -r requirements.txt
${command}
EOF
    )
    sudo docker run -d -p "${http_port}:8000" \
        --name "$repo" \
        --restart=always \
        -v "/opt/${repo}:/usr/src/app" \
        -w /usr/src/app \
        -e TZ=Asia/Shanghai \
        python:3.10.11-slim-bullseye bash -c "$commands" || return 1
    sudo docker logs "$repo"
}

deploy_node_app() {
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} repo_url http_port command"
        return
    fi

    local repo_url="${1:-}"
    local http_port="${2:-3000}"
    local command="${3:-"npm start"}"
    local repo="${repo_url##*/}" repo_arg commands
    repo="${repo%.git}"
    if [[ ! "$repo" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        log "ERROR: Provide a repository URL with a valid repository name."
        return 1
    fi
    printf -v repo_arg '%q' "$repo_url"
    commands=$(cat <<EOF

set -e
apt-get update
apt-get -y install --no-install-recommends git wget ca-certificates
if [ -d .git ]; then git pull; else git clone ${repo_arg} .; fi
npm install --production --silent
${command}
EOF
)
    sudo docker run -d -p "${http_port}:3000" \
        --name "$repo" \
        --restart=always \
        -v "/opt/${repo}:/usr/src/app" \
        -w /usr/src/app \
        -e TZ=Asia/Shanghai \
        -e NODE_ENV=production \
        node:lts-bullseye-slim bash -c "$commands" || return 1
    sudo docker logs "$repo"
}

deploy_php_app() {
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} app_name http_port"
        return
    fi

    local app_name="$1"
    local http_port="$2"
    sudo docker run -d -p "${http_port}:80" --name "$app_name" -v "/opt/${app_name}:/var/www/html" php:7.4-apache || return 1
    # 容器内站点配置文件 /etc/apache2/sites-available/000-default.conf
    # 在php官方docker镜像中安装扩展
    sudo docker exec "$app_name" sh -c '
        set -eu
        installer=$(mktemp)
        trap '\''rm -f -- "$installer"'\'' EXIT
        curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions -o "$installer"
        sh "$installer" gd xdebug pdo_mysql
    '
    #docker exec -t ${app_name} chmod -R 755 /var/www/html
    # download_php_apps /opt/${app_name}
}

docker_run_app(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [interpreter] [command]..."
        return
    fi

    local interpreter=${1:-"python3"}
    shift 1
    local command=""
    
    if [ "$interpreter" = "python3" ]; then
        command=${@:-"python3 -m pip install -r requirements.txt && python3 app.py"}
        # 3.11-alpine3.17
        sudo docker run -it --rm -p 8000:8000 --name py1 -v "$PWD":/usr/src/myapp -w /usr/src/myapp python:3.10.11-slim-bullseye bash -c "${command}"
    elif [ "$interpreter" = "python" ]; then
        command=${@:-"python -m pip install -r requirements.txt && python app.py"}
        sudo docker run -it --rm -p 8000:8000 --name py1 -v "$PWD":/usr/src/myapp -w /usr/src/myapp python:2.7.18-slim-buster bash -c "${command}"
    elif [ "$interpreter" = "php" ]; then
        command=${@:-""}
        sudo docker run -it --rm -p 8000:80 --name php-httpd1 -v "$PWD":/var/www/html php:7.4-apache ${command}
    elif [ "$interpreter" = "php-cli" ]; then
        command=${@:-"php app.php"}
        sudo docker run -it --rm -p 8000:8000 --name php-cli1 -v "$PWD":/usr/src/myapp -w /usr/src/myapp php:7.4-cli ${command}
    elif [ "$interpreter" = "node" ]; then
        command=${@:-"node app.js"}
        sudo docker run -it --rm -p 8000:8000 --name node1 -v "$PWD":/usr/src/app -w /usr/src/app node:18-bullseye-slim ${command}
    elif [ "$interpreter" = "ruby" ]; then
        command=${@:-"ruby app.rb"}
        sudo docker run -it --rm -p 8000:8000 --name ruby1 -v "$PWD":/usr/src/myapp -w /usr/src/myapp ruby:2.7.2-bullseye ${command}
    elif [ "$interpreter" = "perl" ]; then
        command=${@:-"perl app.pl"}
        sudo docker run -it --rm --name perl1 -v "$PWD":/usr/src/myapp -w /usr/src/myapp perl:5.34.0-bullseye ${command}
    fi
}

# nginx 部署静态网站
# docker run -dp 8080:80 --name web1 --restart=always -v /opt/web1:/usr/share/nginx/html nginx:stable-alpine-slim

function auto_mode(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    
    system_init
    install_supervisor
    install_docker

    deploy_nginx
    deploy_mysql
    deploy_redis


    # tinyfilemanager admin/admin@123
    # docker run -d -v /:/var/www/html/data -p 8020:80 --restart=always --name tinyfilemanager1 tinyfilemanager/tinyfilemanager:master

    # adminer
    # docker run -d --link mysql1:db --network network1 -p 8021:8080 --restart=always --name adminer1 adminer

    # deploy_portainer 9001
    # create_proxy docker.iapp.run 9001

    local domain_name=blog.iapp.run
    local port=8010
    deploy_wordpress ${port}
    create_database ${domain_name}
    create_proxy ${domain_name} ${port}
    create_ssl ${domain_name}

    # domain_name=a.iapp.run
    # create_vhost ${domain_name}
    # create_ssl ${domain_name}
    # create_database ${domain_name}
}

install_fail2ban(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装 fail2ban------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    sudo apt update && sudo apt install -y fail2ban
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    log "fail2ban 安装完成并已启动，默认已对 sshd 启用保护"
}

install_monitoring_tools(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装系统监控工具 (htop, btop, ncdu)------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    sudo apt update && sudo apt install -y htop btop ncdu
    log "系统监控工具 (htop, btop, ncdu) 安装完成！"
}

deploy_netdata(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi

    echo -e "\n\n\n------------------------------部署 Netdata 监控------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local port=${1:-19999}
    sudo docker run -d --name=netdata1 \
        -p "${port}:19999" \
        --pid=host \
        -v netdataconfig:/etc/netdata \
        -v netdatalib:/var/lib/netdata \
        -v netdatacache:/var/cache/netdata \
        -v /etc/passwd:/host/etc/passwd:ro \
        -v /etc/group:/host/etc/group:ro \
        -v /proc:/host/proc:ro \
        -v /sys:/host/sys:ro \
        -v /etc/os-release:/host/etc/os-release:ro \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        --restart always \
        --cap-add SYS_PTRACE \
        --security-opt apparmor=unconfined \
        netdata/netdata
    log "Netdata 部署成功，请访问 http://IP:${port}"
}

deploy_adminer(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port]"
        return
    fi

    echo -e "\n\n\n------------------------------部署 Adminer 数据库管理工具------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local port=${1:-8080}
    sudo docker network inspect network1 >/dev/null 2>&1 || sudo docker network create network1
    sudo docker run -d --name adminer1 \
        --restart always \
        --network network1 \
        -p "${port}:8080" \
        adminer
    log "Adminer 部署成功，请访问 http://IP:${port} (可在登录页指定主机为 mysql1 等)"
}

deploy_redis_commander(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port] [redis_host] [redis_port] [redis_password]"
        return
    fi

    echo -e "\n\n\n------------------------------部署 Redis Commander 可视化后台------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local port=${1:-8081}
    local redis_host=${2:-"redis1"}
    local redis_port=${3:-6379}
    local redis_pass=${4:-"123qweQ!"}

    sudo docker network inspect network1 >/dev/null 2>&1 || sudo docker network create network1 || return 1
    sudo docker run -d --name redis-commander1 \
        --restart always \
        --network network1 \
        -p "${port}:8081" \
        -e REDIS_HOST="$redis_host" \
        -e REDIS_PORT="$redis_port" \
        -e REDIS_DB=0 \
        -e REDIS_PASSWORD="$redis_pass" \
        rediscommander/redis-commander:latest || return 1
    log "Redis Commander 部署成功，请访问 http://IP:${port}"
}

deploy_watchtower(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------部署 Watchtower 容器自动更新工具------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    sudo docker run -d --name watchtower1 \
        --restart always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        containrrr/watchtower \
        --cleanup \
        --schedule "0 0 3 * * *"
    log "Watchtower 部署成功，每日凌晨 3 点会自动检测并更新所有容器的镜像，并清理旧镜像。"
}

install_rclone(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi

    echo -e "\n\n\n------------------------------安装 Rclone 备份/同步工具------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    curl https://rclone.org/install.sh | sudo bash
    log "Rclone 安装完成，请输入 rclone config 配置您的云盘/对象存储"
}

deploy_filebrowser(){
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Usage: ${FUNCNAME} [port] [root_dir]"
        return
    fi

    echo -e "\n\n\n------------------------------部署 File Browser 网盘与文件管理器------------------------------"
    read -p "是否继续？ (y)" -t 5 answer && [ ! $? -eq 142 ] && [ "$answer" != "y" ] && return

    local port=${1:-8082}
    local root_dir=${2:-"/"}

    sudo mkdir -p /opt/filebrowser
    sudo touch /opt/filebrowser/filebrowser.db
    sudo chmod 666 /opt/filebrowser/filebrowser.db

    sudo docker run -d --name filebrowser1 \
        --restart always \
        -v "${root_dir}:/srv" \
        -v /opt/filebrowser/filebrowser.db:/database/filebrowser.db \
        -p "${port}:80" \
        -e TZ=Asia/Shanghai \
        filebrowser/filebrowser
    log "File Browser 部署成功，请访问 http://IP:${port} (默认用户名/密码: admin/admin)"
}

upgrade() (
    if [ "$1" = "-d" ] || [ "$1" = "--declare" ]; then declare -f ${FUNCNAME}; return; fi
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        log "Description: Upgrade this script, Perform this operation in the working directory"
        exit 0
    fi
    local url="https://raw.githubusercontent.com/zero-ljz/debian-server-toolkit/main/ccc.sh"
    log "正在从 ${url} 下载最新版本脚本..."
    
    local script_path script_dir ownership
    script_path=$(readlink -f -- "${BASH_SOURCE[0]}") || return 1
    if [ ! -f "$script_path" ]; then
        log "错误：无法确定脚本路径，升级失败"
        return 1
    fi
    script_dir=$(dirname -- "$script_path") || return 1
    ownership=$(stat -c '%u:%g' -- "$script_path") || return 1
    local -a privilege=()
    # 用户目录内自行更新；受保护目录或不同属主的文件通过 sudo 保留原属主。
    if [ ! -w "$script_dir" ] || [ ! -x "$script_dir" ] || [ "$ownership" != "$(id -u):$(id -g)" ]; then
        privilege=(sudo)
    fi

    local tmp_file staged_file=""
    tmp_file=$(mktemp) || return 1
    trap 'rm -f -- "$tmp_file"; if [ -n "$staged_file" ]; then "${privilege[@]}" rm -f -- "$staged_file"; fi' EXIT
    if ! curl -LfsS "$url" -o "$tmp_file"; then
        log "错误：下载失败，原脚本未修改"
        return 1
    fi
    if [ ! -s "$tmp_file" ] || ! bash -n "$tmp_file"; then
        log "错误：下载的脚本为空或 Bash 语法检查失败，原脚本未修改"
        return 1
    fi

    # 同目录暂存后原子替换，避免跨文件系统移动或写入失败损坏原脚本。
    staged_file=$("${privilege[@]}" mktemp "${script_path}.new.XXXXXX") || return 1
    if ! "${privilege[@]}" cp -- "$tmp_file" "$staged_file" ||
        ! "${privilege[@]}" chown --reference="$script_path" "$staged_file" ||
        ! "${privilege[@]}" chmod --reference="$script_path" "$staged_file" ||
        ! "${privilege[@]}" mv -fT -- "$staged_file" "$script_path"; then
        log "错误：脚本替换失败，原脚本未修改"
        return 1
    fi
    staged_file=""
    log "脚本更新成功！"
)

systeminfo()
{
    sudo apt -y install lsb-release curl || return 1
    uname -a && lsb_release -a && lscpu && cat /etc/os-release && hostnamectl && df -h && free -h && timedatectl && curl ipinfo.io
}

# 获取函数名
function_name=${1:-default}
shift  # 移除第一个参数，剩下的参数会被传递给函数

# 获取可用函数列表
function_list=$(compgen -A function | grep -v '^_')

# 定义在不传入参数时默认执行的函数
function default()
{
    log "Usage: ${FUNCNAME} [function_name] [-h] [arguments]"
    echo -e "\nAvailable functions:"
    for func in $function_list; do
        echo "  $func"
    done
    echo
}

# 调用指定的函数，并传递参数
"$function_name" "$@"
