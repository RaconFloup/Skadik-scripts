#!/bin/bash

# --- Цвета для оформления ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ГЛОБАЛЬНЫЕ НАСТРОЙКИ ---
D_PANEL_IP=""
D_NODE_PORT=""
D_VLESS_PORT=""
D_SSH_PORT=""
D_BESZEL_PORT=""
D_BESZEL_KEY=""          # Универсальный токен (TOKEN)
D_BESZEL_SSH_KEY=""      # Публичный SSH-ключ (KEY)
D_BESZEL_HUB_URL=""      # URL хаба Beszel
D_GITHUB_TOKEN=""

load_local_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local home_config="$HOME/.config/skadik/local.conf"
    local config_files=("$script_dir/.skadik.local.conf" "$home_config" "/etc/skadik/local.conf")
    local cfg
    local loaded=0

    for cfg in "${config_files[@]}"; do
        if [ -f "$cfg" ]; then
            source "$cfg"
            loaded=1
        fi
    done

    if [ "$loaded" -eq 0 ]; then
        mkdir -p "$(dirname "$home_config")"
        cat > "$home_config" <<'EOF'
# Конфиг Skadik (локальный, не добавляйте в git)
D_PANEL_IP=""
D_NODE_PORT=""
D_VLESS_PORT=""
D_SSH_PORT=""
D_BESZEL_PORT=""
D_BESZEL_HUB_URL=""
D_BESZEL_KEY=""
D_BESZEL_SSH_KEY=""
D_GITHUB_TOKEN=""
EOF
        chmod 600 "$home_config" 2>/dev/null
        source "$home_config"
        echo -e "${YELLOW}Создан конфиг: $home_config${NC}"
        echo -e "${YELLOW}Заполните параметры при необходимости и перезапустите скрипт.${NC}"
    fi
}

# --- ФУНКЦИИ МОНИТОРИНГА ---

