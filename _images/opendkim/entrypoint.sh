#!/bin/sh
# ─────────────────────────────────────────────────────────────────────
#  Entrypoint образу opendkim.
#
#  Робить те, що в меті проєкту названо прямо: ключі DKIM генеруються
#  САМІ, а KeyTable/SigningTable виводяться з БД, а не правляться
#  руками. Інакше «додати домен» стало б четвертою ручною операцією.
#
#  Послідовність: дочекатись БД -> узяти список доменів -> на кожен
#  домен ключ (якщо його ще немає) -> зібрати таблиці -> зібрати
#  opendkim.conf зі статичної частини плюс те, що залежить від env.
# ─────────────────────────────────────────────────────────────────────
set -eu

# Спільна база плюс перекриття групи — див. _configs/README.md.
SHARED=/etc/opendkim/shared
CUSTOM=/etc/opendkim/config
KEYS=/etc/opendkim/keys
CONF=/etc/opendkim.conf
MYCNF=/run/opendkim-db.cnf

die() { echo "opendkim-entrypoint: $*" >&2; exit 1; }
say() { echo "opendkim-entrypoint: $*" >&2; }
# ── Логи мілтера ──────────────────────────────────────────────────────
# OpenDKIM і OpenDMARC умієте писати лише в syslog — опції «в stderr» у
# них немає. У контейнері syslog-а немає, тож `Syslog no` означало б
# «діагностики не існує»: саме через це DKIM довелось налагоджувати по
# заголовках листів, а `LogWhy yes` разом із `Syslog no` — просто
# суперечність.
#
# Тому піднімаємо мінімальний злив: socat слухає datagram-сокет
# /dev/log і копіює все в stderr, звідки це бере `docker logs`.
# Рядки приходять сирі, з числовим пріоритетом на початку (`<30>`) —
# це нормально, розбирати їх нема кому.
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


if [ -f "$CUSTOM/opendkim.conf" ]; then
    CONF_SRC=$CUSTOM/opendkim.conf
    say "конфіг ГРУПИ $CONF_SRC (перекриває спільний)"
elif [ -f "$SHARED/opendkim.conf" ]; then
    CONF_SRC=$SHARED/opendkim.conf
else
    die "немає ні $CUSTOM/opendkim.conf, ні $SHARED/opendkim.conf"
fi

missing=
for v in MYSQL_HOST MYSQL_DB MYSQL_USER MYSQL_PASSWORD \
         MAIL_HOSTNAME DKIM_SELECTOR INTERNAL_PREFIX; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
done
[ -z "$missing" ] || die "не задані змінні:$missing"

: "${MYNETWORKS:=}"
: "${DB_DRIVER:=mysql}"
[ "$DB_DRIVER" = mysql ] \
    || die "DB_DRIVER='$DB_DRIVER' поки не підтримується: сервіс БД у
шаблоні жорстко MariaDB (відкрите питання в CLAUDE.md). Коли з'явиться
PostgreSQL-група, тут додається гілка на psql"

# Пароль — у файлі з правами 600, а не в аргументах і не в env: інакше
# його видно або в `ps`, або в /proc/<pid>/environ.
umask 077
cat > "$MYCNF" <<CNF
[client]
host     = $MYSQL_HOST
user     = $MYSQL_USER
password = $MYSQL_PASSWORD
CNF
umask 022

# ── Дочекатись БД ─────────────────────────────────────────────────────
# Без цього opendkim стартує раніше MySQL, отримує порожній список
# доменів і далі МОВЧКИ не підписує нічого. Саме той сорт збою, якого
# треба позбутись: пошта ходить, підписів немає, у лозі нічого.
#
# При звичайному старті чекаємо хвилину — MariaDB на першому запуску
# розгортає схему й справді встигає не одразу. При `check` чекати стільку
# немає сенсу: там людина дивиться в термінал.
TRIES=30
[ "${1:-}" = check ] && TRIES=3

i=0
until mysql --defaults-extra-file="$MYCNF" --batch --skip-column-names \
            "$MYSQL_DB" -e 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge "$TRIES" ]; then
        say "БД $MYSQL_HOST/$MYSQL_DB не відповідає за $((TRIES * 2)) с."
        die "Якщо це перевірка через \`mailctl config\` — переконайся, що
