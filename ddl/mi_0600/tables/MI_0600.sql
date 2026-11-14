-- Oracle 12.1. Initial DDL for MI_0600.
--
-- Назначение:
--    один ZIP-архив ЭДО с ФНС на request видов сведений
--    601-604, 611, 612.
--
-- Prerequisites:
--    MI_REQ(REQ_ID);
--    global sequence S_MI_ITM;
--    tablespaces USERS and INDEXES.
--
-- This is a creation/model-import script, not a repeatable migration.


CREATE TABLE MI_0600
(
   ITM_ID           INTEGER
                       DEFAULT ON NULL S_MI_ITM.NEXTVAL NOT NULL,

   EXTERNAL_UUID    CHAR(36)       NOT NULL,
   REQ_ID           INTEGER        NOT NULL,

   CZIP_NAME        VARCHAR2(300)   NOT NULL,
   BZIP_DATA        BLOB,
   IZIP_SIZE        INTEGER,
   IZIP_FILES_COUNT INTEGER,

   DSEND_STAMP      TIMESTAMP WITH LOCAL TIME ZONE,
   ICREATE_TYPE     NUMBER(1)       DEFAULT 0 NOT NULL,
   WAS_UPLOADED     NUMBER(1)       DEFAULT 0 NOT NULL,
   CREATED_AT       TIMESTAMP       DEFAULT CURRENT_TIMESTAMP NOT NULL,

   /* Legacy diagnostic field retained for compatibility. */
   CERR_MSG         VARCHAR2(255),

   /* Common item outcome contract used by MI_Item_Result_Api. */
   MESSAGE_UUID     CHAR(36),
   IRES_CODE        NUMBER(3),
   TRES_TIME        TIMESTAMP WITH LOCAL TIME ZONE,
   CRES_INFO        CLOB,
   ERROR_CODE       VARCHAR2(100),

   CONSTRAINT CK_MI_0600__EXTERNAL_UUID
      CHECK (
         REGEXP_LIKE(
            EXTERNAL_UUID,
            '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
            'c'
         )
      ),

   CONSTRAINT CK_MI_0600__MESSAGE_UUID
      CHECK (
         MESSAGE_UUID IS NULL
         OR REGEXP_LIKE(
               MESSAGE_UUID,
               '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
               'c'
            )
      ),

   CONSTRAINT CK_MI_0600__IZIP_SIZE
      CHECK (IZIP_SIZE IS NULL OR IZIP_SIZE >= 0),

   CONSTRAINT CK_MI_0600__FILES_COUNT
      CHECK (IZIP_FILES_COUNT IS NULL OR IZIP_FILES_COUNT >= 0),

   CONSTRAINT CK_MI_0600__ICREATE_TYPE
      CHECK (ICREATE_TYPE IN (0, 1)),

   CONSTRAINT CK_MI_0600__WAS_UPLOADED
      CHECK (WAS_UPLOADED IN (0, 1))
)
TABLESPACE USERS;


