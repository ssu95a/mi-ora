-- Oracle 12.1. Read model for MI_0007 passport validation items.

CREATE OR REPLACE VIEW V_MI_0007
AS
SELECT i.ITM_ID,
       i.REQ_ID,
       i.CREATED_AT,
       i.PERSON_ID,

       i.IRES_CODE,
       i.TRES_TIME,
       i.CRES_INFO,
       i.ERROR_CODE,
       i.MESSAGE_UUID,
       i.EXTERNAL_UUID,

       p.ICUSNUM,
       p.LAST_NAME,
       p.FIRST_NAME,
       p.MIDDLE_NAME,
       p.BIRTH_DATE,
       p.DOC_ISSUE_DATE,
       p.DOC_SER,
       p.DOC_NUM,
       p.DOC_TYPE_ID,
       p.REGION_CODE
  FROM MI_0007 i
  JOIN MI_PERSON p
    ON p.PERSON_ID = i.PERSON_ID;


COMMENT ON TABLE V_MI_0007 IS
   'MI-edo. Представление элементов запросов проверки паспортных данных {$Id$}';
