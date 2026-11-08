-- Oracle 12.1. Initial DDL for the MI person and address registry.
--
-- Prerequisites:
--    CUS(ICUSNUM);
--    MI_INF(INF_ID);
--    MI_REQ(REQ_ID);
--    tablespaces USERS and INDEXES.
--
-- Person duplicates are allowed by contract. There are no business-key
-- UNIQUE constraints: duplicate consolidation is performed separately.
--
-- This is a creation script, not a repeatable migration.


-------------------------------------------------------------------------------
-- Sequences
-------------------------------------------------------------------------------
CREATE SEQUENCE S_MI_PERSON
   START WITH 1
   INCREMENT BY 1
   NOCYCLE
   CACHE 100;

CREATE SEQUENCE S_MI_ADDR
   START WITH 1
   INCREMENT BY 1
   NOCYCLE
   CACHE 100;


-------------------------------------------------------------------------------
-- Person registry
-------------------------------------------------------------------------------
CREATE TABLE MI_PERSON
(
   PERSON_ID          INTEGER NOT NULL,
   ICUSNUM            NUMBER(12),
   CREATED_AT         TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,

   FIRST_NAME         VARCHAR2(50),
   LAST_NAME          VARCHAR2(50),
   MIDDLE_NAME        VARCHAR2(50),

   FIRST_NAME_LAT     VARCHAR2(50),
   LAST_NAME_LAT      VARCHAR2(50),
   MIDDLE_NAME_LAT    VARCHAR2(50),

   GENDER_ID          NUMBER(1),

   CTZN_TYPE_ID       NUMBER(1),
   CTZN_COUNTRY_CODE  VARCHAR2(10),

   INN                VARCHAR2(13),
   SNILS              VARCHAR2(20),

   DOC_TYPE_ID        NUMBER(3),
   DOC_TYPE_CODE      VARCHAR2(20),
   DOC_SER            VARCHAR2(10),
   DOC_NUM            VARCHAR2(20),
   DOC_ISSUE_DATE     DATE,
   DOC_ISSUER_CODE    VARCHAR2(20),
   DOC_EXPIRE_DATE    DATE,
   DOC_ISSUER_NAME    VARCHAR2(500),
   DOC_INVALID_FROM   DATE,

   BIRTH_DATE         DATE,
   BIRTH_DATE_RAW     VARCHAR2(20),
   BIRTH_PLACE        VARCHAR2(500),

   DEATH_DATE         DATE,

   PHONE              VARCHAR2(20),
   EMAIL              VARCHAR2(100),

   REGION_CODE        VARCHAR2(2),
   COID               VARCHAR2(100),

   CONSTRAINT CK_MI_PERSON__DEATH_DATE
      CHECK (
         DEATH_DATE IS NULL
         OR BIRTH_DATE IS NULL
         OR DEATH_DATE >= BIRTH_DATE
      ),

   CONSTRAINT CK_MI_PERSON__DOC_EXPIRE_DATE
      CHECK (
         DOC_EXPIRE_DATE IS NULL
         OR DOC_ISSUE_DATE IS NULL
         OR DOC_EXPIRE_DATE >= DOC_ISSUE_DATE
      ),

   CONSTRAINT CK_MI_PERSON__DOC_INVALID_FROM
      CHECK (
         DOC_INVALID_FROM IS NULL
         OR DOC_ISSUE_DATE IS NULL
         OR DOC_INVALID_FROM >= DOC_ISSUE_DATE
      )
)
TABLESPACE USERS;


