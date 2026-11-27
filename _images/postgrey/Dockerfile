# Postgrey — greylisting. Беремо пакетний, з пакетними whitelist-ами:
# на джерелах вони застрягли на версії 2015 року (рішення в TODO, п.5b).
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ┌───────────────────────────────────────────────────────────────────┐
# │ ДВА PERL-МОДУЛІ ЯВНО. Бракувало рівно ОДНОГО з них.               │
# │                                                                   │
# │ Postgrey тримається на Net::Server::Multiplex, а той вимагає      │
# │ IO::Multiplex. У Debian це РЕКОМЕНДАЦІЯ, а не залежність, тож із  │
# │ --no-install-recommends (рішення №1) модуль не ставиться.         │
# │                                                                   │
# │ Симптом був підлий: `postgrey --help` друкував                    │
# │   Attempt to call undefined import method ... "IO::Multiplex"     │
# │ і все одно показував довідку — бо вона виводиться ДО старту       │
# │ сервера. Тобто «postgrey у образі є і навіть відповідає» нічого   │
# │ не доказувало. Той самий клас, що `spamd` окремим пакетом.        │
# │                                                                   │
# │ Entrypoint додатково перевіряє САМІ МОДУЛІ (`perl -M...`) до      │
# │ старту — щоб наступне таке зникнення було гучним.                 │
# │                                                                   │
# │ ЧОМУ ТУТ ЖЕ Й libnet-server-perl, хоч його НЕ бракувало.          │
# │                                                                   │
# │ Що він присутній, видно з самого повідомлення: помилка виникла    │
# │ ВСЕРЕДИНІ /usr/share/perl5/Net/Server/Multiplex.pm на рядку 26,   │
# │ а цей файл належить саме libnet-server-perl (apt-file). Тобто     │
# │ пакет стоїть — він жорстка залежність postgrey.                   │
# │                                                                   │
# │ Вписаний однаково, за тим самим правилом, що openssl в образі     │
# │ dovecot: покладатись на транзитивну залежність заради того, від   │
# │ чого ЗАЛЕЖИТЬ ЗАПУСК, не варто. Ціна нульова (apt і так його      │
# │ має), виграш — Dockerfile описує справжній ланцюг залежностей, а  │
# │ не лише його дірку.                                               │
# └───────────────────────────────────────────────────────────────────┘
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        postgrey \
        libnet-server-perl \
        libio-multiplex-perl \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
