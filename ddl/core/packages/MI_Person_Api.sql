CREATE OR REPLACE PACKAGE MI_Person_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {08.11.2026} Sulimoff$';


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Возвращает полную запись person.

      Если person не существует, функция сохраняет стандартную Oracle
      семантику SELECT INTO и бросает NO_DATA_FOUND.
   */
   FUNCTION get_Person (
      p_person_id IN MI_PERSON.PERSON_ID%TYPE
   )
      RETURN MI_PERSON%ROWTYPE;


   /*
      Возвращает последнюю созданную person для ICUSNUM.

      Если p_inf_id задан, учитываются только person, связанные с указанным
      видом сведений через MI_P2I. Если запись не найдена, возвращается NULL.
   */
   FUNCTION get_Last_Person_Id (
      p_icusnum IN MI_PERSON.ICUSNUM%TYPE,
      p_inf_id  IN MI_INF.INF_ID%TYPE DEFAULT NULL
   )
      RETURN MI_PERSON.PERSON_ID%TYPE;


   /*
      Находит person согласно matching profile вида сведений или создаёт
      новую запись и связывает её с MI_INF.

      Поддерживаемые matching profiles:
         INF_ID = 1       : SNILS;
         INF_ID IN (74,75): DOC_TYPE_ID, DOC_SER, DOC_NUM, DOC_ISSUE_DATE.

      Для остальных видов сведений, а также при неполном matching profile,
      всегда создаётся новая person. Бизнес-дубли разрешены контрактом.

      Функция не выполняет COMMIT. При технической ошибке откатываются
      только её собственные DML после внутреннего savepoint.

      p_person_json — JSON object с именами полей MI_PERSON в lowercase.
      PERSON_ID и CREATED_AT из JSON не используются.
      DATE-поля передаются как YYYY-MM-DD, числовые идентификаторы — целыми.

      Возвращаемые result_code:
         PERSON_CREATED;
         PERSON_FOUND;
         PERSON_INVALID_INF_ID;
         PERSON_INF_NOT_FOUND;
         PERSON_INVALID_JSON;
         PERSON_INVALID_DATA;
         PERSON_GET_OR_CREATE_FAILED.

      Успешный result содержит parameters:
         person_id, inf_id, created, linked, match_profile;
         icusnum — если он не NULL.
   */
   FUNCTION get_Or_Create (
      p_inf_id      IN MI_INF.INF_ID%TYPE,
      p_person_json IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t;


   /*
      Вариант для вызывающего кода, где ICUSNUM передаётся отдельно.

      p_icusnum добавляется только когда поле icusnum отсутствует в JSON.
      Явное "icusnum": null сохраняется как NULL.
   */
   FUNCTION get_Or_Create (
      p_inf_id      IN MI_INF.INF_ID%TYPE,
      p_icusnum     IN MI_PERSON.ICUSNUM%TYPE,
      p_person_json IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t;

END MI_Person_Api;
/

CREATE OR REPLACE PACKAGE BODY MI_Person_Api
IS

   cLogger CONSTANT VARCHAR2(64) := 'mi.person';

   cInf_Snils CONSTANT MI_INF.INF_ID%TYPE := 1;
   cInf_Doc_1 CONSTANT MI_INF.INF_ID%TYPE := 74;
   cInf_Doc_2 CONSTANT MI_INF.INF_ID%TYPE := 75;


   /*
      Package-level logger содержит только стабильную идентичность пакета.
      Контекст конкретной операции всегда находится в локальном l_log.
   */
   g_log MI_Logger_T :=
      MI_Logger_T(
         p_logger_name => cLogger
      );


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   FUNCTION exists_Inf (
      p_inf_id IN MI_INF.INF_ID%TYPE
   )
      RETURN BOOLEAN
   IS
      l_dummy PLS_INTEGER;
   BEGIN
      SELECT 1
        INTO l_dummy
        FROM MI_INF
       WHERE INF_ID = p_inf_id;

      RETURN TRUE;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN FALSE;
   END exists_Inf;


   ---------------------------------------------------------------------------
   FUNCTION success_Result (
      p_code       IN VARCHAR2,
      p_info       IN VARCHAR2,
      p_person_id  IN MI_PERSON.PERSON_ID%TYPE DEFAULT NULL,
      p_inf_id     IN MI_INF.INF_ID%TYPE       DEFAULT NULL,
      p_icusnum    IN MI_PERSON.ICUSNUM%TYPE   DEFAULT NULL,
      p_created    IN BOOLEAN                  DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.success(
            p_code => p_code,
            p_info => p_info
         );

      IF p_person_id IS NOT NULL THEN
         l_result.parameters('person_id') := TO_CHAR(p_person_id);
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_icusnum IS NOT NULL THEN
         l_result.parameters('icusnum') := TO_CHAR(p_icusnum);
      END IF;

      IF p_created IS NOT NULL THEN
         l_result.parameters('created') := MI_Utils.to_Char(p_created);
      END IF;

      RETURN l_result;
   END success_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_Result (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_inf_id   IN MI_INF.INF_ID%TYPE       DEFAULT NULL,
      p_icusnum  IN MI_PERSON.ICUSNUM%TYPE   DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.failure(
            p_code => p_code,
            p_info => p_info
         );

      IF p_inf_id IS NOT NULL THEN
         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);
      END IF;

      IF p_icusnum IS NOT NULL THEN
         l_result.parameters('icusnum') := TO_CHAR(p_icusnum);
      END IF;

      RETURN l_result;
   END failure_Result;


   ---------------------------------------------------------------------------
   FUNCTION normalized_Json (
      p_person_json IN CLOB
   )
      RETURN CLOB
   IS
   BEGIN
      IF p_person_json IS NULL THEN
         RETURN TO_CLOB('{}');
      END IF;

      RETURN p_person_json;
   END normalized_Json;


   ---------------------------------------------------------------------------
   FUNCTION is_Json_Object (
      p_person_json IN CLOB
   )
      RETURN BOOLEAN
   IS
      l_is_json PLS_INTEGER;
      l_prefix  VARCHAR2(4000);
   BEGIN
      SELECT CASE
                WHEN p_person_json IS JSON STRICT THEN 1
                ELSE 0
             END
        INTO l_is_json
        FROM DUAL;

      IF l_is_json = 0 THEN
         RETURN FALSE;
      END IF;

      l_prefix := DBMS_LOB.SUBSTR(p_person_json, 4000, 1);

      RETURN REGEXP_LIKE(l_prefix, '^[[:space:]]*[{]');
   END is_Json_Object;


   ---------------------------------------------------------------------------
   FUNCTION json_Has_Icusnum (
      p_person_json IN CLOB
   )
      RETURN BOOLEAN
   IS
      l_exists PLS_INTEGER;
   BEGIN
      SELECT CASE
                WHEN JSON_EXISTS(p_person_json, '$.icusnum') THEN 1
                ELSE 0
             END
        INTO l_exists
        FROM DUAL;

      RETURN l_exists = 1;
   END json_Has_Icusnum;


   ---------------------------------------------------------------------------
   FUNCTION parse_Number (
      p_value       IN VARCHAR2,
      p_field_name  IN VARCHAR2
   )
      RETURN NUMBER
   IS
      l_value VARCHAR2(4000);
   BEGIN
      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      l_value := TRIM(p_value);

      /*
         Все числовые поля MI_PERSON являются идентификаторами/кодами.
         Проверка до TO_NUMBER исключает зависимость от NLS и не допускает
         неявное округление дробного JSON value в NUMBER(p,0).
      */
      IF NOT REGEXP_LIKE(l_value, '^[+-]?[[:digit:]]+$') THEN
         RAISE VALUE_ERROR;
      END IF;

      RETURN TO_NUMBER(l_value);

   EXCEPTION
      WHEN OTHERS THEN
         RAISE_APPLICATION_ERROR(
            -20010,
            'Invalid numeric JSON field '
            || p_field_name
            || ': '
            || SUBSTR(p_value, 1, 100),
            TRUE
         );
   END parse_Number;


   ---------------------------------------------------------------------------
   FUNCTION parse_Date (
      p_value       IN VARCHAR2,
      p_field_name  IN VARCHAR2
   )
      RETURN DATE
   IS
   BEGIN
      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      RETURN TO_DATE(p_value, 'FXYYYY-MM-DD');

   EXCEPTION
      WHEN OTHERS THEN
         RAISE_APPLICATION_ERROR(
            -20011,
            'Invalid date JSON field '
            || p_field_name
            || ': '
            || SUBSTR(p_value, 1, 100)
            || ', expected YYYY-MM-DD',
            TRUE
         );
   END parse_Date;


   ---------------------------------------------------------------------------
   FUNCTION json_Build_Person (
      p_person_json IN CLOB
   )
      RETURN MI_PERSON%ROWTYPE
   IS
      l_person                MI_PERSON%ROWTYPE;

      l_icusnum               VARCHAR2(100);
      l_gender_id             VARCHAR2(100);
      l_ctzn_type_id          VARCHAR2(100);
      l_doc_type_id           VARCHAR2(100);

      l_doc_issue_date        VARCHAR2(100);
      l_doc_expire_date       VARCHAR2(100);
      l_doc_invalid_from      VARCHAR2(100);
      l_birth_date            VARCHAR2(100);
      l_death_date            VARCHAR2(100);
   BEGIN
      SELECT JSON_VALUE(p_person_json, '$.icusnum'),

             JSON_VALUE(p_person_json, '$.first_name'),
             JSON_VALUE(p_person_json, '$.last_name'),
             JSON_VALUE(p_person_json, '$.middle_name'),

             JSON_VALUE(p_person_json, '$.first_name_lat'),
             JSON_VALUE(p_person_json, '$.last_name_lat'),
             JSON_VALUE(p_person_json, '$.middle_name_lat'),

             JSON_VALUE(p_person_json, '$.gender_id'),

             JSON_VALUE(p_person_json, '$.ctzn_type_id'),
             JSON_VALUE(p_person_json, '$.ctzn_country_code'),

             JSON_VALUE(p_person_json, '$.inn'),
             JSON_VALUE(p_person_json, '$.snils'),

             JSON_VALUE(p_person_json, '$.doc_type_id'),
             JSON_VALUE(p_person_json, '$.doc_type_code'),
             JSON_VALUE(p_person_json, '$.doc_ser'),
             JSON_VALUE(p_person_json, '$.doc_num'),
             JSON_VALUE(p_person_json, '$.doc_issue_date'),
             JSON_VALUE(p_person_json, '$.doc_issuer_code'),
             JSON_VALUE(p_person_json, '$.doc_expire_date'),
             JSON_VALUE(p_person_json, '$.doc_issuer_name'),
             JSON_VALUE(p_person_json, '$.doc_invalid_from'),

             JSON_VALUE(p_person_json, '$.birth_date'),
             JSON_VALUE(p_person_json, '$.birth_date_raw'),
             JSON_VALUE(p_person_json, '$.birth_place'),

             JSON_VALUE(p_person_json, '$.death_date'),

             JSON_VALUE(p_person_json, '$.phone'),
             JSON_VALUE(p_person_json, '$.email'),

             JSON_VALUE(p_person_json, '$.region_code'),
             JSON_VALUE(p_person_json, '$.coid')
        INTO l_icusnum,

             l_person.first_name,
             l_person.last_name,
             l_person.middle_name,

             l_person.first_name_lat,
             l_person.last_name_lat,
             l_person.middle_name_lat,

             l_gender_id,

             l_ctzn_type_id,
             l_person.ctzn_country_code,

             l_person.inn,
             l_person.snils,

             l_doc_type_id,
             l_person.doc_type_code,
             l_person.doc_ser,
             l_person.doc_num,
             l_doc_issue_date,
             l_person.doc_issuer_code,
             l_doc_expire_date,
             l_person.doc_issuer_name,
             l_doc_invalid_from,

             l_birth_date,
             l_person.birth_date_raw,
             l_person.birth_place,

             l_death_date,

             l_person.phone,
             l_person.email,

             l_person.region_code,
             l_person.coid
        FROM DUAL;


      l_person.icusnum          := parse_Number(l_icusnum, 'icusnum');
      l_person.gender_id        := parse_Number(l_gender_id, 'gender_id');
      l_person.ctzn_type_id     := parse_Number(l_ctzn_type_id, 'ctzn_type_id');
      l_person.doc_type_id      := parse_Number(l_doc_type_id, 'doc_type_id');

      l_person.doc_issue_date   := parse_Date(l_doc_issue_date, 'doc_issue_date');
      l_person.doc_expire_date  := parse_Date(l_doc_expire_date, 'doc_expire_date');
      l_person.doc_invalid_from := parse_Date(l_doc_invalid_from, 'doc_invalid_from');
      l_person.birth_date       := parse_Date(l_birth_date, 'birth_date');
      l_person.death_date       := parse_Date(l_death_date, 'death_date');

      RETURN l_person;
   END json_Build_Person;


   ---------------------------------------------------------------------------
   FUNCTION find_By_Snils (
      p_inf_id  IN MI_INF.INF_ID%TYPE,
      p_snils   IN MI_PERSON.SNILS%TYPE,
      p_by_inf  IN BOOLEAN
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
      l_person_id MI_PERSON.PERSON_ID%TYPE;
   BEGIN
      IF p_by_inf THEN
         SELECT PERSON_ID
           INTO l_person_id
           FROM (
              SELECT p.PERSON_ID
                FROM MI_PERSON p
                JOIN MI_P2I i
                  ON i.PERSON_ID = p.PERSON_ID
               WHERE i.INF_ID = p_inf_id
                 AND p.SNILS = p_snils
               ORDER BY p.CREATED_AT DESC,
                        p.PERSON_ID DESC
           )
          WHERE ROWNUM = 1;
      ELSE
         SELECT PERSON_ID
           INTO l_person_id
           FROM (
              SELECT p.PERSON_ID
                FROM MI_PERSON p
               WHERE p.SNILS = p_snils
               ORDER BY p.CREATED_AT DESC,
                        p.PERSON_ID DESC
           )
          WHERE ROWNUM = 1;
      END IF;

      RETURN l_person_id;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN NULL;
   END find_By_Snils;


   ---------------------------------------------------------------------------
   FUNCTION find_By_Document (
      p_inf_id  IN MI_INF.INF_ID%TYPE,
      p_person  IN MI_PERSON%ROWTYPE,
      p_by_inf  IN BOOLEAN
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
      l_person_id MI_PERSON.PERSON_ID%TYPE;
   BEGIN
      IF p_by_inf THEN
         SELECT PERSON_ID
           INTO l_person_id
           FROM (
              SELECT p.PERSON_ID
                FROM MI_PERSON p
                JOIN MI_P2I i
                  ON i.PERSON_ID = p.PERSON_ID
               WHERE i.INF_ID = p_inf_id
                 AND p.DOC_TYPE_ID = p_person.doc_type_id
                 AND p.DOC_SER = p_person.doc_ser
                 AND p.DOC_NUM = p_person.doc_num
                 AND p.DOC_ISSUE_DATE = p_person.doc_issue_date
               ORDER BY p.CREATED_AT DESC,
                        p.PERSON_ID DESC
           )
          WHERE ROWNUM = 1;
      ELSE
         SELECT PERSON_ID
           INTO l_person_id
           FROM (
              SELECT p.PERSON_ID
                FROM MI_PERSON p
               WHERE p.DOC_TYPE_ID = p_person.doc_type_id
                 AND p.DOC_SER = p_person.doc_ser
                 AND p.DOC_NUM = p_person.doc_num
                 AND p.DOC_ISSUE_DATE = p_person.doc_issue_date
               ORDER BY p.CREATED_AT DESC,
                        p.PERSON_ID DESC
           )
          WHERE ROWNUM = 1;
      END IF;

      RETURN l_person_id;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN NULL;
   END find_By_Document;


   ---------------------------------------------------------------------------
   FUNCTION find_Person_Id (
      p_inf_id  IN MI_INF.INF_ID%TYPE,
      p_person  IN MI_PERSON%ROWTYPE,
      p_profile OUT VARCHAR2
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
      l_person_id MI_PERSON.PERSON_ID%TYPE;
   BEGIN
      p_profile := NULL;

      IF p_inf_id = cInf_Snils THEN
         p_profile := 'snils';

         IF p_person.snils IS NULL THEN
            RETURN NULL;
         END IF;

         l_person_id :=
            find_By_Snils(
               p_inf_id => p_inf_id,
               p_snils  => p_person.snils,
               p_by_inf => TRUE
            );

         IF l_person_id IS NULL THEN
            l_person_id :=
               find_By_Snils(
                  p_inf_id => p_inf_id,
                  p_snils  => p_person.snils,
                  p_by_inf => FALSE
               );
         END IF;

         RETURN l_person_id;
      END IF;


      IF p_inf_id IN (cInf_Doc_1, cInf_Doc_2) THEN
         p_profile := 'document';

         IF p_person.doc_type_id IS NULL
            OR p_person.doc_ser IS NULL
            OR p_person.doc_num IS NULL
            OR p_person.doc_issue_date IS NULL
         THEN
            RETURN NULL;
         END IF;

         l_person_id :=
            find_By_Document(
               p_inf_id => p_inf_id,
               p_person => p_person,
               p_by_inf => TRUE
            );

         IF l_person_id IS NULL THEN
            l_person_id :=
               find_By_Document(
                  p_inf_id => p_inf_id,
                  p_person => p_person,
                  p_by_inf => FALSE
               );
         END IF;

         RETURN l_person_id;
      END IF;


      p_profile := 'none';

      RETURN NULL;
   END find_Person_Id;


   ---------------------------------------------------------------------------
   FUNCTION insert_Person (
      p_person IN MI_PERSON%ROWTYPE
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
      l_person_id MI_PERSON.PERSON_ID%TYPE;
   BEGIN
      INSERT INTO MI_PERSON (
         ICUSNUM,

         FIRST_NAME,
         LAST_NAME,
         MIDDLE_NAME,

         FIRST_NAME_LAT,
         LAST_NAME_LAT,
         MIDDLE_NAME_LAT,

         GENDER_ID,

         CTZN_TYPE_ID,
         CTZN_COUNTRY_CODE,

         INN,
         SNILS,

         DOC_TYPE_ID,
         DOC_TYPE_CODE,
         DOC_SER,
         DOC_NUM,
         DOC_ISSUE_DATE,
         DOC_ISSUER_CODE,
         DOC_EXPIRE_DATE,
         DOC_ISSUER_NAME,
         DOC_INVALID_FROM,

         BIRTH_DATE,
         BIRTH_DATE_RAW,
         BIRTH_PLACE,

         DEATH_DATE,

         PHONE,
         EMAIL,

         REGION_CODE,
         COID
      )
      VALUES (
         p_person.icusnum,

         p_person.first_name,
         p_person.last_name,
         p_person.middle_name,

         p_person.first_name_lat,
         p_person.last_name_lat,
         p_person.middle_name_lat,

         p_person.gender_id,

         p_person.ctzn_type_id,
         p_person.ctzn_country_code,

         p_person.inn,
         p_person.snils,

         p_person.doc_type_id,
         p_person.doc_type_code,
         p_person.doc_ser,
         p_person.doc_num,
         p_person.doc_issue_date,
         p_person.doc_issuer_code,
         p_person.doc_expire_date,
         p_person.doc_issuer_name,
         p_person.doc_invalid_from,

         p_person.birth_date,
         p_person.birth_date_raw,
         p_person.birth_place,

         p_person.death_date,

         p_person.phone,
         p_person.email,

         p_person.region_code,
         p_person.coid
      )
      RETURNING PERSON_ID
           INTO l_person_id;

      RETURN l_person_id;
   END insert_Person;


   ---------------------------------------------------------------------------
   PROCEDURE link_Person_To_Inf (
      p_person_id  IN MI_PERSON.PERSON_ID%TYPE,
      p_inf_id     IN MI_INF.INF_ID%TYPE,
      p_linked     OUT BOOLEAN
   )
   IS
   BEGIN
      p_linked := FALSE;

      BEGIN
         INSERT INTO MI_P2I (
            PERSON_ID,
            INF_ID
         )
         VALUES (
            p_person_id,
            p_inf_id
         );

         p_linked := TRUE;

      EXCEPTION
         WHEN DUP_VAL_ON_INDEX THEN
            /*
               Идемпотентная связь: существующая пара PERSON_ID/INF_ID
               является успешным результатом.
            */
            NULL;
      END;
   END link_Person_To_Inf;


   ---------------------------------------------------------------------------
   FUNCTION get_Or_Create_Core (
      p_inf_id                    IN MI_INF.INF_ID%TYPE,
      p_default_icusnum           IN MI_PERSON.ICUSNUM%TYPE,
      p_use_default_when_absent   IN BOOLEAN,
      p_person_json               IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_json        CLOB;
      l_person      MI_PERSON%ROWTYPE;
      l_person_id   MI_PERSON.PERSON_ID%TYPE;
      l_profile     VARCHAR2(30);

      l_created     BOOLEAN := FALSE;
      l_linked      BOOLEAN := FALSE;
      l_dml_started BOOLEAN := FALSE;

      l_result      MI_ResultCtx.exec_Result_t;
      l_sqlcode     PLS_INTEGER;
      l_sqlerrm     VARCHAR2(2000);

      l_log         MI_Logger_T :=
         MI_Logger_T(
            p_logger_name => g_log.logger_name,
            p_inf_id      => p_inf_id,
            p_icusnum     => p_default_icusnum
         );
   BEGIN
      IF p_inf_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'PERSON_INVALID_INF_ID',
               p_info => 'p_inf_id must not be NULL'
            );
      END IF;


      IF NOT exists_Inf(p_inf_id) THEN
         RETURN
            failure_Result(
               p_code   => 'PERSON_INF_NOT_FOUND',
               p_info   => 'Не найден вид сведений inf_id=' || p_inf_id,
               p_inf_id => p_inf_id
            );
      END IF;


      l_json := normalized_Json(p_person_json);

      IF NOT is_Json_Object(l_json) THEN
         RETURN
            failure_Result(
               p_code   => 'PERSON_INVALID_JSON',
               p_info   => 'p_person_json must be a valid JSON object',
               p_inf_id => p_inf_id,
               p_icusnum => p_default_icusnum
            );
      END IF;


      BEGIN
         l_person := json_Build_Person(l_json);

         IF p_use_default_when_absent
            AND NOT json_Has_Icusnum(l_json)
         THEN
            l_person.icusnum := p_default_icusnum;
         END IF;

      EXCEPTION
         WHEN OTHERS THEN
            l_sqlcode := SQLCODE;
            l_sqlerrm := SQLERRM;

            l_log.error(
               p_message_text => 'Invalid person JSON data',
               p_action_code  => 'parse',
               p_details_text => TO_CLOB(l_sqlerrm)
            );

            l_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => l_sqlcode,
                  p_sqlerrm => l_sqlerrm,
                  p_code    => 'PERSON_INVALID_DATA',
                  p_info    => 'Некорректные данные person'
               );

            l_result.parameters('inf_id') := TO_CHAR(p_inf_id);

            IF p_default_icusnum IS NOT NULL THEN
               l_result.parameters('icusnum') := TO_CHAR(p_default_icusnum);
            END IF;

            RETURN l_result;
      END;


      l_log.icusnum := l_person.icusnum;

      l_person_id :=
         find_Person_Id(
            p_inf_id  => p_inf_id,
            p_person  => l_person,
            p_profile => l_profile
         );

      l_log.debug(
         p_message_text => 'Person matching completed',
         p_action_code  => 'find',
         p_details_text => TO_CLOB(
            'profile=' || NVL(l_profile, '<NULL>')
            || ', person_id=' || NVL(TO_CHAR(l_person_id), '<NULL>')
         )
      );


      SAVEPOINT MI_PERSON_API_GOC_DML;
      l_dml_started := TRUE;


      IF l_person_id IS NULL THEN
         l_person_id := insert_Person(l_person);
         l_created   := TRUE;
      END IF;


      l_log.person_id := l_person_id;

      link_Person_To_Inf(
         p_person_id => l_person_id,
         p_inf_id    => p_inf_id,
         p_linked    => l_linked
      );


      IF l_created THEN
         l_log.info(
            p_message_text => 'Person created',
            p_action_code  => 'create'
         );

         l_result :=
            success_Result(
               p_code      => 'PERSON_CREATED',
               p_info      => 'Person created',
               p_person_id => l_person_id,
               p_inf_id    => p_inf_id,
               p_icusnum   => l_person.icusnum,
               p_created   => TRUE
            );
      ELSE
         l_log.info(
            p_message_text => 'Person found',
            p_action_code  => 'find'
         );

         l_result :=
            success_Result(
               p_code      => 'PERSON_FOUND',
               p_info      => 'Person found',
               p_person_id => l_person_id,
               p_inf_id    => p_inf_id,
               p_icusnum   => l_person.icusnum,
               p_created   => FALSE
            );
      END IF;


      l_result.parameters('linked') := MI_Utils.to_Char(l_linked);
      l_result.parameters('match_profile') := NVL(l_profile, 'none');

      RETURN l_result;

   EXCEPTION
      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         IF l_dml_started THEN
            ROLLBACK TO MI_PERSON_API_GOC_DML;
         END IF;

         l_log.person_id := l_person_id;

         l_log.error(
            p_message_text => 'get_Or_Create failed',
            p_action_code  => 'get_or_create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'PERSON_GET_OR_CREATE_FAILED',
               p_info    => 'Не удалось найти или создать person'
            );

         l_result.parameters('inf_id') := TO_CHAR(p_inf_id);

         IF l_person_id IS NOT NULL THEN
            l_result.parameters('person_id') := TO_CHAR(l_person_id);
         END IF;

         IF l_person.icusnum IS NOT NULL THEN
            l_result.parameters('icusnum') := TO_CHAR(l_person.icusnum);
         END IF;

         RETURN l_result;
   END get_Or_Create_Core;


   ---------------------------------------------------------------------------
   FUNCTION get_Person (
      p_person_id IN MI_PERSON.PERSON_ID%TYPE
   )
      RETURN MI_PERSON%ROWTYPE
   IS
      l_person MI_PERSON%ROWTYPE;
   BEGIN
      SELECT *
        INTO l_person
        FROM MI_PERSON
       WHERE PERSON_ID = p_person_id;

      RETURN l_person;
   END get_Person;


   ---------------------------------------------------------------------------
   FUNCTION get_Last_Person_Id (
      p_icusnum IN MI_PERSON.ICUSNUM%TYPE,
      p_inf_id  IN MI_INF.INF_ID%TYPE DEFAULT NULL
   )
      RETURN MI_PERSON.PERSON_ID%TYPE
   IS
      l_person_id MI_PERSON.PERSON_ID%TYPE;
   BEGIN
      IF p_icusnum IS NULL THEN
         RETURN NULL;
      END IF;

      SELECT PERSON_ID
        INTO l_person_id
        FROM (
           SELECT p.PERSON_ID
             FROM MI_PERSON p
            WHERE p.ICUSNUM = p_icusnum
              AND (
                     p_inf_id IS NULL
                     OR EXISTS (
                           SELECT NULL
                             FROM MI_P2I i
                            WHERE i.PERSON_ID = p.PERSON_ID
                              AND i.INF_ID = p_inf_id
                        )
                  )
            ORDER BY p.CREATED_AT DESC,
                     p.PERSON_ID DESC
        )
       WHERE ROWNUM = 1;

      RETURN l_person_id;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         RETURN NULL;
   END get_Last_Person_Id;


   ---------------------------------------------------------------------------
   FUNCTION get_Or_Create (
      p_inf_id      IN MI_INF.INF_ID%TYPE,
      p_person_json IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
   BEGIN
      RETURN
         get_Or_Create_Core(
            p_inf_id                  => p_inf_id,
            p_default_icusnum         => NULL,
            p_use_default_when_absent => FALSE,
            p_person_json             => p_person_json
         );
   END get_Or_Create;


   ---------------------------------------------------------------------------
   FUNCTION get_Or_Create (
      p_inf_id      IN MI_INF.INF_ID%TYPE,
      p_icusnum     IN MI_PERSON.ICUSNUM%TYPE,
      p_person_json IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
   BEGIN
      RETURN
         get_Or_Create_Core(
            p_inf_id                  => p_inf_id,
            p_default_icusnum         => p_icusnum,
            p_use_default_when_absent => TRUE,
            p_person_json             => p_person_json
         );
   END get_Or_Create;

END MI_Person_Api;
/
