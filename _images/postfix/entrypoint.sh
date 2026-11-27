#!/bin/sh
# ─────────────────────────────────────────────────────────────────────
#  Entrypoint образу postfix.
#
#  Робить три речі, яких статичний main.cf зробити не може:
#   1. накладає група-специфічні значення через `postconf -e`
#      (у main.cf немає include, а шаблонізувати файл sed-ом — це
#      повернутись до того, від чого ми пішли);
#   2. генерує мапи до БД у /etc/postfix/sql/ — там пароль, тому в
#      репозиторії їх бути не може;
#   3. вимикає chroot усім сервісам і додає submission через штатний
#      `postconf -M/-P/-F`, а не переписуванням master.cf руками.
# ─────────────────────────────────────────────────────────────────────
set -eu

# Спільна база плюс перекриття групи — див. коментар у dovecot-овому
# entrypoint і _configs/README.md.
SHARED=/etc/postfix-shared
CUSTOM=/etc/postfix-custom
SQL=/etc/postfix/sql
TLS_DIR=/etc/postfix/tls

die() { echo "postfix-entrypoint: $*" >&2; exit 1; }
say() { echo "postfix-entrypoint: $*" >&2; }

if [ -f "$CUSTOM/main.cf" ]; then
    MAIN_CF=$CUSTOM/main.cf
    say "конфіг ГРУПИ $MAIN_CF (перекриває спільний)"
elif [ -f "$SHARED/main.cf" ]; then
    MAIN_CF=$SHARED/main.cf
else
    die "немає ні $CUSTOM/main.cf, ні $SHARED/main.cf — перевір
GROUP_CONFIG_DIR у group.env і те, що _configs/ на місці"
fi

# ── Обов'язкові змінні ────────────────────────────────────────────────
missing=
for v in MYSQL_HOST MYSQL_DB MYSQL_USER MYSQL_PASSWORD \
         LISTEN_ADDRESSES PUBLIC_IP MAIL_HOSTNAME POSTMASTER_ADDRESS \
         INTERNAL_PREFIX; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
done
[ -z "$missing" ] || die "не задані змінні:$missing"

# MYNETWORKS свідомо НЕ обов'язковий: порожній — нормальний і
# найбезпечніший випадок (рішення №30).
: "${MYNETWORKS:=}"

