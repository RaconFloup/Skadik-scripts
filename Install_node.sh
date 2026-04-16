#!/bin/bash

# --- Цвета для оформления ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
SCRIPT_INSTALL_DIR="/opt/skadik"
SCRIPT_INSTALL_PATH="${SCRIPT_INSTALL_DIR}/Install_node.sh"
SCRIPT_COMMAND_PATH="/usr/local/bin/skadik"
SCRIPT_VERSION="1.14"

# --- ГЛОБАЛЬНЫЕ НАСТРОЙКИ ---
D_PANEL_IP=""
D_NODE_PORT=""           # Значение по умолчанию берется из конфига (2222)
D_VLESS_PORT=""
D_SSH_PORT=""
D_BESZEL_PORT=""
D_BESZEL_KEY=""          # Универсальный токен (TOKEN)
D_BESZEL_SSH_KEY=""      # Публичный SSH-ключ (KEY)
D_BESZEL_HUB_URL=""      # URL хаба Beszel
D_REMNANODE_SECRET_KEY="" # Секретный ключ ноды

load_local_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local home_config="$HOME/.config/skadik/local.conf"
    local config_files=("$script_dir/.skadik.local.conf" "$home_config" "/etc/skadik/local.conf")
    local cfg
    local loaded=0

    for cfg in "${config_files[@]}"; do
        if [ -f "$cfg" ]; then
            # Auto-fix Windows CRLF to avoid "$'\r': command not found" on Linux.
            sed -i 's/\r$//' "$cfg" 2>/dev/null
            source "$cfg"
            loaded=1
        fi
    done

    if [ "$loaded" -eq 0 ]; then
        mkdir -p "$(dirname "$home_config")"
        cat > "$home_config" <<'EOF'
# Конфиг Skadik (локальный, не добавляйте в git)
D_PANEL_IP=""
D_NODE_PORT="2222"
D_VLESS_PORT=""
D_SSH_PORT=""
D_BESZEL_PORT=""
D_BESZEL_HUB_URL=""
D_BESZEL_KEY=""
D_BESZEL_SSH_KEY=""
D_REMNANODE_SECRET_KEY=""
EOF
        chmod 600 "$home_config" 2>/dev/null
        source "$home_config"
        echo -e "${YELLOW}Создан конфиг: $home_config${NC}"
        echo -e "${YELLOW}Заполните параметры при необходимости и перезапустите скрипт.${NC}"
    fi
}

ensure_global_command() {
    sudo mkdir -p "$(dirname "$SCRIPT_COMMAND_PATH")"
    sudo tee "$SCRIPT_COMMAND_PATH" > /dev/null <<EOF
#!/bin/bash
exec bash "$SCRIPT_INSTALL_PATH" "\$@"
EOF
    sudo chmod +x "$SCRIPT_COMMAND_PATH"
}

ui_line() {
    printf '%b\n' "${BLUE}============================================================${NC}"
}

ui_title() {
    local text="$1"
    ui_line
    printf '%b\n' "${GREEN}  ${text}${NC}"
    ui_line
}

ui_section() {
    local text="$1"
    printf '%b\n' "${BLUE}[ ${text} ]${NC}"
}

ui_option() {
    local key="$1"
    local text="$2"
    printf "  ${YELLOW}%2s)${NC} %s\n" "$key" "$text"
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

    # Получаем список слушающих сокетов.
    mapfile -t listeners < <(sudo ss -tuln | awk 'NR>1 {print $1, $5}')

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

            # Пропускаем шумные системные порты и loopback.
            case "$port" in
                53|68|123|5353) continue ;;
            esac
            if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "localhost" ]]; then
                continue
            fi
            # Скрываем динамические порты (ephemeral), кроме основных портов из конфига.
            if [[ "$port" -ge 32768 && "$port" -le 65535 ]]; then
                if [[ "$port" != "$D_NODE_PORT" && "$port" != "$D_VLESS_PORT" && "$port" != "$D_SSH_PORT" && "$port" != "$D_BESZEL_PORT" ]]; then
                    continue
                fi
            fi

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

