#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        exit 1
    fi
}

# Валидация IPv4-адреса
validate_ip() {
    local ip="$1"
    local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "$ip" =~ $re ]]; then
        return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    # Автоматическое создание глобальной команды gokaskad
    local script_path
    script_path=$(realpath "$0")
    if [ "$script_path" != "/usr/local/bin/gokaskad" ]; then
        cp -f "$script_path" "/usr/local/bin/gokaskad"
        chmod +x "/usr/local/bin/gokaskad"
        echo -e "${GREEN}[OK] Команда gokaskad зарегистрирована.${NC}"
    fi

    # Включение IP Forwarding
    # Убираем все варианты строки (закомментированные и незакомментированные),
    # затем добавляем единственную корректную запись — избегаем дублей.
    sed -i '/^\s*#*\s*net\.ipv4\.ip_forward\s*=/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Активация Google BBR (аналогично — без дублей)
    sed -i '/^\s*#*\s*net\.core\.default_qdisc\s*=/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

    sed -i '/^\s*#*\s*net\.ipv4\.tcp_congestion_control\s*=/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p > /dev/null 2>&1

    # Установка зависимостей
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Установка зависимостей...${NC}"
        apt-get update -y > /dev/null 2>&1
        apt-get install -y iptables-persistent netfilter-persistent > /dev/null 2>&1
        echo -e "${GREEN}[OK] Зависимости установлены.${NC}"
    fi
}

# --- ИНСТРУКЦИЯ ---
show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║             📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного сервера (VPN/Прокси и т.д.):"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает целевой сервис)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка этого сервера${NC}"
    echo -e "1. Выберите нужный пункт (${GREEN}1-3${NC} для стандартных или ${GREEN}4${NC} для кастомных)."
    echo -e "2. Введите ${YELLOW}IP${NC} и ${YELLOW}Порты${NC} (входящий и исходящий)."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка Клиента (Важно!)${NC}"
    echo -e "1. Откройте приложение клиента."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. Если вы использовали разные порты (пункт 4), укажите входящий порт."
    echo ""
    echo -e "${GREEN}Готово! Трафик идёт: Клиент -> Этот Сервер -> Зарубеж.${NC}"
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# --- СТАНДАРТНАЯ НАСТРОЙКА (ПОРТ ВХОДА = ПОРТ ВЫХОДА) ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    local TARGET_IP
    while true; do
        echo -e "Введите IP адрес назначения:"
        read -p "> " TARGET_IP
        if validate_ip "$TARGET_IP"; then
            break
        fi
        echo -e "${RED}Ошибка: некорректный IPv4-адрес (пример: 45.10.20.30)!${NC}"
    done

    local PORT
    while true; do
        echo -e "Введите Порт (одинаковый для входа и выхода):"
        read -p "> " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
            break
        fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    apply_iptables_rules "$PROTO" "$PORT" "$PORT" "$TARGET_IP" "$NAME"
}

# --- КАСТОМНАЯ НАСТРОЙКА (РАЗНЫЕ ПОРТЫ) ---
configure_custom_rule() {
    echo -e "\n${CYAN}--- Универсальное кастомное правило ---${NC}"
    echo -e "${WHITE}Подходит для перенаправления ЛЮБЫХ протоколов (SSH, RDP, нестандартные порты)."
    echo -e "Позволяет принимать трафик на один порт и отправлять на другой.${NC}\n"

    local PROTO
    while true; do
        echo -e "Выберите протокол (${YELLOW}tcp${NC} или ${YELLOW}udp${NC}):"
        read -p "> " PROTO
        if [[ "$PROTO" == "tcp" || "$PROTO" == "udp" ]]; then break; fi
        echo -e "${RED}Ошибка: введите tcp или udp!${NC}"
    done

    local TARGET_IP
    while true; do
        echo -e "Введите IP адрес назначения (куда отправляем трафик):"
        read -p "> " TARGET_IP
        if validate_ip "$TARGET_IP"; then
            break
        fi
        echo -e "${RED}Ошибка: некорректный IPv4-адрес (пример: 45.10.20.30)!${NC}"
    done

    local IN_PORT
    while true; do
        echo -e "Введите ${YELLOW}ВХОДЯЩИЙ Порт${NC} (на этом сервере):"
        read -p "> " IN_PORT
        if [[ "$IN_PORT" =~ ^[0-9]+$ ]] && (( IN_PORT >= 1 && IN_PORT <= 65535 )); then
            break
        fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    local OUT_PORT
    while true; do
        echo -e "Введите ${YELLOW}ИСХОДЯЩИЙ Порт${NC} (на конечном сервере):"
        read -p "> " OUT_PORT
        if [[ "$OUT_PORT" =~ ^[0-9]+$ ]] && (( OUT_PORT >= 1 && OUT_PORT <= 65535 )); then
            break
        fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    apply_iptables_rules "$PROTO" "$IN_PORT" "$OUT_PORT" "$TARGET_IP" "Custom Rule"
}

