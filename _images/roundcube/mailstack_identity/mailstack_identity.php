<?php

/**
 * mailstack_identity — дефолтна ідентичність із ПОШТОВОЇ бази.
 *
 * Навіщо. Roundcube будує адресу першої ідентичності як
 * <логін>@<IMAP-хост>, коли логін не схожий на адресу. У групах
 * small-типу логін і є адресою, тож це непомітно. На isp і office
 * логін короткий (рішення №15: 240 із 312 і 207 із 247 не збігаються
 * з локальною частиною), і результат — `eml_user@mail.isp.example.net`:
 * адреса НЕДОСТАВНА, бо mydestination у нас порожній, а імені вузла
 * немає у virtual_mailbox_domains. Тобто лист із вебмейлу йшов би з
 * From:, на який не можна відповісти.
 *
 * Чому власний плагін, а не налаштування.
 *   - `virtuser_query`, який робив саме це, з Roundcube ПРИБРАНИЙ —
 *     у 1.7 його немає ні в defaults.inc.php, ні в коді (звірено з
 *     release-1.7, а не з пам'яті);
 *   - `mail_domain` не годиться вдвічі: він додає домен до логіна,
 *     тобто виправив би тільки праву частину, а в нас не збігається й
 *     ліва; і задається він на ХОСТ, а в групі доменів кілька;
 *   - пакетний `new_user_identity` робить рівно те, що треба, але
 *     ходить у LDAP, якого в нас немає.
 *
 * Межі. Хук `user_create` спрацьовує РІВНО ОДИН РАЗ — при першому
 * вході, коли Roundcube заводить запис користувача. Вже створену
 * ідентичність він не чіпає, і це правильно: користувач міг виправити
 * її руками.
 */
class mailstack_identity extends rcube_plugin
{
    // Як і в пакетному new_user_identity: плагін потрібен лише на
    // вході, і завантажувати його в решті задач нема за чим.
    public $task = 'login';

    public function init()
    {
        $this->add_hook('user_create', [$this, 'lookup']);
    }

    /**
     * Хук 'user_create'. $args['user'] — логін, ЯК ЙОГО НАБРАЛИ:
     * Roundcube його не нормалізує, тож це або короткий логін, або
     * повна адреса (рішення №15 дозволяє обидва ключі).
     */
    public function lookup($args)
    {
        $rc  = rcmail::get_instance();
        $dsn = $rc->config->get('mailstack_identity_dsn');
        $sql = $rc->config->get('mailstack_identity_query');

        // Без налаштувань плагін не робить нічого — поведінка рівно
        // та, що була б без нього. Це важливо: група, яка його не
        // налаштувала, має працювати, а не падати на вході.
        if (empty($dsn) || empty($sql)) {
            return $args;
        }

        // Окреме з'єднання, а не get_dbh(): основний користувач БД
        // вебмейлу до поштової бази доступу не має взагалі (рішення
        // №35), і давати його заради однієї адреси означало б
        // відкрити йому ж таблицю з хешами.
        $db = rcube_db::factory($dsn, '', false);
        $db->set_debug((bool) $rc->config->get('sql_debug'));

        if ($db->is_error()) {
            rcube::write_log('errors', 'mailstack_identity: немає зв\'язку '
                . 'з поштовою базою, ідентичність лишається дефолтною');
            return $args;
        }

        $login = (string) $args['user'];
        $res   = $db->query($sql, $login, $login);

        if ($db->is_error($res)) {
            rcube::write_log('errors', 'mailstack_identity: запит не '
                . 'виконався: ' . $db->is_error($res));
            return $args;
        }

        $emails = [];
        while ($row = $db->fetch_array($res)) {
            $addr = trim((string) $row[0]);
            // strpos, а не просто непорожність: рядок без '@' як
            // адреса гірший за відсутність рядка — він виглядав би
            // правильним у налаштуваннях.
            if (strpos($addr, '@')) {
                $emails[] = rcube_utils::idn_to_ascii($addr);
            }
        }

        if (!$emails) {
            // Не мовчимо: порожній результат означає або логін, якого
            // немає в users, або розійдений запит — і те, й те видно
            // лише тут, бо далі Roundcube просто візьме свій дефолт.
            rcube::write_log('errors', "mailstack_identity: для логіна "
                . "'{$login}' адреси в поштовій базі не знайдено");
            return $args;
        }

        $emails = array_values(array_unique($emails));

        $args['user_email'] = $emails[0];
        $args['email_list'] = $emails;

        return $args;
    }
}
