# OpenDKIM — підпис вихідної пошти. Перший мілтер у ланцюзі, перед
# OpenDMARC (рішення №10).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# opendkim-tools потрібен для opendkim-genkey: ключі генеруються самі
# (мета проєкту — ручних операцій рівно три, генерація ключів до них не
# належить). KeyTable/SigningTable теж генеруються з БД, тому
# SQL-бекенди самого OpenDKIM (libopendbx) не потрібні — натомість
# потрібен клієнт БД, бо список доменів entrypoint читає сам.
#
# default-mysql-client, а не mariadb-client: пакет-метаперехідник
# лишається правильним і коли Debian змінить реалізацію за ним.
#
# socat — щоб логи демона взагалі існували. OpenDKIM пише лише в syslog,
# якого в контейнері немає; entrypoint зливає /dev/log у stderr.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        opendkim \
        opendkim-tools \
        default-mysql-client \
        socat \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Статичний opendkim.conf у образ НЕ кладемо — він приходить
# змонтованим із groups/<group>/opendkim-config/.
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
