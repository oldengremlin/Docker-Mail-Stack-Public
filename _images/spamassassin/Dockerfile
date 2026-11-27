# SpamAssassin: демон `spamd` плюс адаптер до Postfix `spamass-milter`.
#
# Стан (bayes, AWL, userpref) — у SQL, як на обох джерелах, де він є;
# звідси драйвери DBD на обидві СУБД (рішення №33).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ┌───────────────────────────────────────────────────────────────────┐
# │ `spamd` — ОКРЕМИЙ ПАКЕТ, і це не завжди було так.                 │
# │                                                                   │
# │ Debian виніс демон із пакета `spamassassin` у власний пакет       │
# │ `spamd` (починаючи з Debian 12). У `spamassassin` лишились        │
# │ Perl-модулі, правила й `sa-learn` — тобто все, крім того, що      │
# │ власне слухає порт.                                               │
# │                                                                   │
# │ Симптом, якщо забути: `spamd: command not found`, код виходу 127, │
# │ контейнер у restart-loop. Конфіг при цьому валідний і             │
# │ `spamassassin --lint` проходить чисто — бо lint про демон нічого  │
# │ не знає.                                                          │
# └───────────────────────────────────────────────────────────────────┘
#
# spamass-milter — підключення до Postfix мілтером, а не пайпом через
# content_filter (рішення №31). Він сам викликає spamc, тож spamc
# потрібен тут, а НЕ в образі Postfix — саме це й було причиною
# відмовитись від пайпа: інакше межа між контейнерами розмивається.
#
# libdbd-mysql-perl / libdbd-pg-perl — під user_scores_dsn і bayes у SQL
# (рішення №18 про userpref, №33 про окрему базу).
#
# socat — щоб логи мілтера взагалі існували: spamass-milter пише лише в
# syslog, якого в контейнері немає, і entrypoint зливає /dev/log у
# stderr. Та сама конструкція, що в opendkim/opendmarc.
#
# mysql-клієнт тут НЕ потрібен: схему bayes/awl/userpref застосовує
# MySQL-контейнер із mysql-init, а `mailctl db-schema` лише ЧИТАЄ
# пакетні SQL-файли з цього образу (/usr/share/doc/spamassassin/sql/).
#
# razor/pyzor свідомо НЕ ставимо поки: на джерелах вони не налаштовані, а
# кожен із них — це ще один вихідний канал у мережу з адреси, яка через
# masquerade виглядає як адреса хоста, а не групи.
# ┌───────────────────────────────────────────────────────────────────┐
# │ БЕЗ ЦЬОГО РЯДКА SQL-СХЕМИ НЕ ВСТАНОВЛЮЮТЬСЯ, і `dpkg -L` про це   │
# │ НЕ СКАЖЕ — він показує шляхи з бази пакета, а не з диска.         │
# │                                                                   │
# │ Офіційні debian:*-slim мають /etc/dpkg/dpkg.cfg.d/docker із       │
# │ `path-exclude=/usr/share/doc/*`: документація викидається при      │
# │ встановленні, щоб образ був меншим. А схеми bayes/awl/userpref     │
# │ лежать саме там — /usr/share/doc/spamassassin/sql/.               │
# │                                                                   │
# │ Симптом був рівно такий: find по /usr не знаходить ні одного      │
# │ *.sql, а `dpkg -L spamassassin | grep sql` перелічує всі файли.   │
# │                                                                   │
# │ Ім'я файлу мусить сортуватись ПІСЛЯ `docker`: dpkg застосовує     │
# │ правила в порядку читання, і path-include перекриває лише той     │
# │ path-exclude, який прочитаний раніше. Звідси `zz-`.               │
# └───────────────────────────────────────────────────────────────────┘
RUN printf 'path-include=/usr/share/doc/spamassassin/sql/*\n' \
        > /etc/dpkg/dpkg.cfg.d/zz-keep-spamassassin-sql

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        spamassassin \
        spamd \
        spamass-milter \
        spamc \
        socat \
        libdbi-perl \
        libdbd-mysql-perl \
        libdbd-pg-perl \
        libmail-dkim-perl \
        libnet-dns-perl \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Статичний local.cf у образ НЕ кладемо — він приходить змонтованим із
# _configs/spamassassin/ (або з перекриття групи).
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
