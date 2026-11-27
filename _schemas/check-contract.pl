#!/usr/bin/perl
# check-contract.pl — чи узгоджені SQL-запити конфігів зі схемою.
#
# ЧОМУ ЦЕ ІСНУЄ. Імена таблиць, подань і стовпців — контракт між схемою
# (_schemas/<варіант>/) і запитами, розсипаними по конфігах: Dovecot
# (passdb/userdb), entrypoint Postfix (virtual_* мапи), Roundcube
# (password, sauserprefs). Опечатка в імені стовпця не ловиться нічим:
# MariaDB дізнається про неї лише при виконанні запиту, тобто Dovecot
# падає при першому вході, а Postfix мовчки відмовляє в доставці.
#
# Перевірка статична й свідомо приблизна: вона знає про бектики й про
# «голі» ідентифікатори, вирізавши рядки в лапках і ключові слова SQL.
# Її мета — не замінити справжній сервер, а зловити опечатку до того, як
# схема поїде в mysql-init.
#
#   perl _schemas/check-contract.pl [варіант]      # дефолт mysql-mail

use strict;
use warnings;

my $root    = $0;
$root =~ s{/_schemas/[^/]+$}{};
$root = '.' if $root eq $0;
my $variant = shift // 'mysql-mail';
my $dir     = "$root/_schemas/$variant";
die "немає каталогу схеми: $dir\n" unless -d $dir;

# ── 1. що пропонує схема ──────────────────────────────────────────────

my (%cols, %kind);     # сутність -> { стовпець => 1 }, і таблиця/подання

for my $f (sort glob "$dir/*.sql") {
    local $/;
    open my $fh, '<', $f or die "не читається $f: $!\n";
    my $sql = <$fh>;
    close $fh;
    $sql =~ s/^\s*--[^\n]*$//mg;          # коментарі — там бувають приклади запитів

    # CREATE TABLE `t` ( ... )
    while ($sql =~ /CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?\s+`?(\w+)`?\s*\((.*?)\n\)/gis) {
        my ($t, $body) = ($1, $2);
        $kind{$t} = 'таблиця';
        # стовпець — перше слово рядка в бектиках; KEY/PRIMARY/UNIQUE пропускаємо
        for my $line (split /\n/, $body) {
            next if $line =~ /^\s*(PRIMARY|UNIQUE|KEY|INDEX|CONSTRAINT|FOREIGN)/i;
            $cols{$t}{$1} = 1 if $line =~ /^\s*`(\w+)`/;
        }
    }
    # CREATE [OR REPLACE] ... VIEW `v` AS SELECT ... ;
    while ($sql =~ /CREATE\s+(?:OR\s+REPLACE\s+)?(?:SQL\s+SECURITY\s+\w+\s+)?VIEW\s+`?(\w+)`?\s+AS\s+(.*?);/gis) {
        my ($v, $body) = ($1, $2);
        $kind{$v} = 'подання';
        # стовпці подання — псевдоніми AS `x`
        $cols{$v}{$1} = 1 while $body =~ /\bAS\s+`(\w+)`/gi;
    }
}

printf "СХЕМА %s\n", $variant;
for my $e (sort keys %cols) {
    printf "  %-14s %-9s %s\n", $e, $kind{$e},
        join(' ', sort keys %{ $cols{$e} });
}

# ── 2. запити з конфігів ──────────────────────────────────────────────

my @queries;   # [ файл, рядок, запит ]

sub slurp { local $/; open my $fh, '<', $_[0] or return ''; my $t = <$fh>; close $fh; $t }

