#!/bin/sh
# ─────────────────────────────────────────────────────────────────────
#  Entrypoint образу opendmarc.
#
#  Другий мілтер у ланцюзі, після OpenDKIM (рішення №10). Сам DKIM не
#  перевіряє — читає заголовок Authentication-Results, який ставить
#  OpenDKIM, тому TrustedAuthservIDs мусить ЗБІГАТИСЯ з AuthservID
#  OpenDKIM. Це найтиповіша тиха помилка в цій зв'язці: не збіглось —
#  OpenDMARC проігнорував наш же заголовок і оцінює лише по SPF.
# ─────────────────────────────────────────────────────────────────────
set -eu

SHARED=/etc/opendmarc/shared
CUSTOM=/etc/opendmarc/config
CONF=/etc/opendmarc.conf
PSL=/usr/share/publicsuffix/public_suffix_list.dat

die() { echo "opendmarc-entrypoint: $*" >&2; exit 1; }
say() { echo "opendmarc-entrypoint: $*" >&2; }

# ── Логи мілтера ──────────────────────────────────────────────────────
# OpenDMARC умієте писати лише в syslog. У контейнері його немає, тож
# socat слухає datagram-сокет /dev/log і копіює все в stderr, звідки це
# бере `docker logs`. Без цього діагностики DMARC не існувало б — як її
# не існувало в OpenDKIM, поки не помітили.
syslog_to_stderr() {
    rm -f /dev/log

    # ПЕРЕНОС РЯДКА ТУТ — НЕ ДРІБНИЦЯ, А ВЕСЬ СЕНС КОНСТРУКЦІЇ.
    #
    # Спершу тут стояло просте `socat -u UNIX-RECV:/dev/log STDERR`, і
    # воно виглядало робочим: сокет створювався, демон писав, socat
    # пересилав — а в `docker logs` було порожньо. Причина: syslog-
    # датаграми НЕ містять переносу рядка, а журнальний драйвер Docker
    # ріже потік саме по `\n` і тримає незакінчений рядок у буфері.
    # Усі логи злипались в один невидимий рядок і вивалились разом,
    # щойно хтось надіслав повідомлення з `\n`.
    #
    # Тому `fork`: socat форкається на КОЖНУ датаграму, і перенос додає
    # дочірній процес (`echo >&2`). Інакше додати його нема кому —
    # socat такої опції не має, а потоковий фільтр не може розрізати
    # потік, у якому немає розділювача.
    #
    # Ціна: fork+exec на кожен рядок логу. Для мілтера це одиниці рядків
    # на лист, тобто копійки. Якби колись стало дорого — варіант
    # `busybox syslogd -n -O /dev/stderr`, він пише вже з переносами;
    # перевірити, чи аплет `syslogd` є в пакеті busybox для trixie.
    socat -u UNIX-RECVFROM:/dev/log,mode=0666,fork \
          SYSTEM:'cat >&2; echo >&2' &

    # Дати сокету з'явитись, інакше перші рядки демона втратяться.
    i=0
    while [ ! -S /dev/log ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
    [ -S /dev/log ] || say "УВАГА — не вдалось підняти злив /dev/log у stderr,
логів мілтера не буде"
}

if [ -f "$CUSTOM/opendmarc.conf" ]; then
    CONF_SRC=$CUSTOM/opendmarc.conf
    say "конфіг ГРУПИ $CONF_SRC (перекриває спільний)"
elif [ -f "$SHARED/opendmarc.conf" ]; then
    CONF_SRC=$SHARED/opendmarc.conf
else
    die "немає ні $CUSTOM/opendmarc.conf, ні $SHARED/opendmarc.conf"
fi

missing=
for v in MAIL_HOSTNAME INTERNAL_PREFIX; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
done
[ -z "$missing" ] || die "не задані змінні:$missing"
: "${MYNETWORKS:=}"

# ── Public Suffix List ────────────────────────────────────────────────
# Падаємо, якщо файлу немає. Без нього OpenDMARC вважає організаційним
# доменом другий рівень, і для .com.ua/.kiev.ua/.org.ua вирівнювання
# relaxed стає беззмістовним: example.kiev.ua звівся б до kiev.ua,
# тобто будь-який домен у .kiev.ua вважався б своїм. Помітити це в
# роботі неможливо — DMARC просто почав би пропускати підробки.
[ -s "$PSL" ] || die "немає $PSL. Його дає пакет publicsuffix; без нього
вирівнювання DMARC для доменів третього рівня (.com.ua, .kiev.ua) хибне,
і це НЕ видно в роботі"

# ── Кого не оцінювати ─────────────────────────────────────────────────
# Та сама логіка, що в InternalHosts у OpenDKIM: своя internal-мережа
# (звідти шле Roundcube) плюс довірені мережі групи. Автентиковані
# клієнти відпадають окремо — IgnoreAuthenticatedClients у конфізі.
mkdir -p /etc/opendmarc
{
    echo 127.0.0.1
    echo ::1
    echo "$INTERNAL_PREFIX.0/24"
    for n in $MYNETWORKS; do echo "$n"; done
} > /etc/opendmarc/ignore.hosts
chown opendmarc:opendmarc /etc/opendmarc/ignore.hosts

# ── Конфіг ────────────────────────────────────────────────────────────
cp "$CONF_SRC" "$CONF"
cat >> "$CONF" <<APPEND

# ── Дописано entrypoint-ом із env ────────────────────────────────────
# Ім'я, яким ПІДПИСУЄМОСЯ в Authentication-Results.
AuthservID              $MAIL_HOSTNAME

# Чиїм заголовкам Authentication-Results ВІРИМО.
#
# Мусить збігатися з AuthservID у OpenDKIM — а він там теж
# \$MAIL_HOSTNAME, тобто збігається за конструкцією, а не за
# домовленістю. Якби не збігалось, OpenDMARC мовчки відкинув би наш же
# результат DKIM і оцінював лише по SPF: DMARC «працював би», даючи
# систематично неправильні відповіді.
TrustedAuthservIDs      $MAIL_HOSTNAME
APPEND

case "${1:-}" in
    '')      ;;
    check)
        echo "── opendmarc.conf ──"
        grep -v '^[[:space:]]*\(#\|$\)' "$CONF"
        echo "── ignore.hosts ──"; cat /etc/opendmarc/ignore.hosts
        echo "── public suffix list ──"
        echo "$PSL: $(wc -l < "$PSL") рядків"
        echo "── перевірка конфігу ──"
        exec opendmarc -n -c "$CONF"
        ;;
    *)  die "невідомий аргумент '$1'. Приймаємо лише 'check' або нічого";;
esac

opendmarc -n -c "$CONF" || die "opendmarc не приймає конфіг — див. вище"

syslog_to_stderr
say "exec opendmarc -f -c $CONF"
exec opendmarc -f -c "$CONF"
