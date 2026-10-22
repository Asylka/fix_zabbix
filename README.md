# Скрипты диагностики и восстановления Zabbix

Скрипты из рабочей папки проекта, рассчитанные на Ubuntu 24.04, systemd 255,
Zabbix Server 6.0 и службу `zabbix-server.service`. Существующая установка
и база данных используются без переустановки.

| Файл | Назначение |
| --- | --- |
| `zabbix_safe_restart.sh` | Диагностика, контролируемая остановка, запуск или перезапуск службы. Требуется Bash. |
| `zabbix_cancel_stuck_restart.sh` | Отмена проверенного зависшего restart-задания; режим `--drain-upgrade` для повторных запросов от unattended-upgrade/needrestart. Требуется Bash. |
| `zabbix_start_observe.sh` | Один запуск после перезагрузки VM и наблюдение; отдельный режим диагностики. Запускается через `sh`. |
| [ZABBIX_SAFE_RESTART.md](ZABBIX_SAFE_RESTART.md) | Условия применения восстановления и разбор предыдущих попыток. |
| [ZABBIX_START_AFTER_REBOOT.md](ZABBIX_START_AFTER_REBOOT.md) | Отдельный сценарий запуска после перезагрузки VM. |
| `tests/` | Локальные проверки с подставными вызовами управления службой. Для работы на сервере не нужны. |

## Скачать на сервер без Git

Нужны доступ к GitHub, `curl` и стандартный `tar`. Выполнить от обычного
пользователя; скрипты будут распакованы в новую папку домашнего каталога:

```bash
(
  set -eu
  download_dir=$(mktemp -d "$HOME/fix-zabbix.XXXXXX")
  curl --fail --location --retry 3 \
    https://codeload.github.com/Asylka/fix_zabbix/tar.gz/refs/heads/main \
    --output "$download_dir/repository.tar.gz"
  tar -xzf "$download_dir/repository.tar.gz" -C "$download_dir" --strip-components=1
  cd "$download_dir"
  sha256sum -c SHA256SUMS
  bash -n zabbix_safe_restart.sh
  bash -n zabbix_cancel_stuck_restart.sh
  sh -n zabbix_start_observe.sh
  printf '\nФайлы скачаны и проверены: %s\n' "$download_dir"
)
```

Скачивание и проверка синтаксиса службу не запускают и не перезапускают.
Контрольные суммы проверяют целостность файлов относительно скачанного манифеста.
После успешного скачивания перейти в каталог, напечатанный в последней строке.

Если на сервере уже установлен Git:

```bash
git clone https://github.com/Asylka/fix_zabbix.git
cd fix_zabbix
sha256sum -c SHA256SUMS
```

Для обновления этой Git-копии: `git pull --ff-only`, затем повторить
`sha256sum -c SHA256SUMS` и проверку синтаксиса нужного скрипта.

## Выбрать действие

Из каталога со скачанными файлами можно собрать свежую диагностику:

```bash
sudo bash ./zabbix_safe_restart.sh --diagnose
```

Для случая зависшего обновления, описанного в [инструкции восстановления](ZABBIX_SAFE_RESTART.md),
используется отдельная команда:

```bash
sudo bash ./zabbix_cancel_stuck_restart.sh --drain-upgrade
```

Этот режим требует отключённый и неактивный `apt-daily-upgrade.timer` и
проверяет связь запроса restart с обновлением. Он отменяет задания systemd,
поэтому применять его нужно к описанному в инструкции случаю.
Только после `Exit code: 0` продолжать восстановление по инструкции.
Команды принудительного перезапуска и запуска после перезагрузки приведены
в соответствующих документах вместе с условиями применения.

Не выполнять несколько скриптов управления Zabbix одновременно.
В конце работы скрипт печатает `SEND THIS ARCHIVE` с путём диагностического архива.

## Локальная проверка

В среде с Bash и стандартными Unix-утилитами:

```bash
bash -n zabbix_safe_restart.sh zabbix_cancel_stuck_restart.sh
sh -n zabbix_start_observe.sh
bash tests/test_zabbix_safe_restart.sh
bash tests/test_cancel_stuck_restart.sh
bash tests/test_drain_upgrade.sh
```

Тесты заменяют команды управления службой подставными функциями. Это не
проверка на настоящем systemd или рабочем сервере.

## Состав публичного репозитория

В репозиторий входят скрипты, инструкции и исходники тестов.
Диагностические каталоги с датой, архивы `.tar.gz`, результаты тестовых запусков,
логи, секреты и конфигурация сервера остаются локально и исключены через `.gitignore`.
Диагностические архивы могут содержать внутренние адреса и имена узлов.
Скрипты хранятся с переводами строк LF для запуска на Linux.
