-- ─────────────────────────────────────────────────────────────
--  Схема поштової БД: варіант MySQL/MariaDB, база `mail`.
--
--  ЦЕ НЕ ЄДИНА СХЕМА В ПРОЄКТІ. Групи можуть відрізнятись і СУБД, і
--  структурою: частина прод-серверів історично на PostgreSQL з іншим
--  підходом. Тому схеми лежать у _schemas/<варіант>/, а група вибирає
--  свій через DB_SCHEMA у group.env. Не додавати сюди нічого, що
--  специфічне для однієї групи — це спільний варіант, не її конфіг.
--
--  Знята з чинної прод-конфігурації (MariaDB 10.11) і збережена
--  СТРУКТУРНО БЕЗ ЗМІН: ті самі таблиці, стовпці й подання, що на
--  живому сервері. Це прямий наслідок рішення "переносимо
--  користувачів і скриньки як є" — будь-яке перейменування тут
--  означало б переписувати ще й усі запити в main.cf і dovecot.conf,
--  тобто міняти дві речі замість однієї.
--
--  Змінено рівно три речі, кожна з причиною:
--   1. utf8mb3 -> utf8mb4. utf8mb3 у MariaDB застарілий; дані тут
--      ASCII, тож конверсія безпечна.
--   2. З подань прибрано DEFINER=`mail`@`localhost` і поставлено
--      SQL SECURITY INVOKER. З DEFINER-ом дамп не імпортується у
--      свіжий контейнер: користувача `mail`@`localhost` там немає, і
--      SELECT з подання падає з "The user specified as a definer does
--      not exist".
--   3. users.domain втратив DEFAULT 'small.example.org' — конкретна
--      установка не має протікати у спільний шаблон. Усі INSERT
--      однаково передають домен явно.
--   5. Додано users.login — короткий логін, не пов'язаний з адресою
--      (рішення №15). Без нього більшість користувачів isp і office
--      не змогла б зайти: там автентифікація історично коротким
--      логіном, і з адресою він не збігається у 447 випадках із 568.
--   6. users.home став NULLABLE і без DEFAULT '/var/mail/dummy': NULL
--      означає «за конвенцією», заповнений — «саме цей шлях». Це те,
--      що дозволяє перенести тризівневу розкладку isp як є.
--   4. usersdb.userdb_home тепер ОБЧИСЛЮЄТЬСЯ з домену й логіна, а не
--      віддає стовпець users.home. Рішення №8: Dovecot бере home
--      готовим із в'ю. Причина — мета проєкту: з обчисленим home
--      «додати користувача» лишається одним INSERT, а зі стовпцем
--      довелося б ще й правильно заповнити шлях, тобто з'явилась би
--      можливість тихо помилитись (дефолт там, до речі,
--      '/var/mail/dummy'). Сам стовпець лишається — він потрібен при
--      міграції, щоб звірити фактичні шляхи з конвенцією, див. нижче.
--
--  Виконується автоматично при ПЕРШОМУ старті контейнера MySQL
--  (порожній datadir). Зміни у вже наповненій БД цей файл НЕ
--  застосує — тільки вручну.
-- ─────────────────────────────────────────────────────────────

