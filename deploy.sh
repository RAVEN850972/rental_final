#!/bin/bash

# Скрипт развертывания Avito Rental Bot
# Автор: ZerX

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Развертывание Avito Rental Bot ===${NC}"

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: Запустите скрипт с правами sudo${NC}"
    exit 1
fi

# Получение имени пользователя (не root)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    echo -e "${YELLOW}Введите имя пользователя для запуска бота:${NC}"
    read -r REAL_USER
fi

# Определение домашней директории пользователя
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
PROJECT_DIR="$USER_HOME/avito-rental-bot"

echo -e "${YELLOW}Пользователь: $REAL_USER${NC}"
echo -e "${YELLOW}Директория проекта: $PROJECT_DIR${NC}"

# Создание директории проекта
echo -e "${GREEN}Создание директории проекта...${NC}"
mkdir -p "$PROJECT_DIR"
chown "$REAL_USER:$REAL_USER" "$PROJECT_DIR"

# Установка Python и pip если не установлены
echo -e "${GREEN}Проверка установки Python...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Установка Python3...${NC}"
    apt update
    apt install -y python3 python3-pip python3-venv
fi

# Создание виртуального окружения
echo -e "${GREEN}Создание виртуального окружения...${NC}"
cd "$PROJECT_DIR"
sudo -u "$REAL_USER" python3 -m venv venv
sudo -u "$REAL_USER" ./venv/bin/pip install --upgrade pip

# Установка зависимостей
echo -e "${GREEN}Установка зависимостей...${NC}"
sudo -u "$REAL_USER" ./venv/bin/pip install aiohttp openai

# Создание systemd service файла
echo -e "${GREEN}Создание systemd service...${NC}"
cat > /etc/systemd/system/avito-rental-bot.service << EOL
[Unit]
Description=Avito Rental Bot
After=network.target
Wants=network.target

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$PROJECT_DIR
Environment=PATH=$PROJECT_DIR/venv/bin
ExecStart=$PROJECT_DIR/venv/bin/python main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=avito-rental-bot

# Ограничения ресурсов
MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOL

# Создание скрипта управления
echo -e "${GREEN}Создание скрипта управления...${NC}"
cat > "$PROJECT_DIR/bot_control.sh" << 'EOL'
#!/bin/bash

# Скрипт управления Avito Rental Bot

case "$1" in
    start)
        echo "Запуск бота..."
        sudo systemctl start avito-rental-bot
        sudo systemctl status avito-rental-bot --no-pager
        ;;
    stop)
        echo "Остановка бота..."
        sudo systemctl stop avito-rental-bot
        ;;
    restart)
        echo "Перезапуск бота..."
        sudo systemctl restart avito-rental-bot
        sudo systemctl status avito-rental-bot --no-pager
        ;;
    status)
        sudo systemctl status avito-rental-bot --no-pager
        ;;
    logs)
        echo "Просмотр логов (нажмите Ctrl+C для выхода)..."
        sudo journalctl -u avito-rental-bot -f
        ;;
    enable)
        echo "Включение автозапуска..."
        sudo systemctl enable avito-rental-bot
        ;;
    disable)
        echo "Отключение автозапуска..."
        sudo systemctl disable avito-rental-bot
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|logs|enable|disable}"
        echo ""
        echo "  start    - Запустить бота"
        echo "  stop     - Остановить бота"
        echo "  restart  - Перезапустить бота"
        echo "  status   - Показать статус"
        echo "  logs     - Показать логи в реальном времени"
        echo "  enable   - Включить автозапуск при загрузке системы"
        echo "  disable  - Отключить автозапуск"
        exit 1
        ;;
esac
EOL

chmod +x "$PROJECT_DIR/bot_control.sh"
chown "$REAL_USER:$REAL_USER" "$PROJECT_DIR/bot_control.sh"

# Создание директории для логов
mkdir -p /var/log/avito-rental-bot
chown "$REAL_USER:$REAL_USER" /var/log/avito-rental-bot

# Перезагрузка systemd
systemctl daemon-reload

echo -e "${GREEN}=== Развертывание завершено! ===${NC}"
echo ""
echo -e "${YELLOW}Следующие шаги:${NC}"
echo "1. Скопируйте файлы проекта в директорию: $PROJECT_DIR"
echo "2. Отредактируйте файл config.py с вашими API ключами"
echo "3. Используйте команды управления:"
echo "   cd $PROJECT_DIR"
echo "   ./bot_control.sh start     - запустить бота"
echo "   ./bot_control.sh status    - проверить статус"
echo "   ./bot_control.sh logs      - просмотр логов"
echo "   ./bot_control.sh enable    - автозапуск при загрузке"
echo ""
echo -e "${GREEN}Бот готов к работе!${NC}"