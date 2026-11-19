-- Oracle 12.1. Initial DDL for MI_0202.
--
-- Социальные счета. Договор социального вклада/счёта.
--
-- Prerequisites:
--    MI_REQ(REQ_ID);
--    MI_PERSON(PERSON_ID);
--    CUS(ICUSNUM);
--    global sequence S_MI_ITM;
--    tablespaces USERS and INDEXES.
--
-- This is a creation/model-import script, not a repeatable migration.


CREATE TABLE MI_0202
(
   ITM_ID            INTEGER
                        DEFAULT ON NULL S_MI_ITM.NEXTVAL NOT NULL,

   EXTERNAL_UUID     CHAR(36)       NOT NULL,
   REQ_ID            INTEGER        NOT NULL,
   PERSON_ID         INTEGER,
   ICUSNUM           NUMBER(12),

   KIND              VARCHAR2(50)   NOT NULL,
   ORDER_ID          NUMBER(38),
   ORDER_TIMESTAMP   TIMESTAMP WITH LOCAL TIME ZONE,

   SUBSERVICE_CODE   VARCHAR2(100),
   SUBSERVICE_TITLE  VARCHAR2(500),
   SUBSERVICE_DATA   CLOB,
   AGREEMENT_TYPE    VARCHAR2(50),

   DOCUMENTS         CLOB,
   PAYLOAD           CLOB,

   CREATED_AT        TIMESTAMP WITH LOCAL TIME ZONE
                        DEFAULT CURRENT_TIMESTAMP NOT NULL,

   /* Common item outcome contract used by MI_Item_Result_Api. */
   IRES_CODE         NUMBER(3) DEFAULT 0,
   TRES_TIME         TIMESTAMP WITH LOCAL TIME ZONE,
   CRES_INFO         CLOB,
   MESSAGE_UUID      CHAR(36),
   ERROR_CODE        VARCHAR2(100),

   CONSTRAINT CK_MI_0202__EXTERNAL_UUID
      CHECK (
         REGEXP_LIKE(
            EXTERNAL_UUID,
            '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
            'c'
         )
      ),

   CONSTRAINT CK_MI_0202__MESSAGE_UUID
      CHECK (
         MESSAGE_UUID IS NULL
         OR REGEXP_LIKE(
               MESSAGE_UUID,
               '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
               'c'
            )
      ),

   CONSTRAINT CK_MI_0202__SUBSERVICE_JSON
      CHECK (SUBSERVICE_DATA IS JSON STRICT),

   CONSTRAINT CK_MI_0202__DOCUMENTS_JSON
      CHECK (DOCUMENTS IS JSON STRICT),

   CONSTRAINT CK_MI_0202__PAYLOAD_JSON
      CHECK (PAYLOAD IS JSON STRICT)
)
TABLESPACE USERS;


