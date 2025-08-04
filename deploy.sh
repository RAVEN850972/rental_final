#!/bin/bash

# Цвета для терминала
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ASCII арт заголовок
print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                           AVITO RENTAL BOT DEPLOYER                          ║"
    echo "║                              Automated Deployment                            ║"
    echo "╠═══════════════════════════════════════════════════════════════════════════════╣"
    echo "║                                                                               ║"
    echo "║  ██████╗  ██████╗ ████████╗    ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗ ║"
    echo "║  ██╔══██╗██╔═══██╗╚══██╔══╝    ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗║"
    echo "║  ██████╔╝██║   ██║   ██║       ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚██║"
    echo "║  ██╔══██╗██║   ██║   ██║       ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║ ██╔╝║"
    echo "║  ██████╔╝╚██████╔╝   ██║       ██████╔╝███████╗██║     ███████╗╚██████╔╝██╔╝ ║"
    echo "║  ╚═════╝  ╚═════╝    ╚═╝       ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝ ╚═╝  ║"
    echo "║                                                                               ║"
    echo "╠═══════════════════════════════════════════════════════════════════════════════╣"
    echo "║                                Author: ZerX                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# Функция для печати статуса
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Функция для создания разделителя
print_separator() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами root"
        echo -e "${YELLOW}Используйте: sudo $0${NC}"
        exit 1
    fi
}

# Установка зависимостей
install_dependencies() {
    print_separator
    print_status "Установка системных зависимостей"
    
    # Обновление пакетов
    print_status "Обновление списка пакетов..."
    apt update -qq
    
    # Установка Python и pip
    print_status "Установка Python 3.11+ и pip..."
    apt install -y python3 python3-pip python3-venv git curl
    
    # Проверка версии Python
    PYTHON_VERSION=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1,2)
    print_success "Python версия: $PYTHON_VERSION"
    
    print_success "Системные зависимости установлены"
}

# Создание пользователя для бота
create_bot_user() {
    print_separator
    print_status "Создание пользователя для бота"
    
    BOT_USER="avitobot"
    BOT_HOME="/opt/avito-rental-bot"
    
    # Создание пользователя если не существует
    if ! id "$BOT_USER" &>/dev/null; then
        useradd -r -s /bin/bash -d "$BOT_HOME" -m "$BOT_USER"
        print_success "Пользователь $BOT_USER создан"
    else
        print_warning "Пользователь $BOT_USER уже существует"
    fi
    
    # Создание домашней директории
    mkdir -p "$BOT_HOME"
    chown "$BOT_USER:$BOT_USER" "$BOT_HOME"
    
    print_success "Рабочая директория: $BOT_HOME"
}

# Копирование файлов проекта
deploy_project() {
    print_separator
    print_status "Развертывание проекта"
    
    BOT_HOME="/opt/avito-rental-bot"
    
    # Копирование файлов проекта
    print_status "Копирование файлов проекта..."
    
    # Список файлов проекта
    PROJECT_FILES=("main.py" "avito.py" "chat_gpt.py" "telegram.py" "config.py")
    
    for file in "${PROJECT_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BOT_HOME/"
            print_success "Скопирован файл: $file"
        else
            print_error "Файл не найден: $file"
        fi
    done
    
    # Создание requirements.txt
    cat > "$BOT_HOME/requirements.txt" << EOF
aiohttp==3.9.1
asyncio
python-telegram-bot==20.7
openai==1.3.7
requests==2.31.0
EOF
    
    print_success "Создан файл requirements.txt"
}

# Создание виртуального окружения и установка зависимостей
setup_venv() {
    print_separator
    print_status "Настройка виртуального окружения Python"
    
    BOT_HOME="/opt/avito-rental-bot"
    VENV_PATH="$BOT_HOME/venv"
    
    # Создание виртуального окружения
    print_status "Создание виртуального окружения..."
    sudo -u avitobot python3 -m venv "$VENV_PATH"
    
    # Установка зависимостей
    print_status "Установка Python зависимостей..."
    sudo -u avitobot "$VENV_PATH/bin/pip" install --upgrade pip
    sudo -u avitobot "$VENV_PATH/bin/pip" install -r "$BOT_HOME/requirements.txt"
    
    print_success "Виртуальное окружение настроено"
}

# Создание systemd сервиса
create_systemd_service() {
    print_separator
    print_status "Создание systemd сервиса"
    
    SERVICE_FILE="/etc/systemd/system/avito-rental-bot.service"
    BOT_HOME="/opt/avito-rental-bot"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Avito Rental Bot
After=network.target
Wants=network.target

[Service]
Type=simple
User=avitobot
Group=avitobot
WorkingDirectory=$BOT_HOME
Environment=PYTHONPATH=$BOT_HOME
ExecStart=$BOT_HOME/venv/bin/python main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=avito-rental-bot

# Политики перезапуска
StartLimitInterval=60
StartLimitBurst=3

# Безопасность
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$BOT_HOME

[Install]
WantedBy=multi-user.target
EOF
    
    print_success "Systemd сервис создан: $SERVICE_FILE"
    
    # Перезагрузка systemd
    systemctl daemon-reload
    print_success "Systemd конфигурация перезагружена"
}

# Настройка логирования
setup_logging() {
    print_separator
    print_status "Настройка системы логирования"
    
    # Создание директории для логов
    LOG_DIR="/var/log/avito-rental-bot"
    mkdir -p "$LOG_DIR"
    chown avitobot:avitobot "$LOG_DIR"
    
    # Настройка ротации логов
    cat > "/etc/logrotate.d/avito-rental-bot" << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    su avitobot avitobot
}
EOF
    
    print_success "Логирование настроено: $LOG_DIR"
}