check_for_updates() {
    local is_manual=$1
    # Проверяем обновления только один раз за запуск скрипта, если это не ручной вызов
    if [ "$is_manual" != "manual" ] && [ "${CHECKED_UPDATE:-0}" -eq 1 ]; then
        return
    fi
    CHECKED_UPDATE=1

    echo -e "${YELLOW}Проверка обновлений...${NC}"
    local remote_version
    # Загружаем скрипт из GitHub и вытаскиваем версию
    remote_version=$(curl -s -H "Accept: application/vnd.github.v3.raw" -L "https://api.github.com/repos/RaconFloup/Skadik-scripts/contents/Install_node.sh" | grep -m 1 '^SCRIPT_VERSION=' | cut -d'"' -f2)

    if [[ -n "$remote_version" && "$remote_version" != "$SCRIPT_VERSION" ]]; then
        # Сравниваем версии как числа с плавающей точкой
        local is_newer=$(awk -v v1="$remote_version" -v v2="$SCRIPT_VERSION" 'BEGIN { if (v1 > v2) print 1; else print 0 }')
        if [ "$is_newer" -eq 1 ]; then
            echo -e "${GREEN}Доступна новая версия скрипта: v${remote_version} (текущая: v${SCRIPT_VERSION})${NC}"
            read -p "Хотите обновить скрипт сейчас? [Y/n]: " DO_UPDATE
            if [[ -z "$DO_UPDATE" || "$DO_UPDATE" =~ ^[Yy]$ ]]; then
                update_script
            fi
        elif [ "$is_manual" == "manual" ]; then
            echo -e "${GREEN}У вас установлена самая свежая версия (v${SCRIPT_VERSION}).${NC}"
        fi
    elif [ "$is_manual" == "manual" ]; then
        echo -e "${GREEN}У вас установлена самая свежая версия (v${SCRIPT_VERSION}).${NC}"
    fi
}

update_script() {
    echo -e "${YELLOW}Запрос обновления с GitHub...${NC}"
    sudo mkdir -p "$SCRIPT_INSTALL_DIR"
    sudo curl -f -H "Accept: application/vnd.github.v3.raw" \
         -L https://api.github.com/repos/RaconFloup/Skadik-scripts/contents/Install_node.sh \
         -o "$SCRIPT_INSTALL_PATH"
    
    if [ $? -eq 0 ]; then
        sudo chmod +x "$SCRIPT_INSTALL_PATH"
        ensure_global_command
        echo -e "${GREEN}Обновление успешно: $SCRIPT_INSTALL_PATH${NC}"
        echo -e "${GREEN}Команда доступна глобально: $SCRIPT_COMMAND_PATH${NC}"
        echo -e "${GREEN}Перезапуск...${NC}"
        sleep 1
        exec bash "$SCRIPT_INSTALL_PATH"
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

require_value() {
    local label="$1"
    local value="$2"
    if [ -z "$value" ]; then
        echo -e "${RED}Ошибка: параметр '${label}' не задан.${NC}"
        return 1
    fi
    return 0
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Установка Docker...${NC}"
        sudo curl -fsSL https://get.docker.com | sh
    else
        echo -e "${GREEN}Docker уже установлен.${NC}"
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
    else
        echo -e "${GREEN}Параметры сетевой оптимизации уже применены.${NC}"
    fi
    echo -e "${GREEN}Оптимизация завершена.${NC}"
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}UFW не найден. Устанавливаем...${NC}"
        sudo apt-get update -y && sudo apt-get install -y ufw
    else
        echo -e "${GREEN}UFW уже установлен.${NC}"
    fi

    echo -e "${YELLOW}Настройка правил доступа...${NC}"
    prompt_value PANEL_IP "IP-адрес вашей панели" "$D_PANEL_IP"
    prompt_value NODE_PORT "Порт ноды (Management)" "$D_NODE_PORT"
    prompt_value VLESS_PORT "Порт для клиентов (VLESS)" "$D_VLESS_PORT"
    prompt_value SSH_PORT "Порт SSH" "$D_SSH_PORT"
    prompt_value BESZEL_PORT "Порт Beszel Agent" "$D_BESZEL_PORT"
    require_value "PANEL_IP" "$PANEL_IP" || return
    require_value "NODE_PORT" "$NODE_PORT" || return
    require_value "VLESS_PORT" "$VLESS_PORT" || return
    require_value "SSH_PORT" "$SSH_PORT" || return
    require_value "BESZEL_PORT" "$BESZEL_PORT" || return
    sudo ufw --force reset
    sudo ufw allow from "$PANEL_IP" to any port "$NODE_PORT"
    sudo ufw deny "$NODE_PORT"
    sudo ufw allow "$VLESS_PORT"
    sudo ufw allow "$SSH_PORT"
    sudo ufw allow "$BESZEL_PORT"/tcp
    echo "y" | sudo ufw enable
}