check_status() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${GREEN}          ДИАГНОСТИКА СИСТЕМЫ И НОДЫ               ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    # Сетевые параметры
    ipv6_status=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
    [ "$ipv6_status" -eq 1 ] && echo -e "Протокол IPv6:       ${GREEN}[ ОТКЛЮЧЕН ]${NC}" || echo -e "Протокол IPv6:       ${RED}[ ВКЛЮЧЕН ]${NC}"

    bbr_status=$(sysctl -n net.ipv4.tcp_congestion_control)
    [ "$bbr_status" == "bbr" ] && echo -e "Ускорение BBR:       ${GREEN}[ АКТИВНО ]${NC}" || echo -e "Ускорение BBR:       ${RED}[ НЕАКТИВНО ]${NC}"

    qdisc_status=$(sysctl -n net.core.default_qdisc)
    echo -e "Метод обработки пакетов: ${YELLOW}[ $qdisc_status ]${NC}"

    ufw_raw_status=$(sudo ufw status)
    if echo "$ufw_raw_status" | grep -q "Status: active"; then
        echo -e "Защита Firewall:     ${GREEN}[ АКТИВНА ]${NC}"
    else
        echo -e "Защита Firewall:     ${RED}[ ВЫКЛЮЧЕНА ]${NC}"
    fi

    echo -e "${BLUE}----------------------------------------------------${NC}"
    # Контейнеры
    echo -ne "Статус Remnanode:    "
    if [ "$(docker ps -q -f name=remnanode)" ]; then echo -e "${GREEN}[ РАБОТАЕТ ]${NC}"; else echo -e "${RED}[ ОСТАНОВЛЕН ]${NC}"; fi
    
    echo -ne "Статус Beszel:       "
    if [ "$(docker ps -q -f name=beszel-agent)" ]; then echo -e "${GREEN}[ РАБОТАЕТ ]${NC}"; else echo -e "${RED}[ ОСТАНОВЛЕН ]${NC}"; fi

    echo -e "${BLUE}----------------------------------------------------${NC}"
    echo -e "${YELLOW}Внешние порты и уровень доступа:${NC}"

    # Получаем список слушающих сокетов, фильтруя системные и локальные порты
    mapfile -t listeners < <(sudo ss -tuln | awk 'NR>1 {print $1, $5}' | grep -vE ':(53|68|123|5353) ' | grep -v '127\.0\.0\.' | grep -v '\[::1\]')

    if [ ${#listeners[@]} -eq 0 ]; then
        echo -e "${RED}Нет слушающих портов (кроме возможно локальных)${NC}"
    else
        declare -A port_info
        for line in "${listeners[@]}"; do
            proto=$(echo "$line" | awk '{print $1}')
            addr_port=$(echo "$line" | awk '{print $2}')
            # Разбираем адрес и порт (поддержка IPv6 в скобках)
            if [[ "$addr_port" == *\]* ]]; then
                port="${addr_port##*:}"
                addr="${addr_port%]:*}"
                addr="${addr#\[}"
            else
                port="${addr_port##*:}"
                addr="${addr_port%:*}"
            fi
            [[ -z "$port" || "$port" -eq 0 ]] && continue

            # Определяем тип привязки
            access_type=""
            if [[ "$addr" == "0.0.0.0" || "$addr" == "::" ]]; then
                access_type="ALL_INTERFACES"
            elif [[ "$addr" == "127.0.0.1" || "$addr" == "::1" ]]; then
                access_type="LOOPBACK"
            else
                access_type="SPECIFIC_IP:$addr"
            fi

            # Сохраняем наиболее "открытый" тип доступа для порта
            if [[ -z "${port_info[$port]}" ]]; then
                port_info[$port]="$access_type"
            else
                current="${port_info[$port]}"
                if [[ "$current" == "LOOPBACK" && "$access_type" != "LOOPBACK" ]]; then
                    port_info[$port]="$access_type"
                fi
            fi
        done

        # Вывод по каждому порту
        for port in $(echo "${!port_info[@]}" | tr ' ' '\n' | sort -n); do
            info="${port_info[$port]}"
            echo -ne "👉 Порт ${GREEN}$port${NC} "
            case "$info" in
                ALL_INTERFACES)   echo -n "[СЛУШАЕТ ВСЕ ИНТЕРФЕЙСЫ] " ;;
                LOOPBACK)         echo -n "[ТОЛЬКО ЛОКАЛЬНО] " ;;
                SPECIFIC_IP:*)    ip="${info#SPECIFIC_IP:}"; echo -n "[ПРИВЯЗАН К $ip] " ;;
            esac

            # Проверяем правила UFW
            if [[ "$ufw_raw_status" == *"Status: active"* ]]; then
                ufw_rules=$(echo "$ufw_raw_status" | grep -E "(^| )$port(/| |$)")
                if [[ -n "$ufw_rules" ]]; then
                    rule_line=$(echo "$ufw_rules" | head -n1)
                    if echo "$rule_line" | grep -q "ALLOW"; then
                        if echo "$rule_line" | grep -q "Anywhere"; then
                            echo -e "${RED}[ПУБЛИЧНЫЙ ДОСТУП (Anywhere)]${NC}"
                        else
                            allowed_ip=$(echo "$rule_line" | awk '{print $NF}')
                            echo -e "${GREEN}[ДОСТУП РАЗРЕШЁН ТОЛЬКО ДЛЯ $allowed_ip]${NC}"
                        fi
                    elif echo "$rule_line" | grep -q "DENY"; then
                        echo -e "${RED}[ДОСТУП ЗАПРЕЩЁН UFW]${NC}"
                    else
                        echo -e "${YELLOW}[НЕЯВНОЕ ПРАВИЛО UFW]${NC}"
                    fi
                else
                    echo -e "${YELLOW}[НЕТ ПРАВИЛ В UFW (возможно открыт Docker'ом)]${NC}"
                fi
            else
                echo -e "${YELLOW}[UFW ОТКЛЮЧЕН, ПОРТ ДОСТУПЕН СОГЛАСНО IPTABLES]${NC}"
            fi
        done
    fi
    echo -e "${BLUE}====================================================${NC}"
}

# --- ФУНКЦИИ СЕРВИСА ---

update_script() {
    echo -e "${YELLOW}Запрос обновления с GitHub...${NC}"
    read -s -p "Введите GitHub Token (Enter = из локального конфига): " TEMP_TOKEN
    echo
    TEMP_TOKEN="${TEMP_TOKEN:-$D_GITHUB_TOKEN}"
    if [ -z "$TEMP_TOKEN" ]; then
        echo -e "${RED}Токен не задан. Добавьте D_GITHUB_TOKEN в локальный конфиг или введите вручную.${NC}"
        return
    fi

    sudo curl -f -H "Authorization: token $TEMP_TOKEN" \
         -H "Accept: application/vnd.github.v3.raw" \
         -L https://api.github.com/repos/RaconFloup/Skadik-scripts/contents/Install_node.sh \
         -o /usr/local/bin/skadik
    
    if [ $? -eq 0 ]; then
        sudo chmod +x /usr/local/bin/skadik
        echo -e "${GREEN}Обновление успешно. Перезапуск...${NC}"
        sleep 1
        exec skadik
    else
        echo -e "${RED}Ошибка обновления.${NC}"
    fi
}

# --- МОДУЛИ УСТАНОВКИ ---

prompt_value() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    read -p "$(echo -e "${YELLOW}${prompt_text}${NC} [${default_value}]: ")" input
    eval "$var_name=\"${input:-$default_value}\""
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Установка Docker...${NC}"
        sudo curl -fsSL https://get.docker.com | sh
    fi
}

