# ClamAV: `clamd` (сканер), `freshclam` (оновлення бази) і
# `clamav-milter` (підключення до Postfix) — рішення №32.
#
# Три процеси в одному контейнері, і це свідомо. Розвести їх не вийде
# без гіршого: freshclam мусить ПИСАТИ в той самий том, який clamd
# читає, тобто спільний том на запис із двох контейнерів; а milter без
# clamd не має сенсу взагалі. Тому замість цього — нагляд в entrypoint:
# помер будь-який процес, контейнер виходить, і Docker його підіймає.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Бази вірусів у образ НЕ кладемо: вони оновлюються щодня й важать
# близько гігабайта. Їх забирає freshclam у том групи при першому
# старті — звідси й попередження в entrypoint про те, що перший старт
# довгий і до кінця завантаження бази сканування не працює.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        clamav-daemon \
        clamav-freshclam \
        clamav-milter \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Статичних конфігів у образ НЕ кладемо — вони приходять змонтованими
# з _configs/clamav/ (або з перекриття групи).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
