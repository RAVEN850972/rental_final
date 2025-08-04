#!/bin/bash

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │                           AVITO RENTAL BOT SETUP                           │
# │                         Автоматическая установка                            │
# │                                                                             │
# │ Автор: ZerX                                                                 │
# │ Версия: 1.0                                                                 │
# │ Дата: 2025                                                                  │
# └─────────────────────────────────────────────────────────────────────────────┘

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для печати с рамкой
print_box() {
    local text="$1"
    local length=${#text}
    local line=$(printf "%-${length}s" | tr ' ' '─')
    
    echo "┌─${line}─┐"
    echo "│ ${text} │"
    echo "└─${line}─┘"
}

# Функция для печати статуса
print_status() {
    local status="$1"
    local message="$2"
    if [ "$status" = "OK" ]; then
        echo -e "[${GREEN}✓${NC}] $message"
    elif [ "$status" = "ERROR" ]; then
        echo -e "[${RED}✗${NC}] $message"
    elif [ "$status" = "INFO" ]; then
        echo -e "[${BLUE}i${NC}] $message"
    elif [ "$status" = "WARN" ]; then
        echo -e "[${YELLOW}!${NC}] $message"
    fi
}

# Приветствие
clear
echo
print_box "AVITO RENTAL BOT - УСТАНОВКА SYSTEMD СЕРВИСА"
echo
echo "Автор: ZerX"
echo "Данный скрипт настроит автозапуск бота через systemd"
echo

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    print_status "ERROR" "Запустите скрипт с правами root (sudo)"
    exit 1
fi

print_status "OK" "Права root подтверждены"

# Определение пользователя, который запустил sudo
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    USER_HOME="/home/$REAL_USER"
else
    REAL_USER="root"
    USER_HOME="/root"
fi

print_status "INFO" "Пользователь: $REAL_USER"

# Поиск директории проекта
BOT_DIR=""
POSSIBLE_DIRS=(
    "$USER_HOME/avito-bot"
    "$USER_HOME/avito-rental-bot"
    "$USER_HOME/bot"
    "/opt/avito-bot"
    "$(pwd)"
)

for dir in "${POSSIBLE_DIRS[@]}"; do
    if [ -f "$dir/main.py" ] && [ -f "$dir/config.py" ]; then
        BOT_DIR="$dir"
        break
    fi
done

if [ -z "$BOT_DIR" ]; then
    echo
    print_status "WARN" "Автоматический поиск не дал результатов"
    echo "Введите полный путь к директории с ботом:"
    read -p "Путь: " BOT_DIR
    
    if [ ! -f "$BOT_DIR/main.py" ] || [ ! -f "$BOT_DIR/config.py" ]; then
        print_status "ERROR" "Файлы main.py или config.py не найдены в $BOT_DIR"
        exit 1
    fi
fi

# Проверяем абсолютный путь
if [[ ! "$BOT_DIR" = /* ]]; then
    BOT_DIR="$(realpath "$BOT_DIR")"
fi

# Проверяем что директория существует
if [ ! -d "$BOT_DIR" ]; then
    print_status "ERROR" "Директория $BOT_DIR не существует"
    exit 1
fi

print_status "OK" "Директория бота найдена: $BOT_DIR"

# Проверка Python
PYTHON_CMD=""
for cmd in python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$cmd" &> /dev/null; then
        PYTHON_CMD="$(which "$cmd")"
        break
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    print_status "ERROR" "Python3 не найден в системе"
    exit 1
fi

PYTHON_VERSION=$($PYTHON_CMD --version 2>&1 | cut -d' ' -f2)
print_status "OK" "Python найден: $PYTHON_CMD (версия $PYTHON_VERSION)"

echo
print_status "INFO" "Проверяем конфигурацию перед созданием сервиса..."
echo "Директория бота: $BOT_DIR"
echo "Python путь: $PYTHON_CMD"
echo "Файл main.py: $(ls -la "$BOT_DIR/main.py" 2>/dev/null || echo 'НЕ НАЙДЕН')"
echo "Файл config.py: $(ls -la "$BOT_DIR/config.py" 2>/dev/null || echo 'НЕ НАЙДЕН')"
echo
read -p "Продолжить создание сервиса? (y/N): " continue_setup
if [[ ! $continue_setup =~ ^[Yy]$ ]]; then
    print_status "INFO" "Установка прервана пользователем"
    exit 0
fi

# Проверка зависимостей
print_status "INFO" "Проверка зависимостей..."

if [ -f "$BOT_DIR/requirements.txt" ]; then
    print_status "INFO" "Установка зависимостей из requirements.txt..."
    cd "$BOT_DIR"
    $PYTHON_CMD -m pip install -r requirements.txt
else
    print_status "INFO" "Установка базовых зависимостей..."
    $PYTHON_CMD -m pip install aiohttp asyncio
fi

# Создание systemd сервиса
SERVICE_NAME="rental-production"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

print_status "INFO" "Создание systemd сервиса..."

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Rental Production Bot
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=10
User=$REAL_USER
WorkingDirectory=$BOT_DIR
ExecStart=$PYTHON_CMD $BOT_DIR/main.py
Environment=PYTHONPATH=$BOT_DIR
Environment=PYTHONUNBUFFERED=1

# Логирование
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rental-production

# Безопасность
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$BOT_DIR

[Install]
WantedBy=multi-user.target
EOF

print_status "OK" "Сервис создан: $SERVICE_FILE"

# Настройка прав доступа
chown "$REAL_USER:$REAL_USER" "$BOT_DIR" -R
chmod 755 "$BOT_DIR"
chmod 644 "$SERVICE_FILE"

print_status "OK" "Права доступа настроены"

# Перезагрузка systemd
systemctl daemon-reload
print_status "OK" "Systemd daemon перезагружен"

# Включение автозапуска
systemctl enable "$SERVICE_NAME"
print_status "OK" "Автозапуск включен"

echo
print_box "УСТАНОВКА ЗАВЕРШЕНА"
echo

# Таблица с командами управления
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│                           КОМАНДЫ УПРАВЛЕНИЯ                           │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│ Запуск бота:        sudo systemctl start $SERVICE_NAME"
echo "│ Остановка бота:     sudo systemctl stop $SERVICE_NAME"
echo "│ Перезапуск бота:    sudo systemctl restart $SERVICE_NAME"
echo "│ Статус бота:        sudo systemctl status $SERVICE_NAME"
echo "│ Логи бота:          sudo journalctl -u $SERVICE_NAME -f"
echo "│ Логи за сегодня:    sudo journalctl -u $SERVICE_NAME --since today"
echo "│ Отключить автозапуск: sudo systemctl disable $SERVICE_NAME"
echo "└─────────────────────────────────────────────────────────────────────────┘"

echo
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│                            ИНФОРМАЦИЯ                                   │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│ Сервис:          $SERVICE_NAME"
echo "│ Файл сервиса:    $SERVICE_FILE"
echo "│ Директория:      $BOT_DIR"
echo "│ Пользователь:    $REAL_USER"
echo "│ Python:          $PYTHON_CMD"
echo "│ Автозапуск:      Включен"
echo "└─────────────────────────────────────────────────────────────────────────┘"

echo
read -p "Запустить бота сейчас? (y/N): " start_now
if [[ $start_now =~ ^[Yy]$ ]]; then
    print_status "INFO" "Запуск бота..."
    systemctl start "$SERVICE_NAME"
    sleep 3
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_status "OK" "Бот успешно запущен"
        echo
        print_status "INFO" "Просмотр логов в реальном времени:"
        echo "sudo journalctl -u $SERVICE_NAME -f"
        echo
        print_status "INFO" "Для выхода из логов нажмите Ctrl+C"
    else
        print_status "ERROR" "Ошибка запуска бота"
        echo "Проверьте логи: sudo journalctl -u $SERVICE_NAME -n 50"
    fi
else
    print_status "INFO" "Для запуска используйте: sudo systemctl start $SERVICE_NAME"
fi

echo
print_box "ГОТОВО! БОТ НАСТРОЕН ДЛЯ РАБОТЫ 24/7"
echo
echo "Автор: ZerX"
