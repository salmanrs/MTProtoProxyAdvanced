#!/bin/bash
# MTProto Proxy Installer Script with Advanced Features
# Based on Python proxy features

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Variables
PROXY_DIR="/usr/local/mtproto-proxy"
CONFIG_DIR="$PROXY_DIR/config"
SCRIPTS_DIR="$PROXY_DIR/scripts"
SERVICE_FILE="/etc/systemd/system/mtproto-proxy.service"

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "Please run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS="centos"
        PKG_MANAGER="yum"
    elif [ -f /etc/debian_version ]; then
        OS="ubuntu"
        PKG_MANAGER="apt"
    else
        print_error "Unsupported OS"
        exit 1
    fi
    print_info "Detected OS: $OS"
}

install_dependencies() {
    print_info "Installing dependencies..."
    
    if [ "$OS" = "centos" ]; then
        yum update -y
        yum install -y gcc make openssl-devel git curl wget firewalld
        yum groupinstall -y "Development Tools"
        systemctl enable firewalld
        systemctl start firewalld
    elif [ "$OS" = "ubuntu" ]; then
        apt update -y
        apt install -y build-essential libssl-dev git curl wget ufw
        ufw --force enable
    fi
}

create_directories() {
    print_info "Creating directories..."
    mkdir -p $PROXY_DIR
    mkdir -p $CONFIG_DIR
    mkdir -p $SCRIPTS_DIR
}

download_source() {
    print_info "Downloading MTProto Proxy source..."
    cd /tmp
    git clone https://github.com/TelegramMessenger/MTProxy.git
    cd MTProxy
    make
    cp mtproto-proxy $PROXY_DIR/
    chmod +x $PROXY_DIR/mtproto-proxy
}

generate_secret() {
    print_info "Generating secret..."
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    echo "SECRET=$SECRET" > $CONFIG_DIR/secret.conf
    print_info "Secret: $SECRET"
}

create_config() {
    print_info "Creating configuration files..."
    
    cat > $CONFIG_DIR/proxy.conf << EOF
# MTProto Proxy Configuration
port=443
secret=$SECRET
max-connections=20
expire-time=2592000
data-limit=1073741824
enable-stats=true
stats-port=8888
EOF

    cat > $CONFIG_DIR/users.conf << EOF
# User Management
# Format: username:secret:max_connections:expire_time:data_limit
admin:$SECRET:50:0:0
EOF
}

setup_firewall() {
    print_info "Setting up firewall..."
    
    if [ "$OS" = "centos" ]; then
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=443/udp
        firewall-cmd --permanent --add-port=8888/tcp
        firewall-cmd --reload
    elif [ "$OS" = "ubuntu" ]; then
        ufw allow 443/tcp
        ufw allow 443/udp
        ufw allow 8888/tcp
    fi
}

create_systemd_service() {
    print_info "Creating systemd service..."
    
    cat > $SERVICE_FILE << EOF
[Unit]
Description=MTProto Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nobody
WorkingDirectory=$PROXY_DIR
ExecStart=$PROXY_DIR/mtproto-proxy -u nobody -p 8888 -H 443 -S $SECRET --aes-pwd $CONFIG_DIR/proxy.conf
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtproto-proxy
}

create_management_scripts() {
    print_info "Creating management scripts..."
    
    # User Manager Script
    cat > $SCRIPTS_DIR/user-manager.sh << 'EOF'
#!/bin/bash
USERS_FILE="/usr/local/mtproto-proxy/config/users.conf"

add_user() {
    local username=$1
    local secret=$(head -c 16 /dev/urandom | xxd -ps)
    local max_conn=${2:-10}
    local expire_time=${3:-2592000}
    local data_limit=${4:-1073741824}
    
    echo "$username:$secret:$max_conn:$expire_time:$data_limit" >> $USERS_FILE
    echo "User $username added with secret: $secret"
    systemctl restart mtproto-proxy
}

remove_user() {
    local username=$1
    sed -i "/^$username:/d" $USERS_FILE
    echo "User $username removed"
    systemctl restart mtproto-proxy
}

list_users() {
    echo "Current users:"
    cat $USERS_FILE | grep -v "^#"
}

case "$1" in
    add)
        add_user $2 $3 $4 $5
        ;;
    remove)
        remove_user $2
        ;;
    list)
        list_users
        ;;
    *)
        echo "Usage: $0 {add|remove|list} [username] [max_connections] [expire_time] [data_limit]"
        ;;
esac
EOF

    # Monitoring Script
    cat > $SCRIPTS_DIR/monitoring.sh << 'EOF'
#!/bin/bash
PROXY_DIR="/usr/local/mtproto-proxy"

show_status() {
    echo "=== MTProto Proxy Status ==="
    systemctl status mtproto-proxy --no-pager -l
    echo ""
    
    echo "=== Active Connections ==="
    netstat -an | grep :443 | wc -l
    echo ""
    
    echo "=== Memory Usage ==="
    ps aux | grep mtproto-proxy | grep -v grep
    echo ""
    
    echo "=== Disk Usage ==="
    du -sh $PROXY_DIR
}

show_logs() {
    journalctl -u mtproto-proxy -f
}

case "$1" in
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    *)
        echo "Usage: $0 {status|logs}"
        ;;
esac
EOF

    chmod +x $SCRIPTS_DIR/*.sh
}

optimize_performance() {
    print_info "Optimizing performance..."
    
    # Enable BBR
    echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    
    # Network optimizations
    echo 'net.ipv4.tcp_fastopen=3' >> /etc/sysctl.conf
    echo 'net.ipv4.tcp_low_latency=1' >> /etc/sysctl.conf
    echo 'net.core.rmem_max=134217728' >> /etc/sysctl.conf
    echo 'net.core.wmem_max=134217728' >> /etc/sysctl.conf
    
    sysctl -p
}

start_service() {
    print_info "Starting MTProto Proxy service..."
    systemctl start mtproto-proxy
    sleep 3
    
    if systemctl is-active --quiet mtproto-proxy; then
        print_info "MTProto Proxy started successfully!"
        print_info "Port: 443"
        print_info "Secret: $SECRET"
        print_info "Management: $SCRIPTS_DIR/user-manager.sh"
        print_info "Monitoring: $SCRIPTS_DIR/monitoring.sh"
    else
        print_error "Failed to start MTProto Proxy"
        journalctl -u mtproto-proxy --no-pager -l
        exit 1
    fi
}

show_connection_info() {
    echo ""
    echo "=================================="
    echo "MTProto Proxy Installation Complete!"
    echo "=================================="
    echo "Server IP: $(curl -s ifconfig.me)"
    echo "Port: 443"
    echo "Secret: $SECRET"
    echo ""
    echo "Telegram Link:"
    echo "https://t.me/proxy?server=$(curl -s ifconfig.me)&port=443&secret=$SECRET"
    echo ""
    echo "Management Commands:"
    echo "$SCRIPTS_DIR/user-manager.sh add username [max_conn] [expire] [data_limit]"
    echo "$SCRIPTS_DIR/user-manager.sh remove username"
    echo "$SCRIPTS_DIR/user-manager.sh list"
    echo "$SCRIPTS_DIR/monitoring.sh status"
    echo "$SCRIPTS_DIR/monitoring.sh logs"
    echo "=================================="
}

main() {
    print_info "Starting MTProto Proxy installation..."
    
    check_root
    detect_os
    install_dependencies
    create_directories
    download_source
    generate_secret
    create_config
    setup_firewall
    create_systemd_service
    create_management_scripts
    optimize_performance
    start_service
    show_connection_info
}

main "$@"
