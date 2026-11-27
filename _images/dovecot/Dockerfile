# Dovecot 2.4 з trixie. Синтаксис конфігів тут інший, ніж у 2.3 з
# bookworm — це свідомий вибір (рішення №2), конфіги переписуються під
# нову версію.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Драйвери БД ставимо ОБИДВА, хоч групі потрібен один: образ спільний на
# всі групи (рішення №4), а групи відрізняються СУБД — small на MySQL,
# office і isp на PostgreSQL. Тягнути два образи заради цього безглуздо.
#
# Діагностичних пакетів (iproute2, dnsutils, netcat) тут свідомо НЕМАЄ:
# `./mailctl netns <group> <команда>` виконує бінарник ХОСТА в мережевому
# namespace контейнера, тобто ip/ss/ping/dig доступні й без них. Класти
# інструменти в образ, який дивиться в інтернет, — зайвий матеріал для
# того, хто туди залізе.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        dovecot-core \
        dovecot-imapd \
        dovecot-pop3d \
        dovecot-lmtpd \
        dovecot-sieve \
        dovecot-managesieved \
        dovecot-mysql \
        dovecot-pgsql \
        ca-certificates \
        openssl \
        spamc \
        perl \
 && rm -rf /var/lib/apt/lists/*

# spamc — КЛІЄНТ SpamAssassin, і це не «антиспам у dovecot». Донавчання
# (рішення №34) працює так: користувач переклав лист у .Junk, imapsieve
# ловить IMAP-подію й через `spamc --learntype=spam` каже про це
# spamd'у в контейнері spamassassin. Отже тут потрібен рівно клієнт:
# маленька програма на C, без Perl-модулів, без правил і без доступу до
# бази стану SpamAssassin (рішення №33 — саме цей доступ ми й не
# віддаємо в dovecot).
#
# Пакет ОКРЕМИЙ, як і `spamd`: у Debian 12+ `spamassassin` містить лише
# Perl-модули, правила й sa-learn. На цьому вже спіймались (`spamd:
# command not found`, PITFALLS), тож тут перевіряти не «чи є пакет», а
# чи є бінарник — і це робить entrypoint.

# openssl — не для TLS як такого (сертифікати робить certbot), а для
# ЗАГЛУШКИ: поки certbot не зроблений, entrypoint генерує самопідписаний
# сертифікат, інакше Dovecot не стартує з auth_allow_cleartext = no.
# Формально його тягне ca-certificates, але покладатись на транзитивну
# залежність заради того, від чого залежить запуск, не варто.

# Статичний конфіг у образ НЕ кладемо: він приходить змонтованим із
# groups/<group>/dovecot-config/ (рішення №26 — конфіг належить групі, а
# образ спільний на всі групи).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