група піднята: одноразовий контейнер бере мережу групи, але сам сервіс
mysql має в ній працювати. Якщо це звичайний старт — дивись
\`docker logs <група>-mysql\`"
    fi
    [ "$i" -eq 1 ] && say "чекаю на БД $MYSQL_HOST/$MYSQL_DB..."
    sleep 2
done

# ── Домени групи ──────────────────────────────────────────────────────
# Підписуємо лише те, для чого ми кінцева точка. RELAY/VIRTUAL — інші
# випадки, і підписувати чужий домен своїм ключем сенсу не має.
domains=$(mysql --defaults-extra-file="$MYCNF" --batch --skip-column-names \
          "$MYSQL_DB" -e "SELECT domain FROM domains WHERE type='LOCAL' ORDER BY domain")

if [ -z "$domains" ]; then
    say "УВАГА — у БД немає жодного домену з type='LOCAL'."
    say "Це означає, що підписуватись НЕ БУДЕ НІЧОГО. Якщо група щойно"
    say "створена — так і має бути; якщо ні, це збій, і він інакше"
    say "виглядав би як «пошта ходить, а DKIM немає»."
fi

# ── Ключі ─────────────────────────────────────────────────────────────
: > /etc/opendkim/KeyTable
: > /etc/opendkim/SigningTable

for d in $domains; do
    dir="$KEYS/$d"
    key="$dir/$DKIM_SELECTOR.private"

    if [ ! -s "$key" ]; then
        say "генерую ключ для $d (селектор $DKIM_SELECTOR)"
        mkdir -p "$dir"
        # 2048 біт: 1024 вже слабкий, а 4096 не влазить у один
        # TXT-рядок на 255 символів і вимагає склеювання, на якому
        # половина DNS-панелей спотикається.
        opendkim-genkey -b 2048 -d "$d" -s "$DKIM_SELECTOR" -D "$dir" \
            || die "opendkim-genkey не змогла для $d"
    fi
    chown -R opendkim:opendkim "$dir"
    chmod 700 "$dir"
    chmod 600 "$key"

    echo "$DKIM_SELECTOR._domainkey.$d $d:$DKIM_SELECTOR:$key" \
        >> /etc/opendkim/KeyTable
    # SigningTable — саме refile: лише в ньому працює `*@домен`.
    # Звичайний файл шукав би за повною адресою відправника.
    echo "*@$d $DKIM_SELECTOR._domainkey.$d" >> /etc/opendkim/SigningTable
done

# ── Кого вважаємо «своїм» ─────────────────────────────────────────────
#  ╔═══════════════════════════════════════════════════════════════════╗
#  ║ InternalHosts вирішує, що ПІДПИСАТИ, а що лише ПЕРЕВІРИТИ.        ║
#  ║ Дефолт — тільки localhost, і цього мало: Roundcube шле з          ║
#  ║ internal-мережі групи, а довірені мережі групи (MYNETWORKS)       ║
#  ║ шлють без авторизації й теж мусять підписуватись.                 ║
#  ║                                                                   ║
#  ║ ВІДОМА ПРОГАЛИНА: віддалений користувач, який автентикується на   ║
#  ║ порту 25 (а на джерелах саме так і шлють), сюди не потрапляє —    ║
#  ║ його адреса не з наших мереж. Для submission це закрито           ║
#  ║ `MTAs ORIGINATING` у статичному конфізі, для 25 — ні.             ║
#  ║ Перевіряти живим тестом, див. TODO.                               ║
#  ╚═══════════════════════════════════════════════════════════════════╝
{
    echo 127.0.0.1
    echo ::1
    echo "$INTERNAL_PREFIX.0/24"
    for n in $MYNETWORKS; do echo "$n"; done
} > /etc/opendkim/InternalHosts

# ── Конфіг ────────────────────────────────────────────────────────────
# Статична частина плюс те, що без env не існує. У opendkim.conf немає
# include, тому саме конкатенація; нічого з дописаного нижче НЕ задавати
# у статичному файлі — розійдеться мовчки.
cp "$CONF_SRC" "$CONF"
cat >> "$CONF" <<APPEND

# ── Дописано entrypoint-ом із env ────────────────────────────────────
# AuthservID — ім'я, яким ми підписуємо заголовок Authentication-Results.
# Мусить бути НАШИМ FQDN: OpenDMARC далі шукає саме його, і якщо тут
# опиниться чуже ім'я, DMARC-оцінка будуватиметься на заголовку, який
# ми ж і не ставили.
AuthservID $MAIL_HOSTNAME
APPEND

chown opendkim:opendkim /etc/opendkim/KeyTable /etc/opendkim/SigningTable \
                        /etc/opendkim/InternalHosts
rm -f "$MYCNF"

case "${1:-}" in
    '')      ;;
    check)
        echo "── opendkim.conf ──"
        grep -v '^[[:space:]]*\(#\|$\)' "$CONF"
        echo "── KeyTable ──";      cat /etc/opendkim/KeyTable
        echo "── SigningTable ──";  cat /etc/opendkim/SigningTable
        echo "── InternalHosts ──"; cat /etc/opendkim/InternalHosts
        echo "── перевірка конфігу ──"
        exec opendkim -n -x "$CONF"
        ;;
    *)  die "невідомий аргумент '$1'. Приймаємо лише 'check' або нічого";;
esac

# -n перевіряє конфіг і виходить; робимо це ДО запуску, щоб помилка не
# перетворилась на restart-loop без діагнозу.
opendkim -n -x "$CONF" || die "opendkim не приймає конфіг — див. вище"

syslog_to_stderr
say "exec opendkim -f -x $CONF"
exec opendkim -f -x "$CONF"