# --- ПРИМЕНЕНИЕ ПРАВИЛ IPTABLES ---
apply_iptables_rules() {
    local PROTO=$1
    local IN_PORT=$2
    local OUT_PORT=$3
    local TARGET_IP=$4
    local NAME=$5

    local IFACE
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Не удалось определить сетевой интерфейс!${NC}"
        return 1
    fi

    echo -e "${YELLOW}[*] Применение правил (интерфейс: $IFACE)...${NC}"

    # Удаление старых правил с теми же параметрами (идемпотентность)
    iptables -t nat -D PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
    iptables -D INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    # Новые правила
    iptables -A INPUT -p "$PROTO" --dport "$IN_PORT" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$PROTO" --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"

    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    iptables -A FORWARD -p "$PROTO" -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -p "$PROTO" -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Настройка UFW если активен.
    # ВАЖНО: меняем только правило для конкретного порта, не трогаем глобальную
    # политику DEFAULT_FORWARD_POLICY — это снизило бы безопасность сервера.
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$IN_PORT"/"$PROTO" >/dev/null 2>&1
        # Разрешаем форвардинг только для нужного трафика через before.rules,
        # не меняя DEFAULT_FORWARD_POLICY глобально.
        local ufw_rule="# kaskad: forward $PROTO $IN_PORT -> $TARGET_IP:$OUT_PORT"
        local ufw_before="/etc/ufw/before.rules"
        if ! grep -qF "$ufw_rule" "$ufw_before" 2>/dev/null; then
            # Вставляем правило перед первой строкой *filter (в секцию *nat)
            if grep -q "^\*filter" "$ufw_before"; then
                sed -i "/^\*filter/i $ufw_rule\n-A ufw-before-forward -p $PROTO -d $TARGET_IP --dport $OUT_PORT -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT\n" "$ufw_before"
            fi
        fi
        ufw reload >/dev/null 2>&1
    fi

    netfilter-persistent save >/dev/null 2>&1

    echo -e "${GREEN}[SUCCESS] $NAME настроен!${NC}"
    echo -e "  Протокол : ${CYAN}$PROTO${NC}"
    echo -e "  Вход     : ${YELLOW}$IN_PORT${NC} (на этом сервере)"
    echo -e "  Выход    : ${YELLOW}$TARGET_IP:$OUT_PORT${NC} (зарубежный сервер)"
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    clear
    echo -e "\n${CYAN}--- Активные переадресации ---${NC}"
    echo -e "${MAGENTA}ПОРТ (ВХОД)  ПРОТОКОЛ  ЦЕЛЬ (IP:ПОРТ)${NC}"
    echo -e "-------------------------------------------"

    local found=0
    while read -r line; do
        local l_port l_proto l_dest
        l_port=$(echo  "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo  "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then
            printf "%-13s %-10s %s\n" "$l_port" "$l_proto" "$l_dest"
            found=1
        fi
    done < <(iptables -t nat -S PREROUTING | grep "DNAT")

    if [[ "$found" -eq 0 ]]; then
        echo -e "${YELLOW}Активных правил нет.${NC}"
    fi
    echo ""
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ОДНОГО ПРАВИЛА ---
delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    declare -a RULES_LIST
    local i=1

    while read -r line; do
        local l_port l_proto l_dest
        l_port=$(echo  "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo  "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then
            RULES_LIST[$i]="$l_port:$l_proto:$l_dest"
            echo -e "${YELLOW}[$i]${NC} Вход: $l_port ($l_proto) -> Выход: $l_dest"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING | grep "DNAT")

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    local rule_num
    read -p "Номер правила для удаления (0 — отмена): " rule_num

    if [[ "$rule_num" == "0" || -z "$rule_num" ]]; then return; fi

    if [[ -z "${RULES_LIST[$rule_num]+x}" ]]; then
        echo -e "${RED}Ошибка: неверный номер.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    IFS=':' read -r d_port d_proto d_dest <<< "${RULES_LIST[$rule_num]}"
    local target_ip="${d_dest%:*}"
    local target_port="${d_dest#*:}"

    iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_dest" 2>/dev/null
    iptables -D INPUT -p "$d_proto" --dport "$d_port" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -d "$target_ip" --dport "$target_port" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -s "$target_ip" --sport "$target_port" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    # Закрываем порт в UFW если активен
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "$d_port"/"$d_proto" >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
    fi

    netfilter-persistent save >/dev/null 2>&1
    echo -e "${GREEN}[OK] Правило удалено.${NC}"
    read -p "Нажмите Enter..."
}

# --- ПОЛНАЯ ОЧИСТКА ---
flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo -e "Сброс ВСЕХ правил iptables, включая правила других программ (Docker, fail2ban и т.д.)."
    local confirm
    read -p "Вы уверены? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        netfilter-persistent save >/dev/null 2>&1
        echo -e "${GREEN}[OK] Все правила очищены.${NC}"
    else
        echo -e "${YELLOW}Отменено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              KASKAD — каскадный NAT на iptables              ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "  2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "  3) Настроить ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e "  4) Создать ${YELLOW}Кастомное правило${NC} (разные порты, SSH, RDP...)"
        echo -e "  5) Посмотреть активные правила"
        echo -e "  6) ${RED}Удалить одно правило${NC}"
        echo -e "  7) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "  8) ${MAGENTA}Инструкция${NC}"
        echo -e "  0) Выход"
        echo -e "------------------------------------------------------"
        local choice
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) configure_rule "tcp" "MTProto/TProxy" ;;
            4) configure_custom_rule ;;
            5) list_active_rules ;;
            6) delete_single_rule ;;
            7) flush_rules ;;
            8) show_instructions ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root
prepare_system
show_menu