# Домен для myorigin беремо з POSTMASTER_ADDRESS, а не з MAIL_HOSTNAME:
# у групи кілька доменів, і жоден не зобов'язаний збігатися з іменем
# вузла. POSTMASTER_ADDRESS — єдине місце, де поштовий домен групи
# названий явно.
PM_DOMAIN=${POSTMASTER_ADDRESS#*@}
[ -n "$PM_DOMAIN" ] || die "з POSTMASTER_ADDRESS='$POSTMASTER_ADDRESS' не
виходить домен"

# ── Статична частина ──────────────────────────────────────────────────
cp "$MAIN_CF" /etc/postfix/main.cf

# ── Мапи до БД ────────────────────────────────────────────────────────
# ЦІ ЗАПИТИ — КОНТРАКТ ЗІ СХЕМОЮ _schemas/mysql-mail: імена подань
# (usersdb, aliasesview) і стовпців не довільні. Групі на PostgreSQL
# треба буде інший набір.
#
# `%s` — повний ключ пошуку, який підставляє Postfix. Літерала `%` в
# запитах немає навмисно: у конфігах Postfix його довелось би подвоювати,
# і це класична прихована помилка (та сама причина, що в рішенні №19).
mkdir -p "$SQL"
umask 027
write_map() {
    cat > "$SQL/$1" <<MAP
# ЗГЕНЕРОВАНО entrypoint-ом. Не редагувати: перезаписується на кожному
# старті контейнера.
hosts    = $MYSQL_HOST
user     = $MYSQL_USER
password = $MYSQL_PASSWORD
dbname   = $MYSQL_DB
query    = $2
MAP
}

# Домени, для яких ми кінцева точка. Тільки LOCAL: RELAY і VIRTUAL у
# схемі є, але означають інше й етапу 1 не стосуються.
write_map virtual_domains.cf \
    "SELECT domain FROM domains WHERE domain='%s' AND type='LOCAL'"

# Чи існує скринька. Подання usersdb уже відкидає неактивних
# (active='Y'), тож вимкнений користувач перестає приймати пошту без
# жодної додаткової умови тут.
write_map virtual_mailboxes.cf \
    "SELECT \`user\` FROM usersdb WHERE \`user\`='%s'"

# Аліаси. Стовпець email у поданні — це список отримувачів через кому,
# рівно в тому вигляді, якого чекає virtual_alias_maps.
write_map virtual_aliases.cf \
    "SELECT email FROM aliasesview WHERE alias='%s'"

# Політика за доменом отримувача (рішення №19). Порожня таблиця =
# нуль ефекту, тож мапа підключається завжди й окремого вимикача не
# має: зайва змінна коштувала б більше, ніж один індексний lookup.
#
# ЧОМУ НЕ LIKE: у таблиці очікується 297 історичних записів плюс
# список cip.gov.ua на 50+ тисяч доменів. Суфіксний LIKE означав би
# повний скан на КОЖЕН RCPT. Тому кандидати генеруються з самого
# імені — їх завжди одиниці — і б'ють по PRIMARY KEY.
#
# ЧОМУ НЕ «найдовший рядок <= вхідного» одним скном: контрприклад у
# рішенні №19 — у таблиці `ua.com` і `ua.com.exam`, на вході
# `example.com.ua`. Найбільший рядок <= вхідного це `ua.com.exam`, він
# не доменний суфікс, перевірка провалюється, і `ua.com` не
# знаходиться, хоч і мав би.
#
# ORDER BY LENGTH(domain) DESC дає НАЙТОЧНІШИЙ збіг першим: якщо є і
# `example.com`, і `com`, спрацює перший.
#
# Ключ, який підставляє Postfix для check_recipient_access, — повна
# адреса, тож `%d` тут домен отримувача. Літерала `%` у запиті немає
# навмисно (у конфігах Postfix його довелось би подвоювати).
write_map recipient_policy.cf \
    "SELECT action FROM recipient_policy
      WHERE domain IN ('%d',
              SUBSTRING_INDEX('%d','.',-2), SUBSTRING_INDEX('%d','.',-3),
              SUBSTRING_INDEX('%d','.',-4), SUBSTRING_INDEX('%d','.',-5),
              SUBSTRING_INDEX('%d','.',-6), SUBSTRING_INDEX('%d','.',-7))
        AND (domain = '%d' OR include_subdomains)
      ORDER BY LENGTH(domain) DESC LIMIT 1"

# ── abuse_block: тимчасові блокування (рішення №20) ───────────────────
# Дві мапи на ОДНУ таблицю, бо це дві різні перевірки Postfix із
# різними ключами.
#
# ЗАПИТ ТРИВІАЛЬНИЙ НАВМИСНО — ключі генерує сам Postfix:
#   check_client_access послідовно пробує a.b.c.d, a.b.c, a.b, a
#     (тобто /32, /24, /16, /8 без жодних inet-кастів);
#   check_sender_access — повну адресу, потім її домен.
# Нам лишається точний збіг по PRIMARY KEY. Арифметики підмереж тут
# немає й бути не має: будь-який CIDR, що не кратний октету, у таблиці
# не виражається, і `mailctl block` на такий відмовляє з поясненням.
#
# `expires_at > NOW()` — це і є «розблокування як операції не існує»
# (рішення №20): рядок просто перестає матчитись. Четвертої ручної
# операції не з'являється.
#
# NOW() — час СУБД, не наш: порівнювати треба тим самим годинником,
# яким термін проставляли (`mailctl block` пише
# `NOW() + INTERVAL ? SECOND`), інакше розхід TZ між контейнерами
# давав би блокування, що скінчилось «на годину раніше».
write_map abuse_client.cf \
    "SELECT action FROM abuse_block
      WHERE scope='client' AND block_key='%s' AND expires_at > NOW()
      LIMIT 1"

write_map abuse_sender.cf \
    "SELECT action FROM abuse_block
      WHERE scope='sender' AND block_key='%s' AND expires_at > NOW()
      LIMIT 1"

# ── Резервний MX (рішення №39) ────────────────────────────────────────
# ОДНА мапа на ДВА параметри, і це навмисно:
#   relay_domains        — чи приймаємо пошту для цього домену взагалі
#                          (значення рядка ігнорується, важлива наявність);
#   relay_verify_check   — check_recipient_access, де значення це НАЗВА
#                          обмеження; access(5) таке дозволяє.
# Дві мапи з однаковим WHERE розійшлися б мовчки, і тоді ми або
# приймали б пошту без перевірки отримувача (backscatter), або
# перевіряли домен, для якого не є релеєм.
#
# `%s`, а не `%d`: ключі в цих двох параметрів РІЗНІ. relay_domains
# шукає голий домен (`example.com`), а check_recipient_access пробує
# спершу повну адресу, потім домен. `%d` на ключі без `@` не
# розкривається, і dict_mysql тоді запит НЕ виконує — тобто з `%d`
# relay_domains не знайшов би нічого ніколи. З `%s` зайвий lookup по
# повній адресі просто не збігається, і це безпечно.
#
# Піддоменів НЕ розгортаємо: з compatibility_level 2+ relay_domains
# прибраний із parent_domain_matches_subdomains, тож збіг тут завжди
# точний. Потрібен піддомен — окремий рядок у таблиці. Так воно й
# правильніше: `MX` ставлять на конкретне ім'я, а не на дерево.
write_map relay_domains.cf \
    "SELECT 'reject_unverified_recipient' FROM domains
      WHERE domain='%s' AND type='RELAY'"

# Читає їх proxymap від імені користувача postfix (chroot вимкнений
# нижче), тому група — postfix, а не root.
chmod 640 "$SQL"/*.cf
chgrp postfix "$SQL"/*.cf
umask 022

# ── Група-специфічні значення ─────────────────────────────────────────
# Усе, що нижче, у статичному main.cf дублювати НЕ можна — розійдеться
# мовчки.
#
# inet_interfaces: явний перелік, НЕ `all`.
#
# ┌───────────────────────────────────────────────────────────────────┐
# │ INTERNAL_PREFIX.10 тут — та сама СВІДОМА зміна, що й у `listen`   │
# │ Dovecot, і спершу я зробив її ЛИШЕ для Dovecot. Помилка показова: │
# │ пара ділить netns і адресу, тож «половина пари» виглядала як      │
# │ працююча — вхід у вебмейл проходив (IMAP), а відправка падала з   │
# │ «Не вдалося з'єднатися з сервером» (SMTP на 587).                 │
# │                                                                   │
# │ Причина та сама: Roundcube за рішенням №5 живе ПОЗА netns, і      │
# │ дістатись до Postfix може лише по internal-адресі. На 127.0.0.1 — │
# │ інший namespace; на публічну адресу — пакет пішов би через bridge │
# │ на хост, а хост власних ipvlan-слейвів не бачить.                 │
# │                                                                   │
# │ Що стало видно решті internal: 25 і 587. РЕЛЕЙ цим не             │
# │ відкривається — `mynetworks` лишається 127.0.0.0/8, тобто сусід   │
# │ по мережі може лише здати пошту НАШИМ користувачам, як будь-хто   │
# │ зі світу. SASL-auth (12345) і LMTP (24) лишаються на loopback     │
# │ (рішення №11) — саме вони дали б релей без пароля.                │
# └───────────────────────────────────────────────────────────────────┘
# ── inet_protocols: виводимо з адрес, а не з дефолту ─────────────────
# Дефолт Postfix — `all`, тобто він резолвить AAAA і НАМАГАЄТЬСЯ піти
# по IPv6. Якщо в групи IPv6-адреси немає, кожен лист до великого
# провайдера починається з невдалої спроби:
#
#   connect to gmail-smtp-in.l.google.com[2a00:1450:...]:25:
#       Network is unreachable
#
# Пошта не губиться — Postfix відкочується на IPv4, — але платить
# ~0.85 с на лист (видно в `delays=` третім числом) і засмічує лог.
# Виміряно на живому пересиланні в Gmail, не припущено.
#
# Окремого параметра групи НЕ заводимо: це ПОХІДНЕ від ADDRESSES, а
# дві змінні, що мусять узгоджуватись, розійшлися б мовчки — те саме
# правило, що прибрало `PUBLIC_IP` з group.env (рішення №29). Коли в
# групи з'явиться IPv6-адреса, `all` повернеться саме собою, і
# `smtp_bind_address6` з PITFALLS стане потрібним тоді ж.
case "$LISTEN_ADDRESSES" in
    *:*) inet_proto=all ;;
    *)   inet_proto=ipv4 ;;
esac
echo "postfix-entrypoint: inet_protocols = $inet_proto" \
     "(виведено з ADDRESSES групи)" >&2

# 127.0.0.1 потрібен для LMTP/SASL-пари з Dovecot.
postconf -e \
    "inet_protocols = $inet_proto" \
    "myhostname = $MAIL_HOSTNAME" \
    "mydomain = $PM_DOMAIN" \
    "myorigin = \$mydomain" \
    "inet_interfaces = $LISTEN_ADDRESSES 127.0.0.1 ${INTERNAL_PREFIX}.10" \
    "bounce_notice_recipient = $POSTMASTER_ADDRESS" \
    "2bounce_notice_recipient = $POSTMASTER_ADDRESS" \
    "error_notice_recipient = $POSTMASTER_ADDRESS" \
    "delay_notice_recipient = $POSTMASTER_ADDRESS"

# ── Пошта на ВЛАСНЕ ІМ'Я ВУЗЛА ────────────────────────────────────────
# Обґрунтування — у main.cf, поруч із двома порожніми макросами.
# Коротко: `mydestination` порожній свідомо, тож без цього блоку лист на
# `postmaster@$MAIL_HOSTNAME` отримує 450 знадвору й `loops back to
# myself` зсередини. На isp-джерелі цей аліас був живим.
#
# Обидва параметри ставляться РАЗОМ або не ставляться взагалі:
# `virtual_alias_domains` без мапи зробив би ім'я вузла доменом без
# жодної адреси, тобто 550 на все — гірше, ніж нічого.
#
# `inline:` — вбудована мапа Postfix (з 3.0), але перевіряємо, бо
# «вбудована» це наше знання, а не факт із цього образу. Той самий
# урок, що з окремим пакетом `spamd`.
if postconf -m 2>/dev/null | grep -qx inline; then
    ha_map="inline:{{postmaster@$MAIL_HOSTNAME=$POSTMASTER_ADDRESS},{abuse@$MAIL_HOSTNAME=$POSTMASTER_ADDRESS}}"

    # КОНТРОЛЬ: мапа мусить ВІДПОВІСТИ потрібною адресою. Без цього
    # помилка в синтаксисі inline дала б порожню мапу, а разом із
    # virtual_alias_domains — 550 на postmaster, тобто рівно те, чого
    # ми тут уникаємо.
    ha_got=$(postmap -q "postmaster@$MAIL_HOSTNAME" "$ha_map" 2>/dev/null || true)
    if [ "$ha_got" = "$POSTMASTER_ADDRESS" ]; then
        postconf -e \
            "hostname_aliases = $ha_map," \
            "hostname_alias_domain = \$myhostname"
        echo "postfix-entrypoint: приймаємо postmaster@ і abuse@ на" \
             "$MAIL_HOSTNAME -> $POSTMASTER_ADDRESS" >&2
    else
        postconf -e "hostname_aliases =" "hostname_alias_domain ="
        echo "postfix-entrypoint: УВАГА: inline-мапа не відповіла" \
             "(отримано '$ha_got'), пошта на $MAIL_HOSTNAME НЕ" \
             "приймається. postmaster@ на ІМ'Я ВУЗЛА недосяжний;" \
             "на домени групи це не впливає." >&2
    fi
else
    postconf -e "hostname_aliases =" "hostname_alias_domain ="
    echo "postfix-entrypoint: УВАГА: Postfix не знає типу мапи inline," \
         "тож postmaster@$MAIL_HOSTNAME не приймається." >&2
fi

# Вихідна пошта МУСИТЬ іти з адреси групи. Без цього вона може піти
# дефолтним маршрутом через internal-bridge під адресою хоста — повз
# rDNS і SPF групи, тобто прямо в спам.
postconf -e "smtp_bind_address = $PUBLIC_IP"

# mynetworks ЗАВЖДИ задаємо явно, навіть порожнім. Дефолтний
# `mynetworks_style = subnet` інакше довірив би всій internal-підмережі
# групи — тобто й гостю-проксі, і кожному контейнеру поруч.
# 127.0.0.0/8 потрібен: звідти ходить сам Dovecot.
if [ -n "$MYNETWORKS" ]; then
    postconf -e "mynetworks = 127.0.0.0/8 $MYNETWORKS"
else
    postconf -e "mynetworks = 127.0.0.0/8"
fi

# ── Greylisting (TODO п.5b, рішення №21) ──────────────────────────────
# У main.cf стоїть порожній `greylist_policy =`, підставлений у список
# обмежень як `$greylist_policy`. Тут він або наповнюється, або
# лишається порожнім — і список обмежень при цьому НЕ переписується.
# Інакше в entrypoint з'явилась би друга копія всього списку, яка
# одного дня розійдеться з main.cf мовчки.
#
# ВАЖЛИВО, ЧОМУ ВИМИКАЧ ПОТРІБЕН УЗАГАЛІ: `check_policy_service` на
# мертвий сервіс означає 451 на ВСЮ пошту. Тобто вмикати його на групі,
# де postgrey ще не піднятий, — це не «фільтр не працює», а «пошта не
# приймається». Рішення №21 (на isp-подібній групі вмикати поетапно)
# саме це й має на увазі.
#
# На isp цей рядок був ЗАКОМЕНТОВАНИЙ, хоч демон працював (TODO
# п.5b). Тобто наявність процесу там нічого не доказувала — і це
# рівно та причина, через яку `mailctl health` перевіряє порт, а не
# процес.
case "${GREYLIST:-yes}" in
    yes|YES|true|1)
        postconf -e "greylist_policy = check_policy_service inet:postgrey:10023"
        echo "postfix-entrypoint: greylisting УВІМКНЕНИЙ (postgrey:10023)" >&2
        ;;
    *)
        postconf -e "greylist_policy ="
        echo "postfix-entrypoint: greylisting вимкнений (GREYLIST=${GREYLIST:-})" >&2
        ;;
esac

# ── SQL-мапи політик: або мапа ПРАЦЮЄ, або її не підключаємо ──────────
# Рішення №19 (блокування за доменом отримувача) і №39 (резервний MX)
# дають по таблиці в БД. Але збій SQL-мапи Postfix трактує як збій
# ПЕРЕВІРКИ, тобто відповідає 451 на КОЖЕН RCPT. А таблиці може не
# бути: `mysql-init` виконується лише при ПЕРШОМУ старті MariaDB, тож
# будь-яка група, піднята до появи коду, її не має.
#
# Ціна помилки тут несиметрична, і це вирішальне. Не підключена мапа —
# «політика не діє», видно в health, лікується одною командою.
# Підключена мапа без таблиці — «пошта не приймається»: відправник
# бачить тимчасову помилку, повторює п'ять днів і отримує баунс. На
# isp це тендери й звіти, тобто втрата такого листа вимірюється не
# незручністю.
#
# Тому той самий прийом, що в greylist_policy вище: у main.cf стоять
# порожні макроси, підставлені в список обмежень, а тут вони
# наповнюються — і лише якщо мапа справді відповідає.

# proxymap має СВІЙ список дозволених таблиць — `proxy_read_maps`, і в
# його дефолті перелічені імена параметрів Postfix ($virtual_alias_maps
# і подібні). Мапа, на яку посилається лише НАШ макрос усередині
# smtpd_recipient_restrictions, у цей перелік не входить, тож proxymap
# міг би відкинути її як неузгоджену — а це знову 451, причому проба
# прямим `mysql:` цього не побачила б, бо вона proxymap не чіпає.
#
# Замість того, щоб покладатись на пам'ять про дефолт, додаємо мапи
# явно: беремо дефолт у самого Postfix і дописуємо своє. Якщо вони там
# і так були б дозволені — рядок нічого не змінює; якщо ні — знімає
# цілий режим збою.
#
# ОБИДВІ мапи дописуються ОДНИМ викликом навмисно: `postconf -h -d`
# віддає ДЕФОЛТ, а не поточне значення, тож другий такий виклик
# затер би доданок першого.
#
# `$pr_def` містить літерали на кшталт `$virtual_alias_maps`, і shell
# їх ПОВТОРНО не розкриває (розкриття не рекурсивне) — тому лапки тут
# безпечні. Писати `proxy_read_maps = $proxy_read_maps ...` у main.cf
# було б не можна: це посилання параметра на себе.
rp_cf="$SQL/recipient_policy.cf"
rd_cf="$SQL/relay_domains.cf"
ac_cf="$SQL/abuse_client.cf"
as_cf="$SQL/abuse_sender.cf"
pr_def=$(postconf -h -d proxy_read_maps 2>/dev/null)
if [ -n "$pr_def" ]; then
    our_maps="mysql:$rp_cf mysql:$rd_cf mysql:$ac_cf mysql:$as_cf"
    postconf -e "proxy_read_maps = $pr_def $our_maps"
else
    echo "postfix-entrypoint: УВАГА: postconf не віддав дефолт" \
         "proxy_read_maps — наші мапи могли лишитись незатвердженими" \
         "для proxymap" >&2
fi

# probe_sql_map <файл.cf> <ключ> <таблиця>
# Ставить PROBE_CONTROL (порожній = КОНТРОЛЬ НЕ СПРАЦЮВАВ, пробі вірити
# не можна) і PROBE_ERR (порожній = мапа відповідає).
#
# КОНТРОЛЬ САМОЇ ПРОБИ: та сама мапа з завідомо неіснуючою таблицею
# мусить дати вивід у stderr. Без цього зміна поведінки postmap у
# новій версії зробила б перевірку тихо завжди-успішною — рівно той
# клас «проби без контролю», на якому проєкт уже двічі обпікся.
probe_sql_map() {
    _cf="$1"; _key="$2"; _table="$3"
    _ctl=/tmp/probe-control.cf
    sed "s/FROM $_table/FROM mailstack_no_such_table/" "$_cf" > "$_ctl"
    chmod 640 "$_ctl"; chgrp postfix "$_ctl"
    PROBE_CONTROL=$(postmap -q "$_key" "mysql:$_ctl" 2>&1 >/dev/null || true)
    rm -f "$_ctl"

    # Саму мапу пробуємо з повторами: при старті групи MariaDB може бути
    # ще не готова, і це НЕ те саме, що відсутня таблиця. Розрізняємо за
    # текстом помилки.
    PROBE_ERR=''
    _try=0
    while [ "$_try" -lt 15 ]; do
        PROBE_ERR=$(postmap -q "$_key" "mysql:$_cf" 2>&1 >/dev/null || true)
        [ -z "$PROBE_ERR" ] && break
        case "$PROBE_ERR" in
            *"doesn't exist"*|*"Unknown table"*|*"Unknown column"*) break ;;
        esac
        _try=$((_try + 1))
        sleep 2
    done
}

# ── recipient_policy (рішення №19) ────────────────────────────────────
# КЛЮЧ ПРОБИ МУСИТЬ МІСТИТИ `@`. Запит використовує `%d`, а dict_mysql
# при неможливості розкрити `%d` (ключ без домену) запит НЕ ВИКОНУЄ
# взагалі й тихо віддає «не знайдено». Тобто `postmap -q example.com`
# віддає rc=1 без жодної помилки і на СПРАВНІЙ, і на зламаній мапі —
# проба ні про що.
probe_sql_map "$rp_cf" 'probe@rp-probe.invalid' recipient_policy
if [ -z "$PROBE_CONTROL" ]; then
    postconf -e "recipient_policy_check ="
    echo "postfix-entrypoint: УВАГА: контроль проби recipient_policy не спрацював" >&2
    echo "  (postmap на неіснуючій таблиці промовчав), тому мапу НЕ підключаю." >&2
    echo "  Блокування за доменом отримувача НЕ діє; пошта приймається." >&2
elif [ -n "$PROBE_ERR" ]; then
    postconf -e "recipient_policy_check ="
    echo "postfix-entrypoint: recipient_policy НЕ підключений:" >&2
    echo "  $PROBE_ERR" >&2
    echo "  Блокування за доменом отримувача НЕ діє; пошта приймається." >&2
    echo "  Якщо таблиці немає — застосуй схему до живої бази:" >&2
    echo "    ./mailctl db-load <група> _schemas/upgrade/add-recipient-policy.sql" >&2
    echo "  і потім ./mailctl reload <група> postfix" >&2
else
    postconf -e \
        "recipient_policy_check = check_recipient_access proxy:mysql:$rp_cf"
    echo "postfix-entrypoint: recipient_policy підключений ($rp_cf)" >&2
fi

# ── relay_domains: резервний MX (рішення №39) ─────────────────────────
# Ключ проби — ГОЛИЙ домен, бо запит на `%s`, і саме так його шукає
# relay_domains. Тут `@` не потрібен (і був би іншим ключем).
#
# Ціна невдачі та сама несиметрична, але дзеркальна: не підключені
# relay_domains означають, що для чужих доменів ми відповідаємо
# «Relay access denied» — тобто резервний MX зникає, а ВЛАСНА пошта
# групи при цьому ходить. Підключені без таблиці поклали б усе.
#
# ОБА параметри ставляться разом або не ставляться зовсім:
# relay_domains без relay_verify_check — це той самий генератор
# backscatter, що на isp-джерелі зараз (приймаємо для чужого домену,
# отримуємо 550, складаємо баунс підробленому відправнику).
probe_sql_map "$rd_cf" 'rd-probe.invalid' domains
if [ -z "$PROBE_CONTROL" ]; then
    postconf -e "relay_domains =" "relay_verify_check ="
    echo "postfix-entrypoint: УВАГА: контроль проби relay_domains не спрацював" >&2
    echo "  (postmap на неіснуючій таблиці промовчав), тому мапу НЕ підключаю." >&2
    echo "  Група НЕ є резервним MX ні для кого; власна пошта ходить." >&2
elif [ -n "$PROBE_ERR" ]; then
    postconf -e "relay_domains =" "relay_verify_check ="
    echo "postfix-entrypoint: relay_domains НЕ підключений:" >&2
    echo "  $PROBE_ERR" >&2
    echo "  Група НЕ є резервним MX ні для кого; власна пошта ходить." >&2
    echo "  Домени релею лежать у таблиці domains (type='RELAY'), тобто" >&2
    echo "  там же, де й власні — брак таблиці тут неможливий." >&2
else
    postconf -e \
        "relay_domains = proxy:mysql:$rd_cf" \
        "relay_verify_check = check_recipient_access proxy:mysql:$rd_cf"
    echo "postfix-entrypoint: relay_domains підключений ($rd_cf)" >&2
fi

# ── abuse_block: тимчасові блокування (рішення №20) ───────────────────
# Пробуємо ОБИДВІ мапи, хоч таблиця одна: файли різні, і зламатись
# може будь-який із них окремо (наприклад, після правки write_map).
#
# Ключі проби різні за формою навмисно — кожен такий, яким його
# підставляє відповідна перевірка Postfix: для клієнта адреса, для
# відправника повна поштова адреса. Тут `%d` у запитах немає, тож
# пастки з нерозкритим `%d` (як у recipient_policy) не виникає, але
# ключ «не тієї форми» однаково перевіряв би не те, що працює наживо.
#
# Адреса 192.0.2.1 — з TEST-NET-1 (RFC 5737), тобто гарантовано нічия.
#
# ПІДКЛЮЧАЄМО ОБИДВІ АБО НІ ОДНУ: мапи читають ту саму таблицю, тож
# «працює лише sender» означав би, що заражена машина далі шле без
# перешкод, а health показував би блокування як діюче.
#
# Ціна невдачі та сама несиметрична, що в recipient_policy: не
# підключені мапи означають, що блокування не діє, а пошта ходить;
# підключені без таблиці — 451 на кожен RCPT.
abuse_ok=1
ABUSE_ERR=''
for _ab in "$ac_cf|192.0.2.1" "$as_cf|probe@ab-probe.invalid"; do
    _abf=${_ab%%|*}
    _abk=${_ab#*|}
    probe_sql_map "$_abf" "$_abk" abuse_block
    if [ -z "$PROBE_CONTROL" ]; then
        abuse_ok=0
        echo "postfix-entrypoint: УВАГА: контроль проби abuse_block не спрацював" >&2
        echo "  (postmap на неіснуючій таблиці промовчав) для $_abf." >&2
        break
    fi
    if [ -n "$PROBE_ERR" ]; then
        abuse_ok=0
        ABUSE_ERR="$PROBE_ERR"
        break
    fi
done

if [ "$abuse_ok" = 1 ]; then
    postconf -e \
        "abuse_client_check = check_client_access proxy:mysql:$ac_cf" \
        "abuse_sender_check = check_sender_access proxy:mysql:$as_cf"
    echo "postfix-entrypoint: abuse_block підключений (client + sender)" >&2
else
    postconf -e "abuse_client_check =" "abuse_sender_check ="
    echo "postfix-entrypoint: abuse_block НЕ підключений:" >&2
    if [ -n "$ABUSE_ERR" ]; then echo "  $ABUSE_ERR" >&2; fi
    echo "  Тимчасові блокування НЕ діють; пошта приймається." >&2
    echo "  Якщо таблиці немає — застосуй схему до живої бази:" >&2
    echo "    ./mailctl db-load <група> _schemas/upgrade/add-abuse-block.sql" >&2
    echo "  і потім ./mailctl reload <група> postfix" >&2
fi

# ── anvil: ліміти на клієнта (рішення №13, третя частина) ─────────────
# Самі ліміти стоять у main.cf разом із поясненням, чому саме такі.
# Тут — лише те, що залежить від ГРУПИ.
#
# ANVIL_EXCEPTIONS: кому ліміти не діють. 127.0.0.0/8 додається завжди
# і не обговорюється — звідти ходять Dovecot (LMTP, SASL) і сам
# Postfix, і обмежувати їх означало б обмежити власну доставку.
#
# ВАЖЛИВО: тут НЕ підставляється $mynetworks, хоч це дефолт Postfix.
# Обґрунтування — у main.cf біля параметра; коротко: рішення №20
# називає anvil компенсацією за широкий mynetworks, а дефолт вимикав
# би його саме там.
#
# ANVIL=no ставить усі п'ять лімітів у нуль (у Postfix 0 = без
# обмеження). Це перший етап для isp-подібної групи за рішенням
# №21: спершу подивитись, що anvil пише в лог
# (`max ... rate N/60s for (smtp:ADDR)`), і лише потім вмикати
# відмови. Вимикач саме такий, а не «не задавати параметри», бо
# значення лежать у main.cf і без явного нуля діяли б.
case "${ANVIL:-yes}" in
    yes|YES|true|1)
        # Ліміти рахує ОКРЕМИЙ сервіс anvil із master.cf. Якщо його там
        # немає, smtpd нікого не питає — тобто всі п'ять лімітів у
        # main.cf стоять і НЕ ДІЮТЬ, мовчки. Пакетний master.cf його
        # містить, але master.cf ми правимо самі (postconf -M), тож
        # перевіряємо, а не припускаємо.
        postconf -M anvil/unix >/dev/null 2>&1 || {
            echo "postfix-entrypoint: ПОМИЛКА — ANVIL=yes, але сервісу" >&2
            echo "postfix-entrypoint: anvil немає в master.cf. Ліміти в" >&2
            echo "postfix-entrypoint: main.cf стояли б і не діяли." >&2
            exit 1
        }
        postconf -e \
            "smtpd_client_event_limit_exceptions = 127.0.0.0/8 ${ANVIL_EXCEPTIONS:-}"
        echo "postfix-entrypoint: anvil УВІМКНЕНИЙ, винятки: 127.0.0.0/8 ${ANVIL_EXCEPTIONS:-}" >&2
        ;;
    *)
        postconf -e \
            "smtpd_client_connection_count_limit = 0" \
            "smtpd_client_connection_rate_limit = 0" \
            "smtpd_client_message_rate_limit = 0" \
            "smtpd_client_recipient_rate_limit = 0" \
            "smtpd_client_auth_rate_limit = 0" \
            "smtpd_client_event_limit_exceptions = 127.0.0.0/8"
        echo "postfix-entrypoint: anvil вимкнений (ANVIL=${ANVIL:-}), ліміти обнулені" >&2
        ;;
esac

# ── Сторож: невідомі параметри в нашому конфізі ───────────────────────
# Postfix НЕ лається на невідоме ім'я параметра: він вважає його
# користувацьким макросом, який просто ніхто не читає. Тобто опечатка в
# `smtpd_client_auth_rate_limit` не ламає нічого видимого — вона лише
# МОВЧКИ вимикає те, що мала ввімкнути. Для конфігу, де половина
# параметрів — політики безпеки, це найгірший можливий режим збою.
#
# `postconf -d <ім'я>` про невідоме ім'я попереджає, і це єдиний
# дешевий оракул, який у нас є.
#
# Наші власні макроси перелічені явно: вони підставляються в інші
# значення через $ім'я і для Postfix справді невідомі.
OUR_MACROS='greylist_policy recipient_policy_check relay_verify_check abuse_client_check abuse_sender_check hostname_aliases hostname_alias_domain submission_milters'

# Спершу перевіряємо САМ СТОРОЖ на завідомо неіснуючому імені. Без
# цього зміна формату попередження перетворила б перевірку на тихо
# завжди-успішну — рівно той клас «проби без контролю», на якому цей
# проєкт уже двічі обпікся.
if postconf -d mailstack_no_such_parameter 2>&1 >/dev/null \
     | grep -q 'unknown parameter'
then
    _names=$(postconf -n 2>/dev/null | sed -n 's/^\([a-z0-9_]\{1,\}\) *=.*/\1/p')
    for _m in $OUR_MACROS; do
        _names=$(echo "$_names" | grep -vx "$_m" || true)
    done
    # shellcheck disable=SC2086
    _unknown=$(postconf -d $_names 2>&1 >/dev/null \
                 | sed -n 's/.*: \([a-z0-9_]\{1,\}\): unknown parameter.*/\1/p' \
                 | sort -u | tr '\n' ' ')
    if [ -n "${_unknown# }" ]; then
        echo "postfix-entrypoint: ПОМИЛКА — Postfix не знає таких параметрів:" >&2
        echo "postfix-entrypoint:   $_unknown" >&2
        echo "postfix-entrypoint: вони лежать у конфізі й МОВЧКИ не діють." >&2
        echo "postfix-entrypoint: або це опечатка, або параметр з іншої версії" >&2
        echo "postfix-entrypoint: Postfix. Якщо ім'я власного макроса — додати" >&2
        echo "postfix-entrypoint: його в OUR_MACROS у цьому entrypoint." >&2
        echo "postfix-entrypoint:" >&2
        echo "postfix-entrypoint: НАЙІМОВІРНІША ПРИЧИНА, якщо ти щойно зробив" >&2
        echo "postfix-entrypoint: git pull: ОБРАЗ СТАРІШИЙ ЗА main.cf. Конфіг" >&2
        echo "postfix-entrypoint: приходить bind-mount-ом із репозиторію, а" >&2
        echo "postfix-entrypoint: список OUR_MACROS — із образу, тож новий" >&2
        echo "postfix-entrypoint: макрос у конфізі старий сторож не впізнає." >&2
        echo "postfix-entrypoint: Лікується: ./mailctl build && ./mailctl reload <група> postfix" >&2
        exit 1
    fi
else
    echo "postfix-entrypoint: УВАГА — перевірка невідомих параметрів НЕ працює:" >&2
    echo "postfix-entrypoint: postconf змінив формат попередження. Опечатка в" >&2
    echo "postfix-entrypoint: імені параметра тепер пройде непоміченою." >&2
fi

# ── master.cf ─────────────────────────────────────────────────────────
# chroot геть усім сервісам. У контейнері він не додає ізоляції (вона й
# так є), зате ламає все, що читає файли поза /var/spool/postfix:
# mysql-мапи, /etc/resolv.conf, сертифікати. Класична година дебагу на
# «чому proxymap не бачить БД».
postconf -F '*/*/chroot = n'

# ── postscreen на порту 25 (рішення №13) ──────────────────────────────
# ┌───────────────────────────────────────────────────────────────────┐
# │ ЩО ТУТ ВІДБУВАЄТЬСЯ: порт 25 віддається postscreen, а smtpd       │
# │ стає сервісом ТИПУ `pass` — тобто postscreen сам приймає          │
# │ з'єднання, робить свої тести й ПЕРЕДАЄ дескриптор smtpd лише      │
# │ тим, хто їх пройшов.                                              │
# │                                                                   │
# │ maxproc = 1 не помилка: postscreen один процес на всі з'єднання   │
# │ (він їх не обробляє, а лише тримає й спостерігає). Саме тому він  │
# │ дешевий — бот, що висить у greet_wait, не займає ні smtpd, ні     │
# │ жодного мілтера.                                                  │
# │                                                                   │
# │ 587 НЕ зачіпається свідомо: там свої клієнти з паролем, і         │
# │ затримка на banner ламала б їм відправку без жодної користі.      │
# │                                                                   │
# │ tlsproxy ОБОВ'ЯЗКОВИЙ, бо на 25 ми оголошуємо STARTTLS: postscreen│
# │ сам TLS не вміє й передає його цьому сервісу. Без нього STARTTLS  │
# │ на 25 просто зникне з EHLO.                                       │
# │                                                                   │
# │ dnsblog потрібен лише коли задані postscreen_dnsbl_sites. Ми їх   │
# │ НЕ задаємо (див. main.cf — урок Validity), але сервіс визначаємо: │
# │ інакше перше ж увімкнення DNSBL дало б незрозумілу відмову.       │
# └───────────────────────────────────────────────────────────────────┘
postconf -M smtp/inet="smtp inet n - n - 1 postscreen"
postconf -M smtpd/pass="smtpd pass - - n - - smtpd"
postconf -M tlsproxy/unix="tlsproxy unix - - n - 0 tlsproxy"
postconf -M dnsblog/unix="dnsblog unix - - n - 0 dnsblog"

# Дія pregreet-тесту — ПАРАМЕТР ГРУПИ, і це прямо з рішення №21.
#
# Дефолт самого Postfix — `ignore`, тобто лише запис у лог. Для нас це
# не дефолт, а ПЕРШИЙ ЕТАП: на isp-подібній групі (312 абонентів, які
# ніколи не мали фільтрації) спершу дивимось статистику, і лише потім
# вмикаємо відмову. На small одразу `enforce`.
#
# `enforce`, а не `drop`: enforce відповідає 550 і пише в лог повну
# причину, drop рве з'єднання. Друге економить мілісекунди й забирає
# діагностику.
postconf -e "postscreen_greet_action = ${POSTSCREEN_ACTION:-enforce}"
echo "postfix-entrypoint: postscreen greet_action = ${POSTSCREEN_ACTION:-enforce}" >&2

# Рішення №12: submission на 587 — STARTTLS обов'язковий, вхід лише
# авторизованим. На 25 усе лишається як було, це додаток, а не замінник.
#
# Окремий список мілтерів: на вихідній пошті потрібні OpenDKIM (підписати)
# і ClamAV (заражена машина абонента), але НЕ OpenDMARC і НЕ SpamAssassin.
# Повне обґрунтування — біля `submission_milters` у main.cf. `\$` тут
# екранований навмисно: у master.cf мусить лягти саме посилання на
# параметр, щоб значення лишалось в одному місці.
postconf -M submission/inet="submission inet n - n - - smtpd"
postconf -P \
    "submission/inet/syslog_name = postfix/submission" \
    "submission/inet/smtpd_tls_security_level = encrypt" \
    "submission/inet/smtpd_sasl_auth_enable = yes" \
    "submission/inet/smtpd_client_restrictions = permit_sasl_authenticated,reject" \
    "submission/inet/milter_macro_daemon_name = ORIGINATING" \
    "submission/inet/smtpd_milters = \$submission_milters"

# ── TLS ───────────────────────────────────────────────────────────────
# ЗАГЛУШКА, поки сертифікат не випущений. Без сертифіката `smtpd_tls_auth_only`
# означав би, що авторизуватись не може ніхто.
#
# Том tls-certs СПІЛЬНИЙ із dovecot, тож цей блок виконують обидва
# контейнери, і стартують вони майже одночасно. Тому генеруємо в
# тимчасові імена й ставимо на місце через `mv`: він атомарний у межах
# однієї ФС, отже другий контейнер або побачить готову пару файлів, або
# не побачить нічого — але ніколи напівзаписаний ключ. Без цього
# найпоширеніший симптом був би «іноді при старті сертифікат битий».
#
# Справжній сертифікат кладе сюди `mailctl certs` (TODO п.7), ПІД ТИМИ
# Ж іменами — certbot називає свої файли так само. Отже щойно він
# з'явиться, цей блок просто перестане спрацьовувати, а конфіги не
# змінюються взагалі.
if [ ! -s "$TLS_DIR/privkey.pem" ] || [ ! -s "$TLS_DIR/fullchain.pem" ]; then
    mkdir -p "$TLS_DIR"
    echo "postfix-entrypoint: УВАГА — сертифіката немає, генерую" \
         "САМОПІДПИСАНИЙ для ${MAIL_HOSTNAME}. Клієнти побачать" \
         "попередження; нормально лише до `mailctl certs`." >&2
    tmp=$(mktemp -d "$TLS_DIR/.stub.XXXXXX") \
        || die "не можу створити тимчасову теку в $TLS_DIR"
    if openssl req -new -x509 -days 90 -nodes -newkey rsa:2048 \
        -subj "/CN=${MAIL_HOSTNAME}" \
        -addext "subjectAltName=DNS:${MAIL_HOSTNAME}" \
        -keyout "$tmp/privkey.pem" \
        -out    "$tmp/fullchain.pem" 2>/dev/null
    then
        chmod 600 "$tmp/privkey.pem"
        chmod 644 "$tmp/fullchain.pem"
        mv "$tmp/privkey.pem"   "$TLS_DIR/privkey.pem"
        mv "$tmp/fullchain.pem" "$TLS_DIR/fullchain.pem"
    else
        rm -rf "$tmp"
        die "не вдалось згенерувати самопідписаний сертифікат"
    fi
    rm -rf "$tmp"
fi

# ── Режим перевірки ───────────────────────────────────────────────────
# `docker run --rm ... mail/postfix:trixie check` друкує ефективний
# конфіг і виходить. Потрібен із тієї ж причини, що й у dovecot:
# зламаний конфіг кладе контейнер у restart-loop, і `docker exec` у
# нього вже не зайти. Викликається через `mailctl config <group> postfix`.
case "${1:-}" in
    '')      ;;
    check)
        # Спершу те, по що й приходили: ефективний конфіг.
        postconf -n || die "postconf незадоволений — див. вище"

        # А тепер `postfix check` — але вже БЕЗ перевірки адрес.
        #
        # Одноразовий контейнер не має зовнішніх адрес групи: вони
        # приходять із ipvlan-мережі, до якої підключений лише справжній
        # postfix. Тому `inet_interfaces = 203.0.113.82` тут завжди дає
        # `fatal: no local interface found`, і це не помилка конфігу, а
        # властивість самої перевірки. Решту `postfix check` робить
        # корисного (права, наявність файлів, мапи), тож залишаємо його,
        # підмінивши лише інтерфейси. Конфіг у контейнері все одно
        # одноразовий.
        echo "postfix-entrypoint: inet_interfaces підмінено на" \
             "loopback-only — в одноразовому контейнері адрес групи" \
             "немає, і перевірити їх тут неможливо в принципі" >&2
        postconf -e 'inet_interfaces = loopback-only'
        postfix check || die "postfix check незадоволений — див. вище"
        exit 0
        ;;
    *)  die "невідомий аргумент '$1'. Приймаємо лише 'check' або нічого";;
esac

postfix check || die "postfix check незадоволений — див. вище"

echo "postfix-entrypoint: exec postfix start-fg" >&2
exec postfix start-fg
