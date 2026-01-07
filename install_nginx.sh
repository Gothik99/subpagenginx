#!/bin/bash

# Скрипт установки nginx для subpage
# Использование: sudo ./install_nginx.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then 
    error "Пожалуйста, запустите скрипт от root: sudo ./install_nginx.sh"
    exit 1
fi

# Определяем директорию установки subpage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Директория subpage: $SCRIPT_DIR"

# Определяем порт subpage (по умолчанию 3004)
# Можно переопределить через переменную окружения SUBPAGE_PORT
if [ -f "$SCRIPT_DIR/.env" ]; then
    SUBPAGE_PORT=$(grep -E "^PORT=" "$SCRIPT_DIR/.env" | cut -d '=' -f2 | tr -d '[:space:]' || echo "3004")
else
    SUBPAGE_PORT="3004"
fi
info "Порт subpage: $SUBPAGE_PORT"

# Проверка наличия nginx
if ! command -v nginx &> /dev/null; then
    info "Установка nginx..."
    apt-get update
    apt-get install -y nginx
    info "nginx установлен"
else
    info "nginx уже установлен: $(nginx -v 2>&1)"
fi

# Запрашиваем домен
echo ""
read -p "Введите ваш домен (например: sub.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    error "Домен не может быть пустым"
    exit 1
fi

# Запрашиваем email для Let's Encrypt
echo ""
read -p "Введите email для Let's Encrypt (обязательно): " EMAIL
if [ -z "$EMAIL" ]; then
    error "Email обязателен для получения SSL сертификата"
    exit 1
fi

# Создаем временную конфигурацию nginx для получения сертификата
NGINX_CONF="/etc/nginx/sites-available/subpage"
NGINX_ENABLED="/etc/nginx/sites-enabled/subpage"

info "Создание временной конфигурации nginx для получения SSL сертификата..."

cat > "$NGINX_CONF" << EOF
# Конфигурация nginx для subpage
# Домен: $DOMAIN

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Временная конфигурация для certbot
    location / {
        proxy_pass http://127.0.0.1:$SUBPAGE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Таймауты
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
    }
}
EOF

info "Конфигурация создана: $NGINX_CONF"

# Создаем симлинк в sites-enabled
if [ -L "$NGINX_ENABLED" ]; then
    warn "Симлинк уже существует, удаляю старый..."
    rm "$NGINX_ENABLED"
fi

ln -s "$NGINX_CONF" "$NGINX_ENABLED"
info "Симлинк создан: $NGINX_ENABLED"

# Проверяем конфигурацию nginx
info "Проверка конфигурации nginx..."
if nginx -t; then
    info "Конфигурация nginx корректна"
else
    error "Ошибка в конфигурации nginx!"
    exit 1
fi

# Перезапускаем nginx
info "Перезапуск nginx..."
systemctl restart nginx
systemctl enable nginx

info "nginx успешно настроен и запущен"

# Установка certbot для получения SSL сертификата
info "Установка certbot для получения SSL сертификата..."
if ! command -v certbot &> /dev/null; then
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
    info "certbot установлен"
else
    info "certbot уже установлен"
fi

# Получение SSL сертификата
info "Получение SSL сертификата для $DOMAIN..."
if certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --redirect; then
    info "SSL сертификат успешно получен и настроен!"
else
    warn "Не удалось автоматически получить SSL сертификат"
    warn "Возможные причины:"
    warn "  1. Домен не указывает на этот сервер"
    warn "  2. Порт 80 заблокирован файрволом"
    warn "  3. Домен уже имеет активный сертификат"
    echo ""
    info "Попробуйте получить сертификат вручную:"
    echo "  certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos"
    echo ""
    warn "Продолжаю с HTTP конфигурацией..."
fi

# Обновляем конфигурацию с полной HTTPS настройкой
info "Обновление конфигурации nginx с HTTPS..."

cat > "$NGINX_CONF" << EOF
# Конфигурация nginx для subpage
# Домен: $DOMAIN

# HTTP сервер (редирект на HTTPS)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS сервер
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Логирование
    access_log /var/log/nginx/subpage-access.log;
    error_log /var/log/nginx/subpage-error.log;

    # Проксирование на subpage
    location / {
        proxy_pass http://127.0.0.1:$SUBPAGE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_cache_bypass \$http_upgrade;
        
        # Таймауты
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # Буферизация
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

# Проверяем конфигурацию
info "Проверка обновленной конфигурации nginx..."
if nginx -t; then
    info "Конфигурация корректна"
    systemctl reload nginx
    info "nginx перезагружен с новой конфигурацией"
else
    error "Ошибка в конфигурации nginx!"
    warn "Проверьте файл: $NGINX_CONF"
    exit 1
fi

# Итоговая информация
echo ""
info "=========================================="
info "Установка завершена!"
info "=========================================="
echo ""
info "Домен: $DOMAIN"
info "Проксирование на: http://127.0.0.1:$SUBPAGE_PORT"
info "HTTPS: https://$DOMAIN"
echo ""
info "Полезные команды:"
echo "  Проверка конфигурации: nginx -t"
echo "  Перезагрузка: systemctl reload nginx"
echo "  Статус: systemctl status nginx"
echo "  Логи: tail -f /var/log/nginx/subpage-error.log"
echo "  Обновление SSL: certbot renew"
echo ""