-- ── Домени, які цей сервер обслуговує ──
-- type: LOCAL — доставляємо локально; RELAY — переправляємо далі;
-- VIRTUAL — віртуальні. На проді зараз усі LOCAL.
CREATE TABLE IF NOT EXISTS `domains` (
  `id`            bigint(21)   NOT NULL AUTO_INCREMENT,
  `last_modified` timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `domain`        varchar(128) NOT NULL DEFAULT '',
  `type`          enum('LOCAL','RELAY','VIRTUAL') DEFAULT 'LOCAL',
  PRIMARY KEY (`id`),
  KEY `domain` (`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Поштові скриньки ──
-- passwd зберігає хеш зі схемою у фігурних дужках ({CRAM-MD5}...,
-- {BLF-CRYPT}..., {ARGON2ID}...) — формат Dovecot.
-- Порівняння хешів має бути регістрозалежним, звідси _bin на стовпці.
-- home — абсолютний шлях до скриньки, ЯК ВІН ЗАПИСАНИЙ НА ДЖЕРЕЛІ.
-- Dovecot його НЕ читає: подання usersdb віддає обчислений шлях
-- (див. зміну №4 у шапці). Стовпець лишається як матеріал для звірки
-- при міграції — запит під поданням usersdb.
CREATE TABLE IF NOT EXISTS `users` (
  `id`            bigint(21) unsigned NOT NULL AUTO_INCREMENT,
  `last_modified` timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `user`          varchar(64)  NOT NULL DEFAULT '',
  `domain`        varchar(128) NOT NULL,
  -- Короткий логін (рішення №15). NULL означає "входити лише за повною
  -- адресою" — так буде в групах small-типу, де логін і є email.
  -- Два прод-сервери з трьох автентифікують КОРОТКИМ логіном, не
  -- пов'язаним з адресою: на isp 240 із 312, на office 207 із 247 не
  -- збігаються з локальною частиною. Без цього стовпця більшість
  -- користувачів просто не змогла б зайти.
  --
  -- UNIQUE глобальний, а не на (login, domain): логін без домену і
  -- вводиться без домену, тож двох однакових у БД бути не може — інакше
  -- Dovecot не знав би, чий пароль перевіряти. На джерелах так і є:
  -- логіни унікальні глобально в обох випадках (звірено з дампами).
  `login`         varchar(64)  DEFAULT NULL,
  `passwd`        varchar(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL
                  COMMENT 'хеш зі схемою Dovecot у фігурних дужках',
  -- АБСОЛЮТНИЙ шлях до Maildir, або NULL.
  --
  -- NULL (норма для нових користувачів) означає "обчислити за
  -- конвенцією" — /var/mail/<домен>/<локальна частина>, див. усersdb.
  -- Так "додати користувача" лишається одним INSERT, без можливості
  -- тихо помилитись у шляху (рішення №8).
  --
  -- Заповнюється лише там, де скринька лежить НЕ за конвенцією.
  --
  -- ТУТ РАНІШЕ СТОЯЛО, що це випадок isp: мовляв його тришарову
  -- розкладку (/var/mail/<домен>/<локальна частина>/<логін>) переносимо
  -- ЯК Є, а на сервері співіснуватимуть дві розкладки.
  -- РІШЕННЯ ВЛАСНИКА (2026-11-18) ПРОТИЛЕЖНЕ: переносимо лише й
  -- виключно за уніфікованою схемою, не зберігаючи розкладку джерела.
  -- Отже isp міграється з `home` = NULL, як і решта, а пошта
  -- копіюється ОДРАЗУ в кінцеву розкладку: rsync іде ПО СКРИНЬКАХ
  -- (`<логін>/` джерела -> `<localpart>/` цілі), тож окремого
  -- переукладання не існує як кроку (фаза 2 карти isp).
  --
  -- Причина не стильова. Шлях, що містить `login`, прив'язує скриньку
  -- на диску до значення, яке може змінитись: зміна логіна
  -- перетворила б робочу скриньку на порожню. Конвенція з localpart
  -- такої залежності не має, а localpart уже є частиною адреси.
  -- Безпечність переукладання перевірена на даних: домену, де два
  -- користувачі мали б однаковий localpart, немає ні одного, тож
  -- злиття двох скриньок в одну неможливе.
  `home`          varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
  `quota`         int(10) unsigned DEFAULT 300,
  `active`        enum('Y','N') DEFAULT 'Y',
  `comment`       tinytext DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `eaddress` (`user`,`domain`),
  UNIQUE KEY `login`    (`login`),
  KEY `user` (`user`),
  KEY `domain` (`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Аліаси ──
-- recipients — список отримувачів через кому, як його очікує
-- virtual_alias_maps у Postfix.
CREATE TABLE IF NOT EXISTS `aliases` (
  `id`            bigint(21)   NOT NULL AUTO_INCREMENT,
  `last_modified` timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `local_part`    varchar(64)  NOT NULL DEFAULT '',
  `domain`        varchar(128) NOT NULL DEFAULT '',
  `recipients`    text         DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `local_part` (`local_part`,`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Пересилання для конкретної скриньки ──
-- На проді зараз порожня, але схему тримаємо — механізм існує.
CREATE TABLE IF NOT EXISTS `userforward` (
  `id`         bigint(21)   NOT NULL AUTO_INCREMENT,
  `local_part` varchar(64)  NOT NULL DEFAULT '',
  `domain`     varchar(128) NOT NULL DEFAULT '',
  `recipients` text         DEFAULT NULL,
  `COMMENT`    tinytext     DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `local_part` (`local_part`,`domain`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── `domains_relay` ПРИБРАНА СВІДОМО (рішення №39) ──
-- Вона була в прод-дампі, порожня, і означала те саме, що `type='RELAY'`
-- у таблиці `domains` вище: домени, для яких ми резервний MX, а не
-- кінцева точка. Два місця з однаковим змістом — це рівно той клас, що
-- дає тихий розхід: домен, вставлений не в ту таблицю, не діє, і ніде
-- про це не сказано. Гірше: домен, що потрапив в ОБИДВІ, зробив би нас
-- одночасно кінцевою точкою й релеєм для себе, а Postfix дивиться
-- virtual_mailbox_domains першим — тобто релейний рядок став би мертвим
-- мовчки.
-- Тепер джерело одне: `domains.type`, тобто ОДИН стовпець, де LOCAL і
-- RELAY взаємно виключні за побудовою. Читає його
-- /etc/postfix/sql/relay_domains.cf, наповнює `mailctl domain add
-- <група> <домен> --type=RELAY`.
-- На групах, піднятих до цієї правки, порожня таблиця лишилась у базі.
-- Чіпати її не потрібно: її ніхто не читає.

-- ── Кому дозволено релеїти за IP/іменем ──
-- Живить mynetworks / check_client_access у Postfix.
-- УВАГА при переносі: у контейнері з ipvlan Postfix бачить справжню
-- IP клієнта (NAT-у немає), тому записи лишаються осмисленими. Але
-- 127.0.0.1 і localhost тепер означають "всередині netns групи",
-- тобто ще й Dovecot з Roundcube. Це той самий trust domain, але
-- знати про це треба.
CREATE TABLE IF NOT EXISTS `relay_from_hosts` (
  `id`            bigint(21)   NOT NULL AUTO_INCREMENT,
  `last_modified` timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `host`          varchar(128) NOT NULL DEFAULT '',
  `comment`       text         NOT NULL,
  PRIMARY KEY (`id`),
  KEY `host` (`host`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Релей за парою відправник/отримувач ──
CREATE TABLE IF NOT EXISTS `relay_from_sender` (
  `id`            bigint(21)   NOT NULL AUTO_INCREMENT,
  `last_modified` timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `host`          varchar(128) DEFAULT NULL,
  `sender`        varchar(128) NOT NULL DEFAULT '',
  `receiver`      varchar(128) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `host` (`host`),
  KEY `sender` (`sender`),
  KEY `receiver` (`receiver`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Політика за доменом ОТРИМУВАЧА (рішення №19) ──
-- ЦЬОГО НА ПРОДІ НЕМАЄ. Там та сама функція зроблена транспортом
-- `discard:silently` на 297 доменів, і має два дефекти: 296 записів
-- мають провідну крапку (тобто блокують лише ПІДДОМЕНИ, а сам домен —
-- ні, хоч задум був протилежний), і всі 297 через
-- `relay_domains = $transport_maps` потрапляють у список доменів, для
-- яких сервер оголошує себе релеєм.
--
-- `include_subdomains` замінює ту саму провідну крапку, але явно й в
-- обидва боки: домен сам по собі, піддомени — за прапорцем.
--
-- `source` обов'язковий, і не для краси: історичні записи й
-- імпортований список (cip.gov.ua, 50+ тис. доменів, що оновлюється)
-- мусять жити поряд, не затираючи один одного. Імпорт — синхронізація
-- В МЕЖАХ source: додати нові, прибрати зниклі, чужих не чіпати.
--
-- `action` на РЯДОК, а не на таблицю: у різних джерел політика може
-- відрізнятись, і це поле, а не ще одна таблиця.
--
-- ДЕФОЛТ — REJECT, і це ВИПРАВЛЕННЯ. Спершу тут стояв `DISCARD`,
-- «бо історичні 297 записів isp можуть лишитись як є». Критерій,
-- яким це перевіряється, у тому ж рішенні №19 третім пунктом: мовчки
-- з'їдений лист не діагностується ні абонентом, ні адміном. А хто
-- саме отримує відмову — видно з місця перевірки: вона стоїть ВИЩЕ
-- `permit_mynetworks`, тобто блокує насамперед ВИХІДНУ пошту
-- абонентів. Відправник тут наш власний, до нього можна дотягнутись і
-- він може спитати, що сталось — рівно той випадок, де REJECT
-- правильний. DISCARD виправданий лише проти ворожого чи підробленого
-- відправника, і до абонента це не стосується.
--
-- Дефолт колонки взагалі діє лише на голий `INSERT` руками (mailctl
-- завжди передає action явно), і саме тому він мусить бути безпечним:
-- «втрата листа за замовчуванням» — найгірше, що можна тут поставити.
--
-- varchar(255), а не text: це PRIMARY KEY, і саме по ньому б'є запит
-- із main.cf. Пошук там іде ГЕНЕРАЦІЄЮ КАНДИДАТІВ (домен, потім його
-- суфікси), а не LIKE — інакше кожен RCPT давав би повний скан
-- 50 тисяч рядків.
CREATE TABLE IF NOT EXISTS `recipient_policy` (
  `domain`             varchar(255) NOT NULL,
  `include_subdomains` tinyint(1)   NOT NULL DEFAULT 1,
  `action`             varchar(255) NOT NULL
      DEFAULT 'REJECT recipient domain blocked by local policy',
  `source`             varchar(64)  NOT NULL DEFAULT 'local',
  `comment`            text         DEFAULT NULL,
  `updated_at`         timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`domain`),
  KEY `source` (`source`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── abuse_block: тимчасові блокування з терміном дії (рішення №20) ──
--
-- ЧОГО ЦЕ КОМПЕНСАЦІЯ. На isp-подібній групі `mynetworks` широкий
-- НАВМИСНО: усі абоненти провайдера мусять могти відправляти через
-- його SMTP без авторизації (рішення №20), а на office те саме
-- стосується офісної мережі (рішення №30). Звужувати це не можна —
-- вимога власника. Отже компенсацією є не звуження довіри, а
-- можливість вийняти з неї конкретного порушника на конкретний час.
--
-- ДВА SCOPE В ОДНІЙ ТАБЛИЦІ, бо це дві сторони одного інциденту:
--   client — заражена машина (ключ: IP або його префікс);
--   sender — скомпрометований акаунт (ключ: адреса або домен).
-- Окремі таблиці означали б дві схеми, дві команди й два місця, де
-- щось можна забути; різниця між ними — рівно значення одного поля.
--
-- КЛЮЧІ ПІДСТАВЛЯЄ САМ POSTFIX, і тому запит тривіальний:
-- `check_client_access` послідовно пробує `a.b.c.d`, `a.b.c`, `a.b`,
-- `a` — звідси /32, /24, /16, /8 без жодних inet-кастів і без
-- арифметики підмереж; `check_sender_access` — повну адресу, потім
-- домен. Тобто таблиця тримає рядки, а не маски, і пошук б'є по
-- PRIMARY KEY.
--
-- `block_key`, А НЕ `key`. У рішенні №20 стовпець названий `key`, і це
-- РЕЗЕРВОВАНЕ слово MariaDB: воно вимагало б бектиків усюди, включно з
-- запитом усередині heredoc-а в entrypoint — а бектик у неквотованому
-- heredoc у цьому проєкті вже тричі виконався як команда (PITFALLS).
-- Задум рішення це не змінює, лише ім'я.
--
-- `expires_at` — `datetime`, А НЕ `timestamp`, і це не стиль.
-- При `explicit_defaults_for_timestamp = OFF` MariaDB дає ПЕРШОМУ
-- стовпцю TIMESTAMP без явного дефолту одразу
-- `DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP`. Тобто будь-яке
-- оновлення рядка (виправили `reason`) переставило б термін дії на
-- «щойно», і блокування мовчки скінчилось би в ту ж секунду. `datetime`
-- такої автоматики не має взагалі.
--
-- `added_at` лишається `timestamp`, бо дефолт у нього ЯВНИЙ — а явний
-- `DEFAULT CURRENT_TIMESTAMP` без `ON UPDATE` тієї автоматики не тягне.
--
-- ДЕФОЛТ `action` — REJECT із текстом. Те саме правило, що в
-- `recipient_policy`: дефолт стовпця, який керує долею листа, мусить
-- лишати слід. REJECT відмовляє в живій сесії, тобто відправник (а це
-- наш власний абонент) бачить причину й може спитати; DISCARD з'їв би
-- лист мовчки.
--
-- `OK`/`PERMIT` у цій таблиці не має бути НІКОЛИ: рядок із таким
-- action перетворює її на білий список, який коротко замикає всі
-- наступні перевірки в тому ж списку обмежень. `mailctl block` їх не
-- дає вставити.
--
-- РОЗБЛОКУВАННЯ ЯК ОПЕРАЦІЇ НЕ ІСНУЄ: рядок просто перестає
-- матчитись, бо запит має `expires_at > NOW()`. Четвертої ручної
-- операції (рішення №20) через це не з'являється. `block del` існує
-- для іншого випадку — заблокували не те, і чекати не можна.
--
-- Прострочені рядки лишаються в таблиці свідомо: це єдина історія
-- інцидентів, яка в нас є, і коштує вона байтів.
CREATE TABLE IF NOT EXISTS `abuse_block` (
  `scope`      varchar(16)  NOT NULL,
  `block_key`  varchar(255) NOT NULL,
  `action`     varchar(255) NOT NULL
      DEFAULT 'REJECT temporarily blocked for abuse',
  `reason`     text         DEFAULT NULL,
  `expires_at` datetime     NOT NULL,
  `added_by`   varchar(64)  DEFAULT NULL,
  `added_at`   timestamp    NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`scope`, `block_key`),
  KEY `expires_at` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- ── Подання, до яких ходять Postfix і Dovecot ──
-- Саме вони, а не таблиці, є контрактом: user тут — повний email,
-- тобто логін = адреса. Неактивні скриньки з usersdb зникають, і
-- автентифікація для них просто не знаходить запису.
--
-- SQL SECURITY INVOKER: права перевіряються за тим, хто робить SELECT.
-- Отже поштовому користувачеві БД потрібен SELECT і на базові
-- таблиці, не лише на подання. З DEFINER було б навпаки, але DEFINER
-- прив'язує подання до конкретного облікового запису MySQL, якого у
-- свіжому контейнері немає.

CREATE OR REPLACE
  SQL SECURITY INVOKER
  VIEW `usersdb` AS
    SELECT CONCAT(`users`.`user`, '@', `users`.`domain`) AS `user`,
           -- Фолбек на email навмисно: тоді запит Dovecot
           -- (user = ? OR login = ?) працює однаково в групах, де
           -- короткого логіна немає, і стовпець можна не заповнювати.
           COALESCE(NULLIF(`users`.`login`, ''),
                    CONCAT(`users`.`user`, '@', `users`.`domain`))
                                                         AS `login`,
           `users`.`domain`                              AS `domain`,
           `users`.`passwd`                              AS `password`,
           -- Стовпець home перебиває конвенцію, якщо заповнений: саме
           -- так переноситься тризівнева розкладка isp. Порожній
           -- рядок дорівнює NULL — на джерелах трапляється і те, і те.
           COALESCE(NULLIF(`users`.`home`, ''),
                    CONCAT('/var/mail/', `users`.`domain`, '/',
                           `users`.`user`))              AS `userdb_home`
      FROM `users`
     WHERE `users`.`active` = 'Y';

-- ── Перевірки при міграції ──
--
-- 1. ХТО ЛЕЖИТЬ НЕ ЗА КОНВЕНЦІЄЮ. Таким потрібен заповнений home:
--
--   SELECT CONCAT(`user`,'@',`domain`) AS email, `home`
--     FROM `users`
--    WHERE `home` IS NOT NULL AND `home` <> ''
--      AND `home` <> CONCAT('/var/mail/',`domain`,'/',`user`);
--
-- На isp це будуть усі 312: шлях там тризівневий
-- (/var/mail/<домен>/<локальна частина>/<логін>). Переносимо як є —
-- обґрунтування в коментарі до стовпця home вище.
--
-- 2. КОЛІЗІЯ КОРОТКОГО ЛОГІНА З ЧУЖОЮ АДРЕСОЮ. Знайдено на office, і
-- це не теорія: там login='office' належить скриньці account@, а
-- скринька office@ має логін 'ofice' (опечатка при створенні). Поки вхід
-- лише за логіном, шлях до скриньки один. Щойно додається вхід за
-- повною адресою (рішення №15), власник логіна 'office' уводить
-- office@<домен> — природно для нього — і потрапляє в ЧУЖИЙ рядок.
-- Пароль не зійдеться, тож це буде «пароль раптом не підходить» без
-- видимої причини; при випадково однакових паролях — вхід у чужу
-- скриньку.
--
--   SELECT u.`login`, CONCAT(u.`user`,'@',u.`domain`) AS його_скринька,
--          CONCAT(v.`user`,'@',v.`domain`)            AS чужа_скринька
--     FROM `users` u
--     JOIN `users` v ON v.`user` = u.`login` AND v.`id` <> u.`id`
--    WHERE u.`login` IS NOT NULL;
--
-- Конвертор мусить це ловити й ЗУПИНЯТИСЬ: це дані, і рішення щодо них
-- за власником — виправити логін однієї зі скриньок (ламає налаштований
-- клієнт) або лишити як є, знаючи про наслідок.

CREATE OR REPLACE
  SQL SECURITY INVOKER
  VIEW `aliasesview` AS
    SELECT CONCAT(`aliases`.`local_part`, '@', `aliases`.`domain`) AS `alias`,
           `aliases`.`recipients`                                  AS `email`
      FROM `aliases`;