install_beszel() {
    check_docker
    if docker ps -a --format '{{.Names}}' | grep -qx "beszel-agent"; then
        echo -e "${YELLOW}Beszel Agent уже установлен (контейнер beszel-agent найден).${NC}"
        read -p "Переустановить/обновить конфигурацию Beszel Agent? [y/N]: " REINSTALL_BESZEL
        if [[ ! "$REINSTALL_BESZEL" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Установка Beszel Agent пропущена.${NC}"
            return
        fi
    fi

    mkdir -p /opt/beszel-agent && cd /opt/beszel-agent

    echo -e "${YELLOW}Настройка Beszel Agent${NC}"
    prompt_value B_LISTEN     "Порт для прослушивания"          "$D_BESZEL_PORT"
    prompt_value B_SSH_KEY    "Публичный SSH-ключ (KEY)"        "$D_BESZEL_SSH_KEY"
    prompt_value B_TOKEN      "Универсальный токен (TOKEN)"     "$D_BESZEL_KEY"
    prompt_value B_HUB_URL    "URL хаба Beszel"                 "$D_BESZEL_HUB_URL"
    require_value "B_LISTEN" "$B_LISTEN" || return
    require_value "B_SSH_KEY" "$B_SSH_KEY" || return
    require_value "B_TOKEN" "$B_TOKEN" || return
    require_value "B_HUB_URL" "$B_HUB_URL" || return

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
    if docker ps -a --format '{{.Names}}' | grep -qx "remnanode"; then
        echo -e "${YELLOW}VPN Нода уже установлена (контейнер remnanode найден).${NC}"
        read -p "Переустановить/обновить конфигурацию ноды? [y/N]: " REINSTALL_NODE
        if [[ ! "$REINSTALL_NODE" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Установка ноды пропущена.${NC}"
            return
        fi
    fi

    mkdir -p /opt/remnanode && cd /opt/remnanode

    echo -e "${YELLOW}Настройка VPN Ноды (remnanode)${NC}"
    prompt_value N_PORT       "Порт ноды (Management)"          "${D_NODE_PORT:-2222}"
    prompt_value N_SECRET_KEY "Секретный ключ (SECRET_KEY)"     "$D_REMNANODE_SECRET_KEY"

    require_value "N_PORT" "$N_PORT" || return
    require_value "N_SECRET_KEY" "$N_SECRET_KEY" || return

    cat <<EOF > docker-compose.yml
services: 
  remnanode: 
    container_name: remnanode 
    hostname: remnanode 
    image: remnawave/node:latest 
    network_mode: host 
    restart: always 
    cap_add: 
      - NET_ADMIN 
    ulimits: 
      nofile: 
        soft: 1048576 
        hard: 1048576 
    environment: 
      - NODE_PORT=${N_PORT}
      - SECRET_KEY="${N_SECRET_KEY}"
EOF

    sudo docker compose down 2>/dev/null
    sudo docker compose up -d
    echo -e "${GREEN}VPN Нода (remnanode) установлена и запущена.${NC}"
}

# --- ОСНОВНОЕ МЕНЮ ---

show_menu() {
    local beszel_port_display="${D_BESZEL_PORT:-не задан}"
    ui_title "SKADIK HUB - ПАНЕЛЬ УПРАВЛЕНИЯ v${SCRIPT_VERSION}"

    ui_section "МОНИТОРИНГ"
    ui_option "1" "Проверить состояние и доступность портов"
    ui_option "2" "Запустить тест скорости (Multitest)"

    echo
    ui_section "УСТАНОВКА КОМПОНЕНТОВ"
    ui_option "3" "Экспресс-установка ноды"
    ui_option "4" "Установить только VPN ноду"
    ui_option "5" "Установить Beszel Agent (порт: $beszel_port_display)"

    echo
    ui_section "НАСТРОЙКА И ОПТИМИЗАЦИЯ"
    ui_option "6" "Оптимизация сети (BBR + CAKE + NoIPv6)"
    ui_option "7" "Перенастроить Firewall (UFW)"

    echo
    ui_section "ОБСЛУЖИВАНИЕ"
    ui_option "8" "Проверить обновления скрипта"
    ui_option "9" "Принудительно обновить скрипт"
    ui_option "0" "Выход"

    ui_line
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
        8) check_for_updates manual ;;
        9) update_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка: неверный выбор${NC}"; sleep 1 ;;
    esac
}

while true; do
    clear
    ensure_global_command
    load_local_config
    check_for_updates
    show_menu
    echo -e "\n${YELLOW}Нажмите Enter, чтобы вернуться в меню...${NC}"
    read -r
done
