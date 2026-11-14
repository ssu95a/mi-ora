-- Oracle 12.1. Initial DDL for MI_0600_F.
--
-- Список имён файлов внутри ZIP-архива MI_0600.
-- This is a creation/model-import script, not a repeatable migration.


CREATE TABLE MI_0600_F
(
   ITM_ID          INTEGER       NOT NULL,
   CZIP_FILE_NAME  VARCHAR2(300) NOT NULL
)
TABLESPACE USERS;


/*
   Reverse key is deliberately not used here: the composite key is not a
   monotonically growing sequence and its leading ITM_ID is also the FK path.
*/
CREATE UNIQUE INDEX P_MI_0600_F
   ON MI_0600_F (ITM_ID, CZIP_FILE_NAME)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600_F
   ADD CONSTRAINT PK_MI_0600_F
   PRIMARY KEY (ITM_ID, CZIP_FILE_NAME)
   USING INDEX P_MI_0600_F;


CREATE INDEX I_MI_0600_F__FILE_NAME
   ON MI_0600_F (UPPER(TRIM(CZIP_FILE_NAME)))
   TABLESPACE INDEXES;


ALTER TABLE MI_0600_F
   ADD CONSTRAINT FK_MI_0600_F__MI_0600
   FOREIGN KEY (ITM_ID)
   REFERENCES MI_0600 (ITM_ID)
   ON DELETE CASCADE;


COMMENT ON TABLE MI_0600_F IS
   'MI-edo. Имена файлов внутри ZIP-архивов MI_0600 {$Id$}';

COMMENT ON COLUMN MI_0600_F.ITM_ID IS
   'ID ZIP-элемента /MI_0600/';

COMMENT ON COLUMN MI_0600_F.CZIP_FILE_NAME IS
   'Имя файла внутри ZIP-архива';