# Dovecot: query = ... з продовженнями рядка
{
    my $f = "$root/_configs/dovecot/dovecot.conf";
    my @l = split /\n/, slurp($f);
    for my $i (0 .. $#l) {
        next unless $l[$i] =~ /^\s*(?:iterate_)?query\s*=\s*(.*)$/;
        my ($q, $j) = ($1, $i);
        while ($q =~ s/\\\s*$//) { $q .= ' ' . ($l[++$j] // '') }
        push @queries, [$f, $i + 1, $q];
    }
}
# Postfix: write_map <файл> "<запит>"
{
    my $f = "$root/_images/postfix/entrypoint.sh";
    my @l = split /\n/, slurp($f);
    for my $i (0 .. $#l) {
        next unless $l[$i] =~ /^\s*write_map\s+\S+\s*\\?\s*$/
                 || $l[$i] =~ /^\s*write_map\s+\S+\s+"/;
        my $blob = join ' ', @l[$i .. ($i + 2 > $#l ? $#l : $i + 2)];
        push @queries, [$f, $i + 1, $1] if $blob =~ /"(SELECT\s.*?)"/is;
    }
}
# Roundcube: будь-який рядок із SELECT/UPDATE у конфізі
{
    my $f = "$root/_configs/roundcube/config.inc.php";
    my @l = split /\n/, slurp($f);
    for my $i (0 .. $#l) {
        push @queries, [$f, $i + 1, $1]
            if $l[$i] =~ /["'](\s*(?:SELECT|UPDATE)\s+.*?)["']\s*;/i;
    }
}

# ── 3. звірка ─────────────────────────────────────────────────────────

my %kw = map { $_ => 1 } qw(
    select from where and or as on join left right inner outer update set
    insert into values concat coalesce nullif lower upper substring_index
    order by limit desc asc group having distinct case when then else end
    is not null like in exists count max min sum avg if ifnull now
    current_timestamp true false
);

my ($checked, $bad) = (0, 0);
print "\nЗАПИТИ\n";
for my $q (@queries) {
    my ($f, $ln, $sql) = @$q;
    (my $short = $f) =~ s{^\Q$root\E/}{};

    my $clean = $sql;
    $clean =~ s/'[^']*'/ /g;            # рядки-літерали: там %s і '%{user}'
    $clean =~ s/%\{[^}]*\}/ /g;         # змінні Dovecot
    $clean =~ s/\\//g;

    my @ent = $clean =~ /\b(?:FROM|UPDATE|JOIN)\s+`?(\w+)`?/gi;
    unless (@ent) { next }
    $checked++;

    my %known;
    my @unknown_ent;
    for my $e (@ent) {
        if ($cols{$e}) { %known = (%known, %{ $cols{$e} }) }
        else           { push @unknown_ent, $e }
    }

    # Псевдоніми результату (`... AS username`) — НЕ стовпці джерела, і
    # перевіряти їх проти схеми неправильно: саме так перша версія цієї
    # перевірки дала три фальшиві збої на валідних запитах Dovecot.
    my %alias = map { $_ => 1 } ($clean =~ /\bAS\s+`?(\w+)`?/gi);

    my @ids = $clean =~ /`(\w+)`/g;                       # у бектиках
    push @ids, grep { !$kw{ lc $_ } && !/^\d+$/ }
               ($clean =~ /\b([a-z][a-z0-9_]{2,})\b/g);   # голі
    my %seen;
    @ids = grep { !$seen{$_}++ && !$kw{ lc $_ } } @ids;
    # імена самих сутностей і псевдоніми — не стовпці джерела
    @ids = grep { !$kind{$_} && !$alias{$_} } @ids;

    my @miss = grep { !$known{$_} } @ids;

    if (@unknown_ent || @miss) {
        $bad++;
        print "  ЗБІЙ $short:$ln\n";
        print "      $sql\n";
        printf "      невідома сутність: %s\n", join(', ', @unknown_ent) if @unknown_ent;
        printf "      немає в схемі: %s\n", join(', ', @miss) if @miss;
        printf "      є: %s\n", join(' ', sort keys %known) if %known && @miss;
    }
    else {
        printf "  ok   %-46s %s\n", "$short:$ln",
               join('+', map { "$_(" . scalar(keys %{ $cols{$_} }) . ")" } @ent);
    }
}

printf "\nперевірено запитів: %d, зі збоями: %d\n", $checked, $bad;
exit($bad ? 1 : 0);
