-- Oracle 12.1. Initial DDL for MI_0007.
--
-- Назначение:
--    элементы запросов проверки паспортных данных физических лиц.
--
-- Supported information types are stored in MI_REQ and currently belong to
-- the MI_0007 request partition/group (INF_ID 71, 72, 73, 74, 75).
--
-- Prerequisites:
--    MI_REQ(REQ_ID);
--    MI_PERSON(PERSON_ID);
--    tablespaces USERS and INDEXES.
--
-- This is a creation/model-import script, not a repeatable migration.


-------------------------------------------------------------------------------
-- Global item identifier
--
-- ITM_ID values are generated from one sequence for every MI_xxxx item table.
-- The item table itself is still resolved through MI_REQ.INF_ID.
-------------------------------------------------------------------------------
CREATE SEQUENCE S_MI_ITM
   START WITH 1
   INCREMENT BY 1
   MINVALUE 1
   NOCYCLE
   CACHE 1000;


-------------------------------------------------------------------------------
-- Passport validation request items
-------------------------------------------------------------------------------
CREATE TABLE MI_0007
(
   ITM_ID         INTEGER
                     DEFAULT ON NULL S_MI_ITM.NEXTVAL NOT NULL,

   EXTERNAL_UUID  CHAR(36) NOT NULL,
   REQ_ID         INTEGER  NOT NULL,
   PERSON_ID      INTEGER  NOT NULL,

   CREATED_AT     TIMESTAMP
                     DEFAULT CURRENT_TIMESTAMP NOT NULL,

   /* Common item outcome contract used by MI_Item_Result_Api. */
   MESSAGE_UUID   CHAR(36),
   IRES_CODE      NUMBER(3),
   TRES_TIME      TIMESTAMP WITH LOCAL TIME ZONE,
   CRES_INFO      CLOB,
   ERROR_CODE     VARCHAR2(100)
)
TABLESPACE USERS;


-------------------------------------------------------------------------------
-- Primary and unique keys
-------------------------------------------------------------------------------
CREATE UNIQUE INDEX P_MI_0007
   ON MI_0007 (ITM_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_0007
   ADD CONSTRAINT PK_MI_0007
   PRIMARY KEY (ITM_ID)
   USING INDEX P_MI_0007;


CREATE UNIQUE INDEX U_MI_0007__EXTERNAL_UUID
   ON MI_0007 (EXTERNAL_UUID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0007
   ADD CONSTRAINT UK_MI_0007__EXTERNAL_UUID
   UNIQUE (EXTERNAL_UUID)
   USING INDEX U_MI_0007__EXTERNAL_UUID;


-------------------------------------------------------------------------------
-- Foreign-key access paths
-------------------------------------------------------------------------------
CREATE INDEX F_MI_0007__REQ_ID
   ON MI_0007 (REQ_ID)
   TABLESPACE INDEXES;

CREATE INDEX F_MI_0007__PERSON_ID
   ON MI_0007 (PERSON_ID)
   TABLESPACE INDEXES;


-------------------------------------------------------------------------------
-- Referential integrity
-------------------------------------------------------------------------------
ALTER TABLE MI_0007
   ADD CONSTRAINT FK_MI_0007__MI_REQ
   FOREIGN KEY (REQ_ID)
   REFERENCES MI_REQ (REQ_ID)
   ON DELETE CASCADE;

ALTER TABLE MI_0007
   ADD CONSTRAINT FK_MI_0007__MI_PERSON
   FOREIGN KEY (PERSON_ID)
   REFERENCES MI_PERSON (PERSON_ID);


-------------------------------------------------------------------------------
-- Comments
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_0007 IS
   'MI-edo. Валидность данных физлиц. Элементы запросов проверки паспортных данных {$Id$}';

COMMENT ON COLUMN MI_0007.ITM_ID IS
   'Глобальный ID элемента запроса из S_MI_ITM';

COMMENT ON COLUMN MI_0007.EXTERNAL_UUID IS
   'Внешний UUID элемента запроса';

COMMENT ON COLUMN MI_0007.REQ_ID IS
   'ID заголовка запроса /MI_REQ/';

COMMENT ON COLUMN MI_0007.PERSON_ID IS
   'ID физлица /MI_PERSON/';

COMMENT ON COLUMN MI_0007.CREATED_AT IS
   'Дата и время создания элемента';

COMMENT ON COLUMN MI_0007.MESSAGE_UUID IS
   'UUID входящего сообщения, которым окончательно обработан item';

COMMENT ON COLUMN MI_0007.IRES_CODE IS
   'Бизнес-код результата либо -1 при ошибке обработки элемента';

COMMENT ON COLUMN MI_0007.TRES_TIME IS
   'Дата и время результата, полученные от внешнего сервиса';

COMMENT ON COLUMN MI_0007.CRES_INFO IS
   'Информация о бизнес-результате или внешней ошибке';

COMMENT ON COLUMN MI_0007.ERROR_CODE IS
   'Код внешней ошибки; для успешного результата NULL';
