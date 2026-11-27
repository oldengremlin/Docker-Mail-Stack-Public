# OpenDMARC — перевірка DMARC на вхідній пошті. На жодному з джерел не
# підключений; вмикаємо свідомо (рішення №10).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        opendmarc \
        publicsuffix \
        socat \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# publicsuffix — НЕ «на всяк випадок». DMARC у режимі relaxed вирівнює
# домени до ОРГАНІЗАЦІЙНОГО, і без цього списку OpenDMARC вважає таким
# другий рівень. Для .com.ua, .kiev.ua, .org.ua це хибно: публічний
# суфікс там сам двоскладовий. Без списку example.kiev.ua звівся б
# до kiev.ua, тобто будь-який домен у .kiev.ua вважався б вирівняним із
# нашим — DMARC перестав би робити те єдине, для чого існує, причому
# мовчки. Пакет дає файл з apt, тож оновлюється з образом.
#
# socat — щоб логи демона взагалі існували: OpenDMARC пише лише в
# syslog, якого в контейнері немає, і entrypoint зливає /dev/log у
# stderr.

# Статичний opendmarc.conf у образ НЕ кладемо — він приходить
# змонтованим із _configs/opendmarc/ (або з перекриття групи).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
