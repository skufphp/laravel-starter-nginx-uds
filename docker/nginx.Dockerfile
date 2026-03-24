# ==============================================================================
# Многоэтапный образ Nginx (Unix Socket) — Alpine (Laravel)
# ==============================================================================
# Назначение:
# - Development: только Nginx-конфиг, код монтируется volume'ом
# - Production: самодостаточный immutable-образ с public/ и build-ассетами
#
# Stages:
#   frontend-build  — сборка Vite-ассетов
#   nginx-base      — общая база Nginx
#   development     — dev-образ без копирования кода приложения
#   production      — prod-образ с public/ внутри контейнера
# ==============================================================================

FROM node:24-alpine AS frontend-build

WORKDIR /app

# Устанавливаем frontend-зависимости отдельным слоем для лучшего кеширования
COPY package*.json ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Копируем проект и собираем production-ассеты
COPY . ./
RUN npm run build


# ==============================================================================
# Базовый образ Nginx
# ==============================================================================
FROM nginx:1.29-alpine AS nginx-base

# Nginx должен иметь доступ к группе www-data, которой принадлежит PHP-FPM socket.
# На Alpine группа может уже существовать, поэтому добавление делаем безопасно.
RUN set -eux; \
    addgroup -g 82 -S www-data 2>/dev/null || true; \
    addgroup nginx www-data

WORKDIR /var/www/laravel

# Удаляем дефолтный конфиг и подставляем конфиг Laravel
RUN rm -f /etc/nginx/conf.d/default.conf
COPY docker/nginx/conf.d/laravel.conf /etc/nginx/conf.d/default.conf

# Подготавливаем директории, которые используются Nginx и приложением
RUN set -eux; \
    mkdir -p \
      /var/www/laravel/public \
      /var/cache/nginx \
      /var/run \
      /tmp/nginx


# ==============================================================================
# Development образ
# ==============================================================================
FROM nginx-base AS development

# В development код приложения приходит через bind mount:
#   .:/var/www/laravel
# Поэтому ничего из проекта в образ не копируем.
CMD ["nginx", "-g", "daemon off;"]


# ==============================================================================
# Production образ
# ==============================================================================
FROM nginx-base AS production

WORKDIR /var/www/laravel

# Копируем только публичную часть приложения.
# Nginx не нужен весь Laravel-проект — только public/.
COPY public ./public

# Удаляем маркер dev-сервера Vite, если он случайно попал в контекст
RUN rm -f /var/www/laravel/public/hot

# Подкладываем production-ассеты поверх public/
COPY --from=frontend-build /app/public/build /var/www/laravel/public/build

# Финальные безопасные права на чтение публичных файлов
RUN set -eux; \
    chown -R nginx:www-data /var/www/laravel/public; \
    find /var/www/laravel/public -type d -exec chmod 755 {} \;; \
    find /var/www/laravel/public -type f -exec chmod 644 {} \;

CMD ["nginx", "-g", "daemon off;"]
