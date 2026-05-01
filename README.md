# koha-db-autoincrement-fix

Audit and clean up primary-key collisions between Koha's live tables and
their `deleted*` / `old_*` counterparts. This is the data-side companion
to the [KohaAloha/koha-mysql-init][koha-aloha] `AUTO_INCREMENT` fix.

[koha-aloha]: https://github.com/KohaAloha/koha-mysql-init

## What problem does this solve?

Koha's `about.pl` may report under **System information > Data problems**:

> The following IDs exist in both tables `biblio` and `deletedbiblio`: 3278
> The following IDs exist in both tables `biblioitems` and `deletedbiblioitems`: 3278
> The following IDs exist in both tables `items` and `deleteditems`: 8545, 8546

These collisions occur because, on older MariaDB / MySQL versions, InnoDB
does not persist `AUTO_INCREMENT` across server restarts. After a restart
the counter is reset to `MAX(id) + 1` of the live table only, ignoring the
deleted/old counterpart, so the next insert can re-use an ID that already
exists in the archive table. See the canonical wiki page:

<https://wiki.koha-community.org/wiki/DBMS_auto_increment_fix>

The community-recommended permanent fix is the
[KohaAloha/koha-mysql-init][koha-aloha] systemd unit, which bumps
`AUTO_INCREMENT` past `GREATEST(MAX(live), MAX(deleted/old))` on every
database restart. That fix prevents future collisions but does not clean
up existing ones. This script handles the cleanup.

## What this script does

For a given Koha instance:

1. Reports collisions between the five wiki-listed table pairs:
   - `borrowers` vs `deletedborrowers`
   - `biblio` vs `deletedbiblio`
   - `biblioitems` vs `deletedbiblioitems`
   - `items` vs `deleteditems`
   - `issues` vs `old_issues`
   - `reserves` vs `old_reserves`
2. When called with `--delete=yes`:
   - Dumps the colliding rows from the deleted/old tables to a timestamped
     SQL file in the current directory (INSERT statements, replayable).
   - Then deletes those rows from the deleted/old tables.
3. Reports the status of the KohaAloha `AUTO_INCREMENT` fix and tells the
   operator what to do next (install it, enable the service, or restart
   the database, depending on what is found).

## Why dump first, then delete?

The Koha wiki's *Dealing with corrupted data* section currently advises
deleting matching rows from `deleted*` / `old_*` tables, but [Bug 19016][bz19016]
and [Bug 20271][bz20271] are still open and a community-blessed cleanup
script does not yet exist. The dump-first approach gives an immediate,
replayable rollback path if the deletion turns out to have been wrong for
a given site's history.

[bz19016]: https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=19016
[bz20271]: https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=20271

## Requirements

- A Koha Debian-package install (uses `koha-list`, `koha-mysql`).
- `mysqldump` available on `$PATH`.
- Read access to `/etc/mysql/koha-common.cnf` (the same file `koha-mysql`
  uses). Typically run as `root` or via `sudo`.

## Installation

```sh
git clone https://github.com/l2c2technologies/koha-db-autoincrement-fix
cd koha-db-autoincrement-fix
chmod +x koha-db-autoincrement-fix.sh
sudo cp koha-db-autoincrement-fix.sh /usr/local/sbin/
```

Or run it in place from the cloned directory.

## Usage

### Audit only (default, read-only)

```sh
sudo ./koha-db-autoincrement-fix.sh <instance>
```

Example output when collisions are present:

```
=== Instance: kohadev ===
Table          Deleted/old counterpart  IDs in both tables
----------------------------------------------------------------------------
borrowers      deletedborrowers         none
biblio         deletedbiblio            1: 3278
biblioitems    deletedbiblioitems       1: 3278
items          deleteditems             2: 8545,8546
issues         old_issues               none
reserves       old_reserves             none

4 collision(s) reported above.
Re-run with --delete=yes to dump and remove them.

=== auto_increment fix status ===
KohaAloha auto_increment fix is installed.
koha-mysql-init.service is enabled.

Restart the database to run the fix and bump AUTO_INCREMENT past MAX:
  sudo systemctl restart mariadb

Then verify with:
  sudo journalctl -u koha-mysql-init.service -n 20
```

### Dump and delete

```sh
sudo ./koha-db-autoincrement-fix.sh <instance> --delete=yes
```

This writes `./<instance>_collisions_<YYYYMMDD-HHMMSS>.sql` containing the
colliding rows (with the replay command in a header comment), then issues
`DELETE FROM <archive_table> WHERE <pk> IN (...)` for each pair.

### Rollback

The dump file contains complete INSERT statements with `SET
FOREIGN_KEY_CHECKS=0` at the top. To restore:

```sh
sudo koha-mysql <instance> < ./<instance>_collisions_<YYYYMMDD-HHMMSS>.sql
```

## Recommended workflow for a site showing the warning

1. Run `koha-db-autoincrement-fix.sh <instance>` and confirm the IDs match
   what `about.pl` reports.
2. Install [KohaAloha/koha-mysql-init][koha-aloha] if the script's status
   block says it is missing. The script prints the exact install commands.
3. Run `koha-db-autoincrement-fix.sh <instance> --delete=yes` to dump and
   remove the existing duplicates.
4. `sudo systemctl restart mariadb` (or `mysql`) to let the KohaAloha
   service bump `AUTO_INCREMENT` past the new `MAX(...)` on every covered
   table.
5. Re-run `koha-db-autoincrement-fix.sh <instance>` to confirm zero
   collisions remain. Reload `about.pl`. The data problems warning should
   be gone.

For a fleet of instances, wrap step 3 in a loop:

```sh
for k in $(koha-list); do
    sudo /usr/local/sbin/koha-db-autoincrement-fix.sh "$k" --delete=yes
done
```

Dumps land in the current working directory, prefixed with the instance
name, so they do not collide.

## Caveats

- The script assumes the KohaAloha `koha-mysql-init.service` will run on
  the next database restart. If you run a custom `init-file=` path or the
  per-instance variant from the wiki, the status check will report "not
  installed". That is a false negative for non-standard installs and the
  fix may already be in place via your own configuration. Read the status
  block as advisory.
- Modern MariaDB (>= 10.2.4) and MySQL (>= 8.0) persist `AUTO_INCREMENT`
  across restarts, so the underlying bug does not occur on those versions.
  If you see collisions on a modern DBMS, the cause is almost certainly
  manual database edits, a partial restore, or power-loss corruption, not
  the historical InnoDB bug. The cleanup half of this script is still
  useful, but the KohaAloha prevention layer is not strictly required.

## License

Released under the GNU General Public License, version 3 or later (same
as Koha itself). See the `LICENSE` file.

## Author

L2C2 Technologies. <https://l2c2.co.in>

## See also

- [DBMS auto_increment fix (Koha wiki)](https://wiki.koha-community.org/wiki/DBMS_auto_increment_fix)
- [KohaAloha/koha-mysql-init](https://github.com/KohaAloha/koha-mysql-init)
- Koha bug [18966](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=18966)
- Koha bug [19016](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=19016)
- Koha bug [20271](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=20271)