# Создание скриптов управления
create_management_scripts() {
    print_separator
    print_status "Создание скриптов управления"
    
    BOT_HOME="/opt/avito-rental-bot"
    
    # Скрипт запуска
    cat > "$BOT_HOME/start.sh" << 'EOF'
#!/bin/bash
sudo systemctl start avito-rental-bot
sudo systemctl enable avito-rental-bot
echo "Бот запущен и добавлен в автозагрузку"
EOF
    
    # Скрипт остановки
    cat > "$BOT_HOME/stop.sh" << 'EOF'
#!/bin/bash
sudo systemctl stop avito-rental-bot
echo "Бот остановлен"
EOF
    
    # Скрипт перезапуска
    cat > "$BOT_HOME/restart.sh" << 'EOF'
#!/bin/bash
sudo systemctl restart avito-rental-bot
echo "Бот перезапущен"
EOF
    
    # Скрипт проверки статуса
    cat > "$BOT_HOME/status.sh" << 'EOF'
#!/bin/bash
echo "=== СТАТУС СЕРВИСА ==="
sudo systemctl status avito-rental-bot --no-pager
echo ""
echo "=== ПОСЛЕДНИЕ ЛОГИ ==="
sudo journalctl -u avito-rental-bot -n 20 --no-pager
EOF
    
    # Скрипт просмотра логов
    cat > "$BOT_HOME/logs.sh" << 'EOF'
#!/bin/bash
echo "Просмотр логов бота (Ctrl+C для выхода):"
sudo journalctl -u avito-rental-bot -f
EOF
    
    # Установка прав на выполнение
    chmod +x "$BOT_HOME"/*.sh
    chown avitobot:avitobot "$BOT_HOME"/*.sh
    
    print_success "Скрипты управления созданы"
}

# Финальная настройка и запуск
final_setup() {
    print_separator
    print_status "Финальная настройка и запуск"
    
    BOT_HOME="/opt/avito-rental-bot"
    
    # Установка прав доступа
    chown -R avitobot:avitobot "$BOT_HOME"
    chmod 755 "$BOT_HOME"
    
    print_warning "ВАЖНО: Не забудьте настроить файл config.py с вашими API ключами!"
    echo -e "${YELLOW}Файл конфигурации: $BOT_HOME/config.py${NC}"
    echo
    
    # Предложение запуска
    read -p "Запустить бота сейчас? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl enable avito-rental-bot
        systemctl start avito-rental-bot
        
        sleep 2
        
        if systemctl is-active --quiet avito-rental-bot; then
            print_success "Бот успешно запущен и добавлен в автозагрузку"
        else
            print_error "Ошибка запуска бота. Проверьте конфигурацию."
        fi
    else
        print_warning "Бот не запущен. Используйте команды управления для запуска."
    fi
}

# Вывод итоговой информации
print_final_info() {
    print_separator
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                              РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО                          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${WHITE}Команды управления ботом:${NC}"
    echo -e "${CYAN}  Запуск:         ${WHITE}sudo systemctl start avito-rental-bot${NC}"
    echo -e "${CYAN}  Остановка:      ${WHITE}sudo systemctl stop avito-rental-bot${NC}"
    echo -e "${CYAN}  Перезапуск:     ${WHITE}sudo systemctl restart avito-rental-bot${NC}"
    echo -e "${CYAN}  Статус:         ${WHITE}sudo systemctl status avito-rental-bot${NC}"
    echo -e "${CYAN}  Логи:           ${WHITE}sudo journalctl -u avito-rental-bot -f${NC}"
    echo -e "${CYAN}  Автозагрузка:   ${WHITE}sudo systemctl enable avito-rental-bot${NC}"
    echo
    echo -e "${WHITE}Или используйте готовые скрипты в /opt/avito-rental-bot/:${NC}"
    echo -e "${CYAN}  ./start.sh      ${WHITE}- Запуск бота${NC}"
    echo -e "${CYAN}  ./stop.sh       ${WHITE}- Остановка бота${NC}"
    echo -e "${CYAN}  ./restart.sh    ${WHITE}- Перезапуск бота${NC}"
    echo -e "${CYAN}  ./status.sh     ${WHITE}- Проверка статуса${NC}"
    echo -e "${CYAN}  ./logs.sh       ${WHITE}- Просмотр логов${NC}"
    echo
    echo -e "${YELLOW}Файлы проекта:    ${WHITE}/opt/avito-rental-bot/${NC}"
    echo -e "${YELLOW}Конфигурация:     ${WHITE}/opt/avito-rental-bot/config.py${NC}"
    echo -e "${YELLOW}Логи:             ${WHITE}/var/log/avito-rental-bot/${NC}"
    echo -e "${YELLOW}Системный сервис: ${WHITE}/etc/systemd/system/avito-rental-bot.service${NC}"
    echo
    print_separator
}

# Основная функция
main() {
    print_header
    
    print_status "Начало развертывания Avito Rental Bot"
    
    check_root
    install_dependencies
    create_bot_user
    deploy_project
    setup_venv
    create_systemd_service
    setup_logging
    create_management_scripts
    final_setup
    print_final_info
    
    echo -e "${GREEN}Развертывание завершено успешно!${NC}"
}

# Обработка сигналов
trap 'echo -e "\n${RED}Развертывание прервано пользователем${NC}"; exit 1' INT TERM

# Запуск основной функции
main "$@"