CREATE UNIQUE INDEX P_MI_PERSON
   ON MI_PERSON (PERSON_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_PERSON
   ADD CONSTRAINT PK_MI_PERSON
   PRIMARY KEY (PERSON_ID)
   USING INDEX P_MI_PERSON;


/*
   Leading ICUSNUM supports FK maintenance and get_Last_Person_Id.
   CREATED_AT/PERSON_ID provide deterministic descending access to the latest
   person without an additional redundant ICUSNUM-only index.
*/
CREATE INDEX I_MI_PERSON__ICUSNUM_LAST
   ON MI_PERSON (
      ICUSNUM,
      CREATED_AT DESC,
      PERSON_ID DESC
   )
   TABLESPACE INDEXES;

/* Matching profile for INF_ID = 1. */
CREATE INDEX I_MI_PERSON__SNILS
   ON MI_PERSON (SNILS)
   TABLESPACE INDEXES;

/* Matching profile for INF_ID IN (74, 75). */
CREATE INDEX I_MI_PERSON__DOC
   ON MI_PERSON (
      DOC_TYPE_ID,
      DOC_SER,
      DOC_NUM,
      DOC_ISSUE_DATE
   )
   TABLESPACE INDEXES;


ALTER TABLE MI_PERSON
   ADD CONSTRAINT FK_MI_PERSON__CUS
   FOREIGN KEY (ICUSNUM)
   REFERENCES CUS (ICUSNUM)
   ON DELETE SET NULL;


-------------------------------------------------------------------------------
-- Person-to-information-type link
--
-- The table is an IOT. Its primary-key structure is the table storage itself;
-- therefore a separate P_MI_P2I index is neither required nor created.
-------------------------------------------------------------------------------
CREATE TABLE MI_P2I
(
   PERSON_ID  INTEGER NOT NULL,
   INF_ID     INTEGER NOT NULL,
   LINKED_AT  TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,

   CONSTRAINT PK_MI_P2I
      PRIMARY KEY (PERSON_ID, INF_ID)
)
ORGANIZATION INDEX
TABLESPACE USERS;


/* PERSON_ID is the leading IOT primary-key column. */
CREATE INDEX F_MI_P2I__INF_ID
   ON MI_P2I (INF_ID)
   TABLESPACE INDEXES;


ALTER TABLE MI_P2I
   ADD CONSTRAINT FK_MI_P2I__MI_PERSON
   FOREIGN KEY (PERSON_ID)
   REFERENCES MI_PERSON (PERSON_ID)
   ON DELETE CASCADE;

ALTER TABLE MI_P2I
   ADD CONSTRAINT FK_MI_P2I__MI_INF
   FOREIGN KEY (INF_ID)
   REFERENCES MI_INF (INF_ID)
   ON DELETE CASCADE;


-------------------------------------------------------------------------------
-- Address registry
-------------------------------------------------------------------------------
CREATE TABLE MI_ADDR
(
   ADDR_ID        INTEGER NOT NULL,
   REQ_ID         INTEGER NOT NULL,
   ITM_ID         INTEGER,

   CKLADR_CODE    VARCHAR2(30),
   CPOSTCODE      VARCHAR2(6),
   CREGION_CODE   VARCHAR2(2),
   CREGION_TYPE   VARCHAR2(30),
   CREGION_NAME   VARCHAR2(50),
   CAREA_TYPE     VARCHAR2(30),
   CAREA_NAME     VARCHAR2(100),
   CCITY_TYPE     VARCHAR2(30),
   CCITY_NAME     VARCHAR2(50),
   CPLACE_TYPE    VARCHAR2(30),
   CPLACE_NAME    VARCHAR2(250),
   CSTREET_TYPE   VARCHAR2(30),
   CSTREET_NAME   VARCHAR2(200),
   CHOUSE         VARCHAR2(100),
   CBUILD         VARCHAR2(100),
   CAPART         VARCHAR2(100),
   CFIAS_CODE     CHAR(36),
   CSTRCT         VARCHAR2(100),
   CCTYA3         CHAR(3),
   COKTMO_CODE    VARCHAR2(20),
   CUNSTRCT_ADDR  VARCHAR2(250),

   CREATED_AT     TIMESTAMP WITH LOCAL TIME ZONE
                     DEFAULT CURRENT_TIMESTAMP NOT NULL
)
TABLESPACE USERS;


CREATE UNIQUE INDEX P_MI_ADDR
   ON MI_ADDR (ADDR_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_ADDR
   ADD CONSTRAINT PK_MI_ADDR
   PRIMARY KEY (ADDR_ID)
   USING INDEX P_MI_ADDR;


CREATE INDEX F_MI_ADDR__REQ_ID
   ON MI_ADDR (REQ_ID)
   TABLESPACE INDEXES;

/* ITM_ID is polymorphic: its table is selected through MI_REQ.INF_ID. */
CREATE INDEX I_MI_ADDR__ITM_ID
   ON MI_ADDR (ITM_ID)
   TABLESPACE INDEXES;


ALTER TABLE MI_ADDR
   ADD CONSTRAINT FK_MI_ADDR__MI_REQ
   FOREIGN KEY (REQ_ID)
   REFERENCES MI_REQ (REQ_ID)
   ON DELETE CASCADE;


-------------------------------------------------------------------------------
-- Person-to-address link
--
-- The table is an IOT. PERSON_ID is the leading primary-key column, so only
-- the secondary index required by the ADDR_ID foreign key is created.
-------------------------------------------------------------------------------
CREATE TABLE MI_P2A
(
   PERSON_ID  INTEGER NOT NULL,
   ADDR_ID    INTEGER NOT NULL,
   ITYPE      NUMBER NOT NULL,
   DBEG_REG   DATE,
   DEND_REG   DATE,

   CONSTRAINT PK_MI_P2A
      PRIMARY KEY (PERSON_ID, ADDR_ID, ITYPE)
)
ORGANIZATION INDEX
TABLESPACE USERS;


CREATE INDEX F_MI_P2A__ADDR_ID
   ON MI_P2A (ADDR_ID)
   TABLESPACE INDEXES;


ALTER TABLE MI_P2A
   ADD CONSTRAINT FK_MI_P2A__MI_PERSON
   FOREIGN KEY (PERSON_ID)
   REFERENCES MI_PERSON (PERSON_ID)
   ON DELETE CASCADE;

ALTER TABLE MI_P2A
   ADD CONSTRAINT FK_MI_P2A__MI_ADDR
   FOREIGN KEY (ADDR_ID)
   REFERENCES MI_ADDR (ADDR_ID)
   ON DELETE CASCADE;


-------------------------------------------------------------------------------
-- ID generation
-------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER T_MI_PERSON_BI
   BEFORE INSERT ON MI_PERSON
   FOR EACH ROW
   WHEN (NEW.PERSON_ID IS NULL)
BEGIN
   :NEW.PERSON_ID := S_MI_PERSON.NEXTVAL;
END;
/

CREATE OR REPLACE TRIGGER T_MI_ADDR_BI
   BEFORE INSERT ON MI_ADDR
   FOR EACH ROW
   WHEN (NEW.ADDR_ID IS NULL)
BEGIN
   :NEW.ADDR_ID := S_MI_ADDR.NEXTVAL;
END;
/


-------------------------------------------------------------------------------
-- Comments: MI_PERSON
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_PERSON IS
   'MI-edo. Реестр физ лиц. Данные физ лиц, используемые в MI-edo {$Id$}';

COMMENT ON COLUMN MI_PERSON.PERSON_ID IS
   'ID записи /mi_person/';
COMMENT ON COLUMN MI_PERSON.ICUSNUM IS
   'Обычно заполнен; допускается NULL для локальных персон без привязки к CUS';
COMMENT ON COLUMN MI_PERSON.CREATED_AT IS
   'Дата и время создания записи';
COMMENT ON COLUMN MI_PERSON.FIRST_NAME IS 'Имя';
COMMENT ON COLUMN MI_PERSON.LAST_NAME IS 'Фамилия';
COMMENT ON COLUMN MI_PERSON.MIDDLE_NAME IS 'Отчество';
COMMENT ON COLUMN MI_PERSON.FIRST_NAME_LAT IS 'Имя латиницей';
COMMENT ON COLUMN MI_PERSON.LAST_NAME_LAT IS 'Фамилия латиницей';
COMMENT ON COLUMN MI_PERSON.MIDDLE_NAME_LAT IS 'Отчество латиницей';
COMMENT ON COLUMN MI_PERSON.GENDER_ID IS 'Пол человека';
COMMENT ON COLUMN MI_PERSON.CTZN_TYPE_ID IS 'Тип гражданства';
COMMENT ON COLUMN MI_PERSON.CTZN_COUNTRY_CODE IS
   'Страна/код страны гражданства';
COMMENT ON COLUMN MI_PERSON.INN IS 'ИНН';
COMMENT ON COLUMN MI_PERSON.SNILS IS 'СНИЛС';
COMMENT ON COLUMN MI_PERSON.DOC_TYPE_ID IS 'Тип документа, ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_TYPE_CODE IS 'Строковый код типа ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_SER IS 'Серия ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_NUM IS 'Номер ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_ISSUE_DATE IS 'Дата выдачи ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_ISSUER_CODE IS
   'Код подразделения, выдавшего ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_EXPIRE_DATE IS
   'Дата окончания срока действия ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_ISSUER_NAME IS
   'Наименование органа, выдавшего ДУЛ';
COMMENT ON COLUMN MI_PERSON.DOC_INVALID_FROM IS
   'Дата, с которой ДУЛ недействителен';
COMMENT ON COLUMN MI_PERSON.BIRTH_DATE IS 'Дата рождения';
COMMENT ON COLUMN MI_PERSON.BIRTH_DATE_RAW IS
   'Строковая дата рождения для особых случаев';
COMMENT ON COLUMN MI_PERSON.BIRTH_PLACE IS 'Место рождения';
COMMENT ON COLUMN MI_PERSON.DEATH_DATE IS 'Дата смерти';
COMMENT ON COLUMN MI_PERSON.PHONE IS 'Телефон';
COMMENT ON COLUMN MI_PERSON.EMAIL IS 'E-mail';
COMMENT ON COLUMN MI_PERSON.REGION_CODE IS 'Код региона';
COMMENT ON COLUMN MI_PERSON.COID IS 'Внешний идентификатор COID';


-------------------------------------------------------------------------------
-- Comments: MI_P2I
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_P2I IS
   'MI-edo. Реестр физ лиц. Связь person с видами сведений {$Id$}';
COMMENT ON COLUMN MI_P2I.PERSON_ID IS 'ID физлица /mi_person/';
COMMENT ON COLUMN MI_P2I.INF_ID IS 'ID вида сведений /mi_inf/';
COMMENT ON COLUMN MI_P2I.LINKED_AT IS 'Когда была сформирована связь';


-------------------------------------------------------------------------------
-- Comments: MI_ADDR
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_ADDR IS
   'MI-edo. Адреса, привязанные к запросам и элементам запросов {$Id$}';
COMMENT ON COLUMN MI_ADDR.ADDR_ID IS 'ID адреса';
COMMENT ON COLUMN MI_ADDR.REQ_ID IS 'ID запроса /mi_req/';
COMMENT ON COLUMN MI_ADDR.ITM_ID IS
   'ID элемента запроса; таблица элемента определяется через mi_req.inf_id';
COMMENT ON COLUMN MI_ADDR.CKLADR_CODE IS 'Код по КЛАДР';
COMMENT ON COLUMN MI_ADDR.CPOSTCODE IS 'Индекс';
COMMENT ON COLUMN MI_ADDR.CREGION_CODE IS 'Код региона';
COMMENT ON COLUMN MI_ADDR.CREGION_TYPE IS 'Тип региона';
COMMENT ON COLUMN MI_ADDR.CREGION_NAME IS 'Наименование региона';
COMMENT ON COLUMN MI_ADDR.CAREA_TYPE IS 'Тип района';
COMMENT ON COLUMN MI_ADDR.CAREA_NAME IS 'Наименование района';
COMMENT ON COLUMN MI_ADDR.CCITY_TYPE IS 'Тип города';
COMMENT ON COLUMN MI_ADDR.CCITY_NAME IS 'Наименование города';
COMMENT ON COLUMN MI_ADDR.CPLACE_TYPE IS 'Тип населенного пункта';
COMMENT ON COLUMN MI_ADDR.CPLACE_NAME IS 'Наименование населенного пункта';
COMMENT ON COLUMN MI_ADDR.CSTREET_TYPE IS 'Тип улицы';
COMMENT ON COLUMN MI_ADDR.CSTREET_NAME IS 'Наименование улицы';
COMMENT ON COLUMN MI_ADDR.CHOUSE IS 'Номер дома';
COMMENT ON COLUMN MI_ADDR.CBUILD IS 'Корпус';
COMMENT ON COLUMN MI_ADDR.CAPART IS 'Квартира/офис';
COMMENT ON COLUMN MI_ADDR.CFIAS_CODE IS 'Идентификатор адреса в ФИАС';
COMMENT ON COLUMN MI_ADDR.CSTRCT IS 'Строение';
COMMENT ON COLUMN MI_ADDR.CCTYA3 IS 'Код страны (Alpha3)';
COMMENT ON COLUMN MI_ADDR.COKTMO_CODE IS 'Код региона по ОКТМО';
COMMENT ON COLUMN MI_ADDR.CUNSTRCT_ADDR IS 'Неструктурированный адрес';
COMMENT ON COLUMN MI_ADDR.CREATED_AT IS 'Дата создания';


-------------------------------------------------------------------------------
-- Comments: MI_P2A
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_P2A IS
   'MI-edo. Адресные данные. Связь физлиц с адресами {$Id$}';
COMMENT ON COLUMN MI_P2A.PERSON_ID IS 'ID физлица /mi_person/';
COMMENT ON COLUMN MI_P2A.ADDR_ID IS 'ID адреса /mi_addr/';
COMMENT ON COLUMN MI_P2A.ITYPE IS
   'Тип адреса: 1 - постоянная регистрация, 2 - временная регистрация';
COMMENT ON COLUMN MI_P2A.DBEG_REG IS 'Дата начала срока регистрации';
COMMENT ON COLUMN MI_P2A.DEND_REG IS 'Дата окончания срока регистрации';
