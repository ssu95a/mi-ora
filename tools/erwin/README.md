# Нормализация tablespace в модели erwin

`MI_Set_Tablespaces.bas` массово задаёт физическое размещение объектов MI:

- таблицы `MI_*` и их partition storage — `USERS`;
- обычные, уникальные и вторичные индексы — `INDEXES`;
- PK таблиц-IOT `MI_P2A` и `MI_P2I` остаётся в `USERS`, потому что это сам
  табличный сегмент;
- view, sequence и объекты не из пространства имён `MI_*` не изменяются.

Макрос меняет саму `.erwin`-модель через штатный erwin SCAPI. Сгенерированный
DDL не разбирается и не переписывается.

## Подготовка

1. Закрыть выбранную модель в erwin и убедиться, что файл не read-only.
2. Разрядность Excel должна совпадать с разрядностью erwin Data Modeler.
3. `EAL.dll` из установленного erwin должна быть зарегистрирована. Макрос
   использует late binding, поэтому добавлять ссылку в `Tools -> References`
   обычно не требуется.
4. В модели должны существовать Oracle tablespace с именами `USERS` и
   `INDEXES`. Макрос намеренно не создаёт их автоматически.

## Запуск

1. Открыть Excel, нажать `Alt+F11`.
2. Выбрать `File -> Import File...` и импортировать
   `MI_Set_Tablespaces.bas`.
3. Сначала запустить `MI_Tablespaces_Dry_Run`.
4. Проверить файл `<model>.erwin.tablespaces.log`.
5. Запустить `MI_Tablespaces_Apply`.

Перед применением рядом с моделью автоматически создаётся копия:

```text
<model>.before-tablespaces-YYYYMMDD-HHMMSS.erwin
```

Если SCAPI сообщает ошибку, исходный файл не сохраняется: транзакция erwin
откатывается. После успешного применения следует заново сгенерировать полный
DDL и проверить, что:

```sql
CREATE TABLE ... TABLESPACE USERS;
CREATE INDEX ... TABLESPACE INDEXES;
```

Для partitioned-объектов проверяются также storage-объекты разделов. Если в
будущем появятся новые IOT-таблицы, их имена нужно добавить в константу
`IOT_TABLES` до запуска `APPLY`.
