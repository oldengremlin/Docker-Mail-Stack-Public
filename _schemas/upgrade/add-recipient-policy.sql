-- Додає recipient_policy (рішення №19) до ВЖЕ ЗАПУЩЕНОЇ групи.
--
-- Навіщо окремий файл: _schemas/.../01-schema.sql виконується лише при
-- ПЕРШОМУ старті MariaDB. На групі з живою поштою том знести не можна,
-- тож нова таблиця мусить доїхати окремо.
--
-- ПОРЯДОК ЗАСТОСУВАННЯ БІЛЬШЕ НЕ КРИТИЧНИЙ, і це свідома зміна
-- конструкції. Спершу мапа була підключена в main.cf напряму, тож
-- reload без цього файла означав 451 на КОЖЕН RCPT: SQL-lookup до
-- неіснуючої таблиці Postfix вважає збоєм ПЕРЕВІРКИ, а не «немає
-- збігу». Тобто вся пошта групи переставала прийматись.
--
-- Тепер мапу підключає entrypoint і лише після того, як сам її
-- опитає. Без таблиці блокування просто не діє — `mailctl health`
-- показує це як ЗБІЙ, пошта при цьому ходить. Після заливки
-- потрібен `mailctl reload <група> postfix`, щоб entrypoint
-- перепитав мапу й підключив її.
--
--   ./mailctl db-load <група> _schemas/upgrade/add-recipient-policy.sql
--
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

-- Таблиця могла бути створена ДО того, як дефолт виправили з DISCARD
-- на REJECT — на small саме так і є. CREATE TABLE IF NOT EXISTS
-- наявну таблицю не чіпає, тож дефолт правиться окремим ALTER.
--
-- Ідемпотентно: повторний запуск просто ставить те саме значення.
-- Рядків це не змінює взагалі — дефолт діє лише на нові INSERT без
-- явного action, тобто на голий SQL руками.
ALTER TABLE `recipient_policy`
  ALTER COLUMN `action`
  SET DEFAULT 'REJECT recipient domain blocked by local policy';