-------------------------------------------------------------------------------
-- Primary and unique keys
-------------------------------------------------------------------------------
CREATE UNIQUE INDEX P_MI_0202
   ON MI_0202 (ITM_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_0202
   ADD CONSTRAINT PK_MI_0202
   PRIMARY KEY (ITM_ID)
   USING INDEX P_MI_0202;


CREATE UNIQUE INDEX U_MI_0202__EXTERNAL_UUID
   ON MI_0202 (EXTERNAL_UUID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0202
   ADD CONSTRAINT UK_MI_0202__EXTERNAL_UUID
   UNIQUE (EXTERNAL_UUID)
   USING INDEX U_MI_0202__EXTERNAL_UUID;


-------------------------------------------------------------------------------
-- Operational and foreign-key access paths
-------------------------------------------------------------------------------
CREATE INDEX F_MI_0202__REQ_ID
   ON MI_0202 (REQ_ID)
   TABLESPACE INDEXES;

/* Oracle B-tree indexes do not store all-NULL keys; no partial index needed. */
CREATE INDEX F_MI_0202__PERSON_ID
   ON MI_0202 (PERSON_ID)
   TABLESPACE INDEXES;

CREATE INDEX F_MI_0202__ICUSNUM
   ON MI_0202 (ICUSNUM)
   TABLESPACE INDEXES;

CREATE INDEX I_MI_0202__KIND
   ON MI_0202 (KIND)
   TABLESPACE INDEXES;

CREATE INDEX I_MI_0202__ORDER_ID
   ON MI_0202 (ORDER_ID)
   TABLESPACE INDEXES;

CREATE INDEX I_MI_0202__MESSAGE_UUID
   ON MI_0202 (MESSAGE_UUID)
   TABLESPACE INDEXES;


-------------------------------------------------------------------------------
-- Referential integrity
-------------------------------------------------------------------------------
ALTER TABLE MI_0202
   ADD CONSTRAINT FK_MI_0202__MI_REQ
   FOREIGN KEY (REQ_ID)
   REFERENCES MI_REQ (REQ_ID)
   ON DELETE CASCADE;

ALTER TABLE MI_0202
   ADD CONSTRAINT FK_MI_0202__MI_PERSON
   FOREIGN KEY (PERSON_ID)
   REFERENCES MI_PERSON (PERSON_ID);

ALTER TABLE MI_0202
   ADD CONSTRAINT FK_MI_0202__CUS
   FOREIGN KEY (ICUSNUM)
   REFERENCES CUS (ICUSNUM);


-------------------------------------------------------------------------------
-- Comments
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_0202 IS
   'MI-edo. Социальные счета. Договор социального вклада/счёта (вид сведений 0202) {$Id$}';

COMMENT ON COLUMN MI_0202.ITM_ID IS
   'ID элемента запроса из общей последовательности S_MI_ITM';
COMMENT ON COLUMN MI_0202.EXTERNAL_UUID IS
   'Внешний UUID элемента';
COMMENT ON COLUMN MI_0202.REQ_ID IS
   'ID запроса /MI_REQ/';
COMMENT ON COLUMN MI_0202.PERSON_ID IS
   'ID физлица /MI_PERSON/';
COMMENT ON COLUMN MI_0202.ICUSNUM IS
   'ID клиента XXI; заполняется ФПЗ при проверке';
COMMENT ON COLUMN MI_0202.KIND IS
   'Подвид документа: Appeal / CancelRequest / Message / signRequest / signResponse';
COMMENT ON COLUMN MI_0202.ORDER_ID IS
   'Идентификатор заявления на ЕПГУ (orderId)';
COMMENT ON COLUMN MI_0202.ORDER_TIMESTAMP IS
   'Дата и время формирования заявления (orderTimestamp)';
COMMENT ON COLUMN MI_0202.SUBSERVICE_CODE IS
   'Код услуги (subservice.code)';
COMMENT ON COLUMN MI_0202.SUBSERVICE_TITLE IS
   'Наименование услуги (subservice.title)';
COMMENT ON COLUMN MI_0202.SUBSERVICE_DATA IS
   'Свободные атрибуты услуги (subservice.anyData, variantData), JSON';
COMMENT ON COLUMN MI_0202.AGREEMENT_TYPE IS
   'Тип продукта: Счёт / Вклад';
COMMENT ON COLUMN MI_0202.DOCUMENTS IS
   'Документы с метаданными вложений, JSON array';
COMMENT ON COLUMN MI_0202.PAYLOAD IS
   'Исходный JSON от Java без преобразования';
COMMENT ON COLUMN MI_0202.CREATED_AT IS
   'Дата и время создания элемента';
COMMENT ON COLUMN MI_0202.IRES_CODE IS
   'Код результата: 0 - черновик';
COMMENT ON COLUMN MI_0202.TRES_TIME IS
   'Время получения результата';
COMMENT ON COLUMN MI_0202.CRES_INFO IS
   'Информация о результате';
COMMENT ON COLUMN MI_0202.MESSAGE_UUID IS
   'UUID сообщения, обработавшего элемент';
COMMENT ON COLUMN MI_0202.ERROR_CODE IS
   'Код ошибки при обработке';
