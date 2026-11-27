# Postfix. Власник мережевого namespace групи: разом із ним у цьому ж
# netns живе Dovecot (рішення №5).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# postfix-mysql і postfix-pgsql — ОБИДВА: образ спільний на всі групи
# (рішення №4), а групи відрізняються СУБД. postfix-pcre потрібен під
# regexp-мапи, які на джерелах використовуються (sender_checks_regexp,
# helo_checks_regexp) — навіть якщо більшість політик переїде в SQL
# (рішення №18), pcre лишається для того, що правилом описується
# природніше за таблицю.
#
# Діагностичних пакетів немає навмисно — `./mailctl netns` дає
# інструменти хоста в namespace контейнера.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        postfix \
        postfix-mysql \
        postfix-pgsql \
        postfix-pcre \
        ca-certificates \
        openssl \
 && rm -rf /var/lib/apt/lists/*

# Статичний main.cf у образ НЕ кладемо: він приходить змонтованим із
# groups/<group>/postfix-config/. master.cf лишається пакетний —
# entrypoint правит його штатним `postconf -M/-P/-F`, а не переписує
# руками: відтворювати двадцять службових рядків по пам'яті — це той
# самий клас помилки, що й inet_listener address (див. PITFALLS).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