install_network_opt() {
    echo -e "${YELLOW}Оптимизация сетевого стека...${NC}"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        SCHEDULER="fq"
        if lsmod | grep -q "cake" || modprobe sch_cake 2>/dev/null; then SCHEDULER="cake"; fi
        sudo tee -a /etc/sysctl.conf <<EOF

# Оптимизация сети Skadik
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = $SCHEDULER
net.ipv4.tcp_congestion_control = bbr
EOF
        sudo sysctl -p
    fi
    echo -e "${GREEN}Оптимизация завершена.${NC}"
}

install_firewall() {
    echo -e "${YELLOW}Настройка правил доступа...${NC}"
    prompt_value PANEL_IP "IP-адрес вашей панели" "$D_PANEL_IP"
    prompt_value NODE_PORT "Порт ноды (Management)" "$D_NODE_PORT"
    prompt_value VLESS_PORT "Порт для клиентов (VLESS)" "$D_VLESS_PORT"
    prompt_value SSH_PORT "Порт SSH" "$D_SSH_PORT"
    sudo ufw --force reset
    sudo ufw allow from "$PANEL_IP" to any port "$NODE_PORT"
    sudo ufw deny "$NODE_PORT"
    sudo ufw allow "$VLESS_PORT"
    sudo ufw allow "$SSH_PORT"
    sudo ufw allow "$D_BESZEL_PORT"/tcp
    echo "y" | sudo ufw enable
}

install_beszel() {
    check_docker
    mkdir -p /opt/beszel-agent && cd /opt/beszel-agent

    echo -e "${YELLOW}Настройка Beszel Agent${NC}"
    prompt_value B_LISTEN     "Порт для прослушивания"          "$D_BESZEL_PORT"
    prompt_value B_SSH_KEY    "Публичный SSH-ключ (KEY)"        "$D_BESZEL_SSH_KEY"
    prompt_value B_TOKEN      "Универсальный токен (TOKEN)"     "$D_BESZEL_KEY"
    prompt_value B_HUB_URL    "URL хаба Beszel"                 "$D_BESZEL_HUB_URL"

    cat <<EOF > docker-compose.yml
services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_data:/var/lib/beszel-agent
    environment:
      LISTEN: ${B_LISTEN}
      KEY: '${B_SSH_KEY}'
      TOKEN: ${B_TOKEN}
      HUB_URL: ${B_HUB_URL}
EOF

    sudo docker compose down 2>/dev/null
    sudo docker compose up -d
    sudo ufw allow "$B_LISTEN"/tcp
    echo -e "${GREEN}Beszel Agent установлен и запущен.${NC}"
}

install_node() {
    check_docker
    mkdir -p /opt/remnanode && cd /opt/remnanode
    echo -e "${YELLOW}Вставьте содержимое docker-compose.yml из панели:${NC}"
    read -p "Нажмите Enter для входа в редактор..."
    nano docker-compose.yml
    sudo docker compose up -d
}

# --- ОСНОВНОЕ МЕНЮ ---

show_menu() {
    local beszel_port_display="${D_BESZEL_PORT:-не задан}"
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${GREEN}            SKADIK HUB - ПАНЕЛЬ УПРАВЛЕНИЯ          ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    echo -e "${BLUE}[ МОНИТОРИНГ ]${NC}"
    echo "  1) Проверить состояние и доступность портов"
    echo "  2) Запустить тест скорости (Multitest)"
    
    echo -e "\n${BLUE}[ УСТАНОВКА КОМПОНЕНТОВ ]${NC}"
    echo "  3) Экспресс-установка Ноды"
    echo "  4) Установить только VPN Ноду"
    echo "  5) Установить Beszel Agent ($beszel_port_display)"
    
    echo -e "\n${BLUE}[ НАСТРОЙКА И ОПТИМИЗАЦИЯ ]${NC}"
    echo "  6) Оптимизация сети (BBR + CAKE + NoIPv6)"
    echo "  7) Перенастроить Firewall (UFW)"
    
    echo -e "\n${BLUE}[ ОБСЛУЖИВАНИЕ ]${NC}"
    echo "  8) Обновить этот скрипт"
    echo "  0) Выход"
    
    echo -e "${BLUE}====================================================${NC}"
    echo -ne "${YELLOW}Выберите действие: ${NC}"
    read -r choice

    case $choice in
        1) check_status ;;
        2) if [ -f "/usr/local/bin/multitest" ]; then multitest; else sudo curl -sL https://raw.githubusercontent.com/saveksme/multitest/master/multitest.sh -o /usr/local/bin/multitest && sudo chmod +x /usr/local/bin/multitest && multitest; fi ;;
        3) install_network_opt; install_firewall; install_beszel; install_node ;;
        4) install_node ;;
        5) install_beszel ;;
        6) install_network_opt ;;
        7) install_firewall ;;
        8) update_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка: неверный выбор${NC}"; sleep 1 ;;
    esac
}

while true; do
    clear
    load_local_config
    show_menu
    echo -e "\n${YELLOW}Нажмите Enter, чтобы вернуться в меню...${NC}"
    read -r
done
