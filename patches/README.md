# Патчи zapret2

`001-tls-reasm-fastpath.patch` — итоговый diff ветки
[`Anonym-tsk/zapret2:tls-reasm-fastpath`](https://github.com/Anonym-tsk/zapret2/tree/tls-reasm-fastpath)
на коммите `88611a550078d338a02d4dd8e49277b9fde83fff` относительно `v1.0.7`.
Ветка опубликована в [PR #321](https://github.com/bol-van/zapret2/pull/321).
Она основана на [PR #303](https://github.com/bol-van/zapret2/pull/303), но содержит
исправленную и доработанную реализацию: выключенный по умолчанию режим
`--fastpath-workaround=0|1|auto`, глобальный autodetect, ACK-only placeholders для
всех незавершённых TLS-фрагментов, безопасный fallback по ретрансмиссии и исправления
обнаруженных ошибок работы с reassembly-буфером и пакетами.

Перед сборкой `.github/workflows/build-nfqws2.yml` определяет последний стабильный
релиз zapret2 через GitHub API `releases/latest` (без draft и prerelease).
Тег разрешается в commit один раз: все архитектуры собираются с этого SHA,
а в `ZAPRET_GH_VER` и `ZAPRET_GH_HASH` передаются тег релиза и SHA соответственно.
Патч проверен на `v1.0.7` (`038c97e5819df10f8e8c22a2f1fffe57f2f7379b`).
При выходе новой версии нужно проверять совместимость патча с исходниками
и учитывать изменения upstream-рецепта сборки. Проверка SHA-256 рецепта не
проверяет совместимость патча. Патчи применяются по имени файла с `--fuzz=0`;
ошибка применения останавливает сборку.

## Сборка

Release workflow сначала собирает семь Linux-архитектур по рецепту
[upstream](https://github.com/bol-van/zapret2/blob/v1.0.7/.github/workflows/build.yml):
те же toolchain, зависимости, флаги, Lua/LuaJIT и UPX 4.2.4
(без UPX для mips64). MIPS использует soft-float toolchain.
Lua-скрипты берутся из той же ревизии и сжимаются `pigz -11`, как в embedded-релизе.
Изменённые патчами бинарники, естественно, отличаются от upstream.
SHA-256 upstream `.github/workflows/build.yml` проверяется до запуска матрицы.
Если в новом стабильном релизе рецепт изменился, пайплайн останавливается:
сначала нужно сверить и обновить `build-nfqws2.yml`, затем ожидаемый SHA-256.

Артефакты `nfqws2-*` содержат tar.gz, сохраняющие права исполняемых файлов.
Entware и OpenWrt скачивают их в `out/nfqws2`; дальнейшая упаковка не меняется.
Для локальной упаковки скачайте семь tar.gz в `out/nfqws2`, затем на Linux
выполните `make entware` или сборку через OpenWrt SDK. Скачивания готовых
upstream-бинарников в Makefile больше нет.

Release workflow автоматически увеличивает версию из `VERSION`, использует её
для пакетов и релиза, затем коммитит обновлённый `VERSION` и создаёт тег.

Проверка передачи бинарников и Lua в пакеты без скачивания зависимостей:
`bash tests/test-packaging.sh` (Linux).
Release workflow запускает её в джобе `test-packaging` перед сборкой бинарников;
при ошибке теста дальнейшая сборка и публикация не запускаются.