-------------------------------------------------------------------------------
-- Primary and unique keys
-------------------------------------------------------------------------------
CREATE UNIQUE INDEX P_MI_0600
   ON MI_0600 (ITM_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_0600
   ADD CONSTRAINT PK_MI_0600
   PRIMARY KEY (ITM_ID)
   USING INDEX P_MI_0600;


CREATE UNIQUE INDEX U_MI_0600__REQ_ID
   ON MI_0600 (REQ_ID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600
   ADD CONSTRAINT UK_MI_0600__REQ_ID
   UNIQUE (REQ_ID)
   USING INDEX U_MI_0600__REQ_ID;


CREATE UNIQUE INDEX U_MI_0600__EXTERNAL_UUID
   ON MI_0600 (EXTERNAL_UUID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600
   ADD CONSTRAINT UK_MI_0600__EXTERNAL_UUID
   UNIQUE (EXTERNAL_UUID)
   USING INDEX U_MI_0600__EXTERNAL_UUID;


/*
   Archive name is the idempotency key used by the 601/603/611 capture flow.
   A database constraint is required; a procedural existence check alone is
   racy under concurrent capture workers.
*/
CREATE UNIQUE INDEX U_MI_0600__CZIP_NAME
   ON MI_0600 (CZIP_NAME)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600
   ADD CONSTRAINT UK_MI_0600__CZIP_NAME
   UNIQUE (CZIP_NAME)
   USING INDEX U_MI_0600__CZIP_NAME;


-------------------------------------------------------------------------------
-- Operational access paths
-------------------------------------------------------------------------------
CREATE INDEX I_MI_0600__DSEND_STAMP
   ON MI_0600 (DSEND_STAMP)
   TABLESPACE INDEXES;

/* Oracle B-tree indexes do not store all-NULL keys; no partial index needed. */
CREATE INDEX I_MI_0600__MESSAGE_UUID
   ON MI_0600 (MESSAGE_UUID)
   TABLESPACE INDEXES;


-------------------------------------------------------------------------------
-- Referential integrity
-------------------------------------------------------------------------------
ALTER TABLE MI_0600
   ADD CONSTRAINT FK_MI_0600__MI_REQ
   FOREIGN KEY (REQ_ID)
   REFERENCES MI_REQ (REQ_ID)
   ON DELETE CASCADE;


-------------------------------------------------------------------------------
-- Comments
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_0600 IS
   'MI-edo. ЭДО с ФНС. ZIP-элементы запросов видов сведений 601-604, 611, 612 {$Id$}';

COMMENT ON COLUMN MI_0600.ITM_ID IS
   'Глобальный ID элемента запроса из S_MI_ITM';

COMMENT ON COLUMN MI_0600.EXTERNAL_UUID IS
   'Внешний UUID элемента';

COMMENT ON COLUMN MI_0600.REQ_ID IS
   'ID заголовка запроса /MI_REQ/; один item на request';

COMMENT ON COLUMN MI_0600.CZIP_NAME IS
   'Наименование ZIP-архива; ключ идемпотентности capture flow';

COMMENT ON COLUMN MI_0600.BZIP_DATA IS
   'Данные ZIP-архива';

COMMENT ON COLUMN MI_0600.IZIP_SIZE IS
   'Размер ZIP-архива в байтах';

COMMENT ON COLUMN MI_0600.IZIP_FILES_COUNT IS
   'Количество файлов в ZIP-архиве';

COMMENT ON COLUMN MI_0600.DSEND_STAMP IS
   'Дата и время постановки request в очередь отправки';

COMMENT ON COLUMN MI_0600.ICREATE_TYPE IS
   'Способ создания: 0 - вручную, 1 - автоматически';

COMMENT ON COLUMN MI_0600.WAS_UPLOADED IS
   'Признак выгрузки архива: 0 - нет, 1 - да';

COMMENT ON COLUMN MI_0600.CREATED_AT IS
   'Дата и время создания элемента';

COMMENT ON COLUMN MI_0600.CERR_MSG IS
   'Legacy-текст ошибки; новые результаты используют ERROR_CODE/CRES_INFO';

COMMENT ON COLUMN MI_0600.MESSAGE_UUID IS
   'UUID входящего сообщения, которым окончательно обработан item';

COMMENT ON COLUMN MI_0600.IRES_CODE IS
   'Бизнес-код результата либо -1 при ошибке обработки элемента';

COMMENT ON COLUMN MI_0600.TRES_TIME IS
   'Дата и время результата, полученные от внешнего сервиса';

COMMENT ON COLUMN MI_0600.CRES_INFO IS
   'Информация о бизнес-результате или внешней ошибке';

COMMENT ON COLUMN MI_0600.ERROR_CODE IS
   'Код внешней ошибки; для успешного transport response NULL';
