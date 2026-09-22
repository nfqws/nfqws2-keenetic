# Патчи zapret2

`001-tls-reasm-fastpath.patch` — оба коммита [PR #303](https://github.com/bol-van/zapret2/pull/303):
`d988e5407fbaf93c33ed662e59493b4127202626` и `a035d89b18221d376382728884a80200fce09c1b`.
Патч сохранён без изменений и добавляет autodetect аппаратного fastpath при TLS reassembly.

Перед сборкой `.github/workflows/build-nfqws2.yml` определяет последний стабильный
релиз zapret2 через GitHub API `releases/latest` (без draft и prerelease).
Тег разрешается в commit один раз: все архитектуры собираются с этого SHA,
а в `ZAPRET_GH_VER` и `ZAPRET_GH_HASH` передаются тег релиза и SHA соответственно.
Патч проверен на `v1.0.5.2` (`6b6c63e3385fa73f8af3be4a69171e947f5a319d`).
При выходе новой версии нужно учитывать изменения upstream-рецепта сборки.
Патчи применяются по имени файла; ошибка применения останавливает сборку.

## Сборка

Release workflow сначала собирает семь Linux-архитектур по рецепту
[upstream](https://github.com/bol-van/zapret2/blob/v1.0.5.2/.github/workflows/build.yml):
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
