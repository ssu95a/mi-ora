CREATE OR REPLACE PACKAGE MI_0202_Api
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {19.11.2026} Sulimoff$';


   RET_FAIL CONSTANT PLS_INTEGER := -1;
   RET_OK   CONSTANT PLS_INTEGER :=  0;


   /*
      Oracle-эквивалент составного результата MI_0202_srv.get_item_row.

      Коллекции p_links и p_addresses имеют одинаковые индексы: элемент
      MI_P2A с индексом N относится к MI_ADDR с тем же индексом N.
   */
   TYPE P2A_Row_List_t IS TABLE OF MI_P2A%ROWTYPE
      INDEX BY PLS_INTEGER;

   TYPE Address_Row_List_t IS TABLE OF MI_ADDR%ROWTYPE
      INDEX BY PLS_INTEGER;


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Создаёт item 0202 для существующего request.

      Процедура не выполняет COMMIT/ROLLBACK. При ошибке откатывает только
      собственную работу через DCL savepoint.
   */
   PROCEDURE create_Item (
      p_req_id        IN  MI_REQ.REQ_ID%TYPE,
      p_payload_text  IN  CLOB,

      p_itm_id        OUT MI_0202.ITM_ID%TYPE,
      p_ret_code      OUT NUMBER,
      p_ret_info      OUT VARCHAR2
   );


   /*
      Полный контракт PG apply_request с идентификаторами созданных строк.

      Вся операция атомарна. В отличие от PG-порта автономные транзакции не
      используются: Java/caller владеет COMMIT/ROLLBACK, пакет — только своим
      savepoint. При любом отказе ФПЗ созданные MI_REQ/MI_0202/person/address
      откатываются до savepoint.
   */
   PROCEDURE apply_Request (
      p_message_uuid           IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid  IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id         IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time           IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text           IN  CLOB,

      p_req_id                 OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                 OUT MI_0202.ITM_ID%TYPE,
      p_ret_code               OUT NUMBER,
      p_ret_info               OUT VARCHAR2
   );


   /* JDBC wrapper для общего Java business handler. */
   PROCEDURE apply_Request (
      p_message_uuid           IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid  IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id         IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time           IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text           IN  CLOB,

      p_ret_code               OUT NUMBER,
      p_ret_info               OUT VARCHAR2
   );


   /* Oracle-эквивалент MI_0202_srv.get_item_row. */
   PROCEDURE get_Item_Row (
      p_itm_id      IN  MI_0202.ITM_ID%TYPE,
      p_item        OUT MI_0202%ROWTYPE,
      p_person      OUT MI_PERSON%ROWTYPE,
      p_links       OUT P2A_Row_List_t,
      p_addresses   OUT Address_Row_List_t
   );


   /* Oracle-эквивалент MI_0202_srv.get_item_json. */
   FUNCTION get_Item_Json (
      p_itm_id IN MI_0202.ITM_ID%TYPE
   )
      RETURN CLOB;

END MI_0202_Api;
/


CREATE OR REPLACE PACKAGE BODY MI_0202_Api
IS

   cInf_Id    CONSTANT MI_INF.INF_ID%TYPE := 202;
   cFps_Check CONSTANT VARCHAR2(100)       := 'SMEV.202.CHECK';
   cLogger    CONSTANT VARCHAR2(64)        := 'mi.0202';

   cApp_Error_Code CONSTANT PLS_INTEGER := -20003;

   e_Rollback_Failed EXCEPTION;
   PRAGMA EXCEPTION_INIT(e_Rollback_Failed, -20003);


   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => $$PLSQL_UNIT
      );


   ---------------------------------------------------------------------------
   PROCEDURE rollback_Or_Raise (
      p_name  IN OUT NOCOPY DCL.T_Name,
      p_log   IN            MI_Logger_T
   )
   IS
      l_rolled_back BOOLEAN;
   BEGIN
      l_rolled_back :=
         MI_Transaction.rollback_Savepoint(
            p_name => p_name,
            p_log  => p_log
         );

      IF l_rolled_back IS NULL OR NOT l_rolled_back THEN
         p_log.fatal(
            p_message_text => 'MI_0202 savepoint rollback failed',
            p_action_code  => 'rollback'
         );

         /*
            Java не должен дойти до commit после неуспешного локального
            rollback. Для всех client-visible application errors пакета
            используется один закреплённый номер; identity находится в text.
         */
         RAISE_APPLICATION_ERROR(
            cApp_Error_Code,
            'MI_0202_ROLLBACK_FAILED: local savepoint rollback failed'
         );
      END IF;
   END rollback_Or_Raise;


   TYPE Person_Data_t IS RECORD
   (
      last_name        MI_PERSON.LAST_NAME%TYPE,
      first_name       MI_PERSON.FIRST_NAME%TYPE,
      middle_name      MI_PERSON.MIDDLE_NAME%TYPE,
      inn              MI_PERSON.INN%TYPE,
      snils            MI_PERSON.SNILS%TYPE,
      birth_date       VARCHAR2(20),

      doc_type_id      MI_PERSON.DOC_TYPE_ID%TYPE,
      doc_type_code    MI_PERSON.DOC_TYPE_CODE%TYPE,
      doc_ser          MI_PERSON.DOC_SER%TYPE,
      doc_num          MI_PERSON.DOC_NUM%TYPE,
      doc_issue_date   VARCHAR2(20),
      doc_issuer_code  MI_PERSON.DOC_ISSUER_CODE%TYPE,
      doc_issuer_name  MI_PERSON.DOC_ISSUER_NAME%TYPE
   );


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   FUNCTION success_Result (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_req_id   IN MI_REQ.REQ_ID%TYPE     DEFAULT NULL,
      p_itm_id   IN MI_0202.ITM_ID%TYPE    DEFAULT NULL
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

      MI_ResultCtx.put_Number(l_result, 'ret_code', RET_OK);
      MI_ResultCtx.put_Number(l_result, 'req_id', p_req_id);
      MI_ResultCtx.put_Number(l_result, 'itm_id', p_itm_id);

      RETURN l_result;
   END success_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_Result (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_details  IN CLOB DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.failure(
            p_code    => p_code,
            p_info    => p_info,
            p_details => p_details
         );

      MI_ResultCtx.put_Number(l_result, 'ret_code', RET_FAIL);

      RETURN l_result;
   END failure_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_From_Cause (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_cause    IN MI_ResultCtx.exec_Result_t,
      p_details  IN CLOB DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      l_result :=
         MI_ResultCtx.wrap_Exception(
            p_cause   => p_cause,
            p_code    => p_code,
            p_info    => p_info,
            p_details => p_details
         );

      MI_ResultCtx.put_Number(l_result, 'ret_code', RET_FAIL);

      RETURN l_result;
   END failure_From_Cause;


   ---------------------------------------------------------------------------
   FUNCTION null_If_Empty (
      p_value IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN NULLIF(TRIM(p_value), '');
   END null_If_Empty;


   ---------------------------------------------------------------------------
   FUNCTION is_Json_Object (
      p_json IN CLOB
   )
      RETURN BOOLEAN
   IS
      l_is_json PLS_INTEGER;
      l_prefix  VARCHAR2(4000);
   BEGIN
      IF p_json IS NULL THEN
         RETURN FALSE;
      END IF;

      SELECT CASE
                WHEN p_json IS JSON STRICT THEN 1
                ELSE 0
             END
        INTO l_is_json
        FROM dual;

      IF l_is_json = 0 THEN
         RETURN FALSE;
      END IF;

      l_prefix := LTRIM(DBMS_LOB.SUBSTR(p_json, 4000, 1));

      RETURN SUBSTR(l_prefix, 1, 1) = '{';
   END is_Json_Object;


   ---------------------------------------------------------------------------
   FUNCTION parse_Date (
      p_value IN VARCHAR2
   )
      RETURN DATE
   IS
   BEGIN
      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      RETURN TO_DATE(p_value, 'FXYYYY-MM-DD');
   END parse_Date;


   ---------------------------------------------------------------------------
   FUNCTION parse_Timestamp_Tz (
      p_value IN VARCHAR2
   )
      RETURN TIMESTAMP WITH TIME ZONE
   IS
      l_value VARCHAR2(100);
   BEGIN
      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      l_value := TRIM(p_value);

      IF SUBSTR(l_value, -1) IN ('Z', 'z') THEN
         l_value := SUBSTR(l_value, 1, LENGTH(l_value) - 1) || '+00:00';
      END IF;

      BEGIN
         RETURN TO_TIMESTAMP_TZ(
                   l_value,
                   'YYYY-MM-DD"T"HH24:MI:SS.FFTZH:TZM'
                );
      EXCEPTION
         WHEN OTHERS THEN
            NULL;
      END;

      BEGIN
         RETURN TO_TIMESTAMP_TZ(
                   l_value,
                   'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'
                );
      EXCEPTION
         WHEN OTHERS THEN
            NULL;
      END;

      BEGIN
         RETURN TO_TIMESTAMP_TZ(
                   l_value,
                   'YYYY-MM-DD HH24:MI:SS.FFTZH:TZM'
                );
      EXCEPTION
         WHEN OTHERS THEN
            NULL;
      END;

      BEGIN
         RETURN FROM_TZ(
                   TO_TIMESTAMP(l_value, 'YYYY-MM-DD"T"HH24:MI:SS.FF'),
                   SESSIONTIMEZONE
                );
      EXCEPTION
         WHEN OTHERS THEN
            RETURN FROM_TZ(
                      TO_TIMESTAMP(l_value, 'YYYY-MM-DD"T"HH24:MI:SS'),
                      SESSIONTIMEZONE
                   );
      END;
   END parse_Timestamp_Tz;


   ---------------------------------------------------------------------------
   FUNCTION hex_Digit (
      p_value IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN SUBSTR('0123456789ABCDEF', p_value + 1, 1);
   END hex_Digit;


   ---------------------------------------------------------------------------
   FUNCTION json_Escape (
      p_value IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
      l_result VARCHAR2(32767);
      l_char   VARCHAR2(1);
      l_code   PLS_INTEGER;
   BEGIN
      IF p_value IS NULL THEN
         RETURN NULL;
      END IF;

      FOR i IN 1 .. LENGTH(p_value) LOOP
         l_char := SUBSTR(p_value, i, 1);
         l_code := ASCII(l_char);

         CASE l_char
            WHEN '"'  THEN l_result := l_result || '\"';
            WHEN '\'  THEN l_result := l_result || '\\';
            WHEN CHR(8)  THEN l_result := l_result || '\b';
            WHEN CHR(9)  THEN l_result := l_result || '\t';
            WHEN CHR(10) THEN l_result := l_result || '\n';
            WHEN CHR(12) THEN l_result := l_result || '\f';
            WHEN CHR(13) THEN l_result := l_result || '\r';
            ELSE
               IF l_code BETWEEN 0 AND 31 THEN
                  l_result :=
                       l_result
                    || '\u00'
                    || hex_Digit(TRUNC(l_code / 16))
                    || hex_Digit(MOD(l_code, 16));
               ELSE
                  l_result := l_result || l_char;
               END IF;
         END CASE;
      END LOOP;

      RETURN l_result;
   END json_Escape;


   ---------------------------------------------------------------------------
   FUNCTION json_String (
      p_value IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      IF p_value IS NULL THEN
         RETURN 'null';
      END IF;

      RETURN '"' || json_Escape(p_value) || '"';
   END json_String;


   ---------------------------------------------------------------------------
   FUNCTION json_Person (
      p_person IN Person_Data_t
   )
      RETURN CLOB
   IS
      l_json VARCHAR2(32767);
   BEGIN
      l_json :=
           '{'
        || '"last_name":'       || json_String(p_person.last_name)
        || ',"first_name":'     || json_String(p_person.first_name)
        || ',"middle_name":'    || json_String(p_person.middle_name)
        || ',"inn":'            || json_String(p_person.inn)
        || ',"snils":'          || json_String(p_person.snils)
        || ',"birth_date":'     || json_String(p_person.birth_date)
        || ',"doc_type_id":'
        || CASE
              WHEN p_person.doc_type_id IS NULL THEN 'null'
              ELSE TO_CHAR(p_person.doc_type_id, 'TM9')
           END
        || ',"doc_type_code":'  || json_String(p_person.doc_type_code)
        || ',"doc_ser":'        || json_String(p_person.doc_ser)
        || ',"doc_num":'        || json_String(p_person.doc_num)
        || ',"doc_issue_date":' || json_String(p_person.doc_issue_date)
        || ',"doc_issuer_code":'|| json_String(p_person.doc_issuer_code)
        || ',"doc_issuer_name":'|| json_String(p_person.doc_issuer_name)
        || '}';

      RETURN TO_CLOB(l_json);
   END json_Person;


   ---------------------------------------------------------------------------
   PROCEDURE read_Person (
      p_person_json IN  VARCHAR2,
      p_person      OUT Person_Data_t
   )
   IS
   BEGIN
      SELECT null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.lastName' RETURNING VARCHAR2(50) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.firstName' RETURNING VARCHAR2(50) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.middleName' RETURNING VARCHAR2(50) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.inn' RETURNING VARCHAR2(13) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.snils' RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.birthday' RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentType.code'
                   RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentSeries'
                   RETURNING VARCHAR2(10) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentNumber'
                   RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentIssueDate'
                   RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentIssuer.code'
                   RETURNING VARCHAR2(20) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_person_json,
                   '$.personalDoc.documentIssuer.name'
                   RETURNING VARCHAR2(500) ERROR ON ERROR
                )
             )
        INTO p_person.last_name,
             p_person.first_name,
             p_person.middle_name,
             p_person.inn,
             p_person.snils,
             p_person.birth_date,
             p_person.doc_type_code,
             p_person.doc_ser,
             p_person.doc_num,
             p_person.doc_issue_date,
             p_person.doc_issuer_code,
             p_person.doc_issuer_name
        FROM dual;

      IF p_person.doc_type_code IS NOT NULL THEN
         SELECT MIN(PUD.IPUDID)
           INTO p_person.doc_type_id
           FROM PUD
          WHERE PUD.CPUDCODE9 = p_person.doc_type_code
            AND PUD.IPUDUSE = 0;
      END IF;
   END read_Person;


   ---------------------------------------------------------------------------
   PROCEDURE save_Address (
      p_req_id      IN MI_REQ.REQ_ID%TYPE,
      p_itm_id      IN MI_0202.ITM_ID%TYPE,
      p_person_id   IN MI_PERSON.PERSON_ID%TYPE,
      p_addr_json   IN VARCHAR2,
      p_itype       IN MI_P2A.ITYPE%TYPE
   )
   IS
      l_addr_id      MI_ADDR.ADDR_ID%TYPE;

      l_postcode     MI_ADDR.CPOSTCODE%TYPE;
      l_region_code  MI_ADDR.CREGION_CODE%TYPE;
      l_region_type  MI_ADDR.CREGION_TYPE%TYPE;
      l_region_name  MI_ADDR.CREGION_NAME%TYPE;
      l_area_type    MI_ADDR.CAREA_TYPE%TYPE;
      l_area_name    MI_ADDR.CAREA_NAME%TYPE;
      l_city_type    MI_ADDR.CCITY_TYPE%TYPE;
      l_city_name    MI_ADDR.CCITY_NAME%TYPE;
      l_place_type   MI_ADDR.CPLACE_TYPE%TYPE;
      l_place_name   MI_ADDR.CPLACE_NAME%TYPE;
      l_street_type  MI_ADDR.CSTREET_TYPE%TYPE;
      l_street_name  MI_ADDR.CSTREET_NAME%TYPE;
      l_house        MI_ADDR.CHOUSE%TYPE;
      l_build        MI_ADDR.CBUILD%TYPE;
      l_apart        MI_ADDR.CAPART%TYPE;
      l_fias_code    MI_ADDR.CFIAS_CODE%TYPE;
      l_strct        MI_ADDR.CSTRCT%TYPE;
      l_full_address MI_ADDR.CUNSTRCT_ADDR%TYPE;

      l_dbeg_reg     MI_P2A.DBEG_REG%TYPE;
      l_dend_reg     MI_P2A.DEND_REG%TYPE;
   BEGIN
      IF p_addr_json IS NULL THEN
         RETURN;
      END IF;

      SELECT null_If_Empty(JSON_VALUE(p_addr_json, '$.postalCode' RETURNING VARCHAR2(6) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.region.code' RETURNING VARCHAR2(2) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.region.type' RETURNING VARCHAR2(30) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.region.value' RETURNING VARCHAR2(50) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.area.type' RETURNING VARCHAR2(30) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.area.value' RETURNING VARCHAR2(100) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.city.type' RETURNING VARCHAR2(30) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.city.value' RETURNING VARCHAR2(50) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.place.type' RETURNING VARCHAR2(30) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.place.value' RETURNING VARCHAR2(250) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.street.type' RETURNING VARCHAR2(30) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.street.value' RETURNING VARCHAR2(200) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.house' RETURNING VARCHAR2(100) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.building1' RETURNING VARCHAR2(100) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.apartment' RETURNING VARCHAR2(100) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.fiasCode' RETURNING VARCHAR2(36) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.building2' RETURNING VARCHAR2(100) ERROR ON ERROR)),
             null_If_Empty(JSON_VALUE(p_addr_json, '$.fullAddress' RETURNING VARCHAR2(250) ERROR ON ERROR)),
             parse_Date(
                null_If_Empty(
                   JSON_VALUE(
                      p_addr_json,
                      '$.startDateRegistration'
                      RETURNING VARCHAR2(20) ERROR ON ERROR
                   )
                )
             ),
             parse_Date(
                null_If_Empty(
                   JSON_VALUE(
                      p_addr_json,
                      '$.endDateRegistration'
                      RETURNING VARCHAR2(20) ERROR ON ERROR
                   )
                )
             )
        INTO l_postcode,
             l_region_code,
             l_region_type,
             l_region_name,
             l_area_type,
             l_area_name,
             l_city_type,
             l_city_name,
             l_place_type,
             l_place_name,
             l_street_type,
             l_street_name,
             l_house,
             l_build,
             l_apart,
             l_fias_code,
             l_strct,
             l_full_address,
             l_dbeg_reg,
             l_dend_reg
        FROM dual;

      IF l_full_address IS NULL
         AND l_postcode IS NULL
         AND l_region_name IS NULL
         AND l_city_name IS NULL
         AND l_street_name IS NULL
      THEN
         RETURN;
      END IF;

      INSERT INTO MI_ADDR (
         REQ_ID,
         ITM_ID,
         CPOSTCODE,
         CREGION_CODE,
         CREGION_TYPE,
         CREGION_NAME,
         CAREA_TYPE,
         CAREA_NAME,
         CCITY_TYPE,
         CCITY_NAME,
         CPLACE_TYPE,
         CPLACE_NAME,
         CSTREET_TYPE,
         CSTREET_NAME,
         CHOUSE,
         CBUILD,
         CAPART,
         CFIAS_CODE,
         CSTRCT,
         CUNSTRCT_ADDR
      )
      VALUES (
         p_req_id,
         p_itm_id,
         l_postcode,
         l_region_code,
         l_region_type,
         l_region_name,
         l_area_type,
         l_area_name,
         l_city_type,
         l_city_name,
         l_place_type,
         l_place_name,
         l_street_type,
         l_street_name,
         l_house,
         l_build,
         l_apart,
         l_fias_code,
         l_strct,
         l_full_address
      )
      RETURNING ADDR_ID
           INTO l_addr_id;

      INSERT INTO MI_P2A (
         PERSON_ID,
         ADDR_ID,
         ITYPE,
         DBEG_REG,
         DEND_REG
      )
      VALUES (
         p_person_id,
         l_addr_id,
         p_itype,
         l_dbeg_reg,
         l_dend_reg
      );

      g_log.variable_Value(
         p_variable_name => 'addr_id',
         p_value_text     => TO_CHAR(l_addr_id) || ' (itype=' || TO_CHAR(p_itype) || ')'
      );
   END save_Address;


   ---------------------------------------------------------------------------
   FUNCTION create_Item_Impl (
      p_req_id        IN MI_REQ.REQ_ID%TYPE,
      p_payload_text  IN CLOB
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
      l_person_json       VARCHAR2(4000);
      l_foreign_person    VARCHAR2(4000);
      l_person            Person_Data_t;
      l_person_api_json   CLOB;
      l_person_result     MI_ResultCtx.exec_Result_t;
      l_person_id         MI_PERSON.PERSON_ID%TYPE;

      l_item_id           MI_0202.ITM_ID%TYPE;
      l_kind              MI_0202.KIND%TYPE;
      l_agreement         MI_0202.AGREEMENT_TYPE%TYPE;
      l_order_id          MI_0202.ORDER_ID%TYPE;
      l_order_timestamp   TIMESTAMP WITH TIME ZONE;
      l_order_time_text   VARCHAR2(100);
      l_subservice_code   MI_0202.SUBSERVICE_CODE%TYPE;
      l_subservice_title  MI_0202.SUBSERVICE_TITLE%TYPE;

      l_any_data          VARCHAR2(4000);
      l_variant_data      VARCHAR2(4000);
      l_subservice_data   CLOB;
      l_documents         CLOB;

      l_address           VARCHAR2(4000);
      l_temp_address      VARCHAR2(4000);
      l_fact_address      VARCHAR2(4000);

      l_result            MI_ResultCtx.exec_Result_t;
      l_savepoint_name    DCL.T_Name;
      l_dml_started       BOOLEAN := FALSE;
      l_sqlcode           PLS_INTEGER;
      l_sqlerrm           VARCHAR2(2000);

      l_log               MI_Logger_T := g_log;
   BEGIN
      l_log.context(
         p_inf_id => cInf_Id,
         p_req_id => p_req_id
      );

      IF p_req_id IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'MI_0202_INVALID_REQ_ID',
               p_info => 'p_req_id must not be NULL'
            );
      END IF;

      IF NOT is_Json_Object(p_payload_text) THEN
         RETURN
            failure_Result(
               p_code => 'MI_0202_INVALID_PAYLOAD',
               p_info => 'p_payload_text must be a strict JSON object'
            );
      END IF;

      SELECT null_If_Empty(
                JSON_VALUE(
                   p_payload_text,
                   '$.kind' RETURNING VARCHAR2(50) ERROR ON ERROR
                )
             ),
             JSON_VALUE(
                p_payload_text,
                '$.orderId' RETURNING NUMBER ERROR ON ERROR
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_payload_text,
                   '$.orderTimestamp' RETURNING VARCHAR2(100) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_payload_text,
                   '$.subservice.code' RETURNING VARCHAR2(100) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_payload_text,
                   '$.subservice.title' RETURNING VARCHAR2(500) ERROR ON ERROR
                )
             ),
             null_If_Empty(
                JSON_VALUE(
                   p_payload_text,
                   '$.subservice.anyData.Product_Type.What_kind_agreement'
                   RETURNING VARCHAR2(50) ERROR ON ERROR
                )
             ),
             JSON_QUERY(
                p_payload_text,
                '$.subjects[0].person'
                RETURNING VARCHAR2(4000) ERROR ON ERROR
             ),
             JSON_QUERY(
                p_payload_text,
                '$.subjects[0].foreignPerson'
                RETURNING VARCHAR2(4000) ERROR ON ERROR
             ),
             JSON_QUERY(
                p_payload_text,
                '$.subservice.anyData'
                RETURNING VARCHAR2(4000) ERROR ON ERROR
             ),
             JSON_QUERY(
                p_payload_text,
                '$.subservice.variantData'
                RETURNING VARCHAR2(4000) ERROR ON ERROR
             ),
             JSON_QUERY(
                p_payload_text,
                '$.documents'
                RETURNING VARCHAR2(4000) ERROR ON ERROR
             )
        INTO l_kind,
             l_order_id,
             l_order_time_text,
             l_subservice_code,
             l_subservice_title,
             l_agreement,
             l_person_json,
             l_foreign_person,
             l_any_data,
             l_variant_data,
             l_documents
        FROM dual;

      IF l_person_json IS NULL THEN
         l_person_json := l_foreign_person;
      END IF;

      IF l_kind IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'MI_0202_KIND_REQUIRED',
               p_info => 'kind is null or empty in payload'
            );
      END IF;

      IF l_person_json IS NULL THEN
         RETURN
            failure_Result(
               p_code => 'MI_0202_PERSON_REQUIRED',
               p_info => 'person or foreignPerson not found in payload'
            );
      END IF;

      l_order_timestamp :=
         parse_Timestamp_Tz(l_order_time_text);

      read_Person(
         p_person_json => l_person_json,
         p_person      => l_person
      );

      l_person_api_json := json_Person(l_person);

      IF l_any_data IS NOT NULL OR l_variant_data IS NOT NULL THEN
         l_subservice_data := TO_CLOB('{');

         IF l_any_data IS NOT NULL THEN
            l_subservice_data :=
                 l_subservice_data
              || '"anyData":'
              || l_any_data;
         END IF;

         IF l_variant_data IS NOT NULL THEN
            IF l_any_data IS NOT NULL THEN
               l_subservice_data := l_subservice_data || ',';
            END IF;

            l_subservice_data :=
                 l_subservice_data
              || '"variantData":'
              || l_variant_data;
         END IF;

         l_subservice_data := l_subservice_data || '}';
      END IF;

      SELECT JSON_QUERY(l_person_json, '$.address' RETURNING VARCHAR2(4000) ERROR ON ERROR),
             JSON_QUERY(l_person_json, '$.tempRegistrationAddress' RETURNING VARCHAR2(4000) ERROR ON ERROR),
             JSON_QUERY(l_person_json, '$.factAddress' RETURNING VARCHAR2(4000) ERROR ON ERROR)
        INTO l_address,
             l_temp_address,
             l_fact_address
        FROM dual;

      DCL.SavePoint(l_savepoint_name);
      l_dml_started := TRUE;

      l_person_result :=
         MI_Person_Api.get_Or_Create(
            p_inf_id      => cInf_Id,
            p_person_json => l_person_api_json
         );

      IF MI_ResultCtx.is_Failed(l_person_result) THEN
         l_dml_started := FALSE;

         rollback_Or_Raise(
            p_name => l_savepoint_name,
            p_log  => l_log
         );

         RETURN
            failure_From_Cause(
               p_code  => 'MI_0202_PERSON_FAILED',
               p_info  => 'Не удалось создать или найти person для MI_0202',
               p_cause => l_person_result
            );
      END IF;

      l_person_id :=
         MI_ResultCtx.result_Number(
            p_result => l_person_result,
            p_name   => 'person_id'
         );

      IF l_person_id IS NULL THEN
         l_result :=
            failure_From_Cause(
               p_code  => 'MI_0202_PERSON_ID_MISSING',
               p_info  => 'MI_Person_Api did not return person_id',
               p_cause => l_person_result
            );

         l_dml_started := FALSE;

         rollback_Or_Raise(
            p_name => l_savepoint_name,
            p_log  => l_log
         );

         RETURN l_result;
      END IF;

      INSERT INTO MI_0202 (
         EXTERNAL_UUID,
         REQ_ID,
         PERSON_ID,
         KIND,
         ORDER_ID,
         ORDER_TIMESTAMP,
         SUBSERVICE_CODE,
         SUBSERVICE_TITLE,
         SUBSERVICE_DATA,
         AGREEMENT_TYPE,
         DOCUMENTS,
         PAYLOAD
      )
      VALUES (
         MI_Utils.uuid_V7,
         p_req_id,
         l_person_id,
         l_kind,
         l_order_id,
         l_order_timestamp,
         l_subservice_code,
         l_subservice_title,
         l_subservice_data,
         l_agreement,
         l_documents,
         p_payload_text
      )
      RETURNING ITM_ID
           INTO l_item_id;

      save_Address(p_req_id, l_item_id, l_person_id, l_address,      1);
      save_Address(p_req_id, l_item_id, l_person_id, l_temp_address, 2);
      save_Address(p_req_id, l_item_id, l_person_id, l_fact_address, 3);

      l_log.context(
         p_inf_id    => cInf_Id,
         p_req_id    => p_req_id,
         p_itm_id    => l_item_id,
         p_person_id => l_person_id
      );

      l_log.info(
         p_message_text => 'MI_0202 item created',
         p_action_code  => 'create'
      );

      RETURN
         success_Result(
            p_code   => 'MI_0202_ITEM_CREATED',
            p_info   => 'MI_0202 item created',
            p_req_id => p_req_id,
            p_itm_id => l_item_id
         );

   EXCEPTION
      WHEN e_Rollback_Failed THEN
         RAISE;

      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         IF l_dml_started THEN
            l_dml_started := FALSE;

            rollback_Or_Raise(
               p_name => l_savepoint_name,
               p_log  => l_log
            );
         END IF;

         l_log.error(
            p_message_text => 'create_Item failed',
            p_action_code  => 'create',
            p_details_text => TO_CLOB(l_sqlerrm)
         );

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    => 'MI_0202_ITEM_CREATE_FAILED',
               p_info    => 'Не удалось создать MI_0202 item'
            );

         MI_ResultCtx.put_Number(l_result, 'ret_code', RET_FAIL);

         RETURN l_result;
   END create_Item_Impl;


   ---------------------------------------------------------------------------
   PROCEDURE create_Item (
      p_req_id        IN  MI_REQ.REQ_ID%TYPE,
      p_payload_text  IN  CLOB,

      p_itm_id        OUT MI_0202.ITM_ID%TYPE,
      p_ret_code      OUT NUMBER,
      p_ret_info      OUT VARCHAR2
   )
   IS
      l_result MI_ResultCtx.exec_Result_t;
   BEGIN
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      l_result :=
         create_Item_Impl(
            p_req_id       => p_req_id,
            p_payload_text => p_payload_text
         );

      p_itm_id :=
         MI_ResultCtx.result_Number(
            p_result => l_result,
            p_name   => 'itm_id'
         );

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );
   END create_Item;


   ---------------------------------------------------------------------------
   FUNCTION call_Fps_Check (
      p_itm_id IN MI_0202.ITM_ID%TYPE
   )
      RETURN VARCHAR2
   IS
      l_parameters SYS.ODCIVARCHAR2LIST :=
         SYS.ODCIVARCHAR2LIST(TO_CHAR(p_itm_id));
   BEGIN
      RETURN
         AC.Get_Value2(
            cDefint  => cFps_Check,
            tabParam => l_parameters
         );
   END call_Fps_Check;


   ---------------------------------------------------------------------------
   PROCEDURE apply_Request (
      p_message_uuid           IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid  IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id         IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time           IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text           IN  CLOB,

      p_req_id                 OUT MI_REQ.REQ_ID%TYPE,
      p_itm_id                 OUT MI_0202.ITM_ID%TYPE,
      p_ret_code               OUT NUMBER,
      p_ret_info               OUT VARCHAR2
   )
   IS
      l_request_result  MI_ResultCtx.exec_Result_t;
      l_item_result     MI_ResultCtx.exec_Result_t;
      l_result          MI_ResultCtx.exec_Result_t;

      l_req_id          MI_REQ.REQ_ID%TYPE;
      l_itm_id          MI_0202.ITM_ID%TYPE;
      l_fps_result      VARCHAR2(4000);

      l_savepoint_name  DCL.T_Name;
      l_dml_started     BOOLEAN := FALSE;
      l_phase           VARCHAR2(30) := 'validate';
      l_sqlcode         PLS_INTEGER;
      l_sqlerrm         VARCHAR2(2000);

      l_log             MI_Logger_T := g_log;
   BEGIN
      p_req_id   := NULL;
      p_itm_id   := NULL;
      p_ret_code := RET_FAIL;
      p_ret_info := NULL;

      l_log.context(
         p_inf_id         => cInf_Id,
         p_correlation_id => p_correlation_id
      );

      IF NOT MI_Utils.is_Uuid(p_message_uuid) THEN
         l_result := failure_Result('MI_0202_INVALID_MESSAGE_UUID', 'p_message_uuid is invalid');
      ELSIF NOT MI_Utils.is_Uuid(p_original_request_uuid) THEN
         l_result := failure_Result('MI_0202_INVALID_ORIGINAL_UUID', 'p_original_request_uuid is invalid');
      ELSIF NOT MI_Utils.is_Uuid(p_correlation_id) THEN
         l_result := failure_Result('MI_0202_INVALID_CORRELATION_ID', 'p_correlation_id is invalid');
      ELSIF p_request_time IS NULL THEN
         l_result := failure_Result('MI_0202_INVALID_REQUEST_TIME', 'p_request_time must not be NULL');
      ELSIF NOT is_Json_Object(p_payload_text) THEN
         l_result := failure_Result('MI_0202_INVALID_PAYLOAD', 'p_payload_text must be a strict JSON object');
      ELSE
         l_result := success_Result('MI_0202_VALID', 'MI_0202 request validated');
      END IF;

      IF MI_ResultCtx.is_Failed(l_result) THEN
         MI_ResultCtx.export_Jdbc_Result(
            p_result        => l_result,
            p_success_code  => RET_OK,
            p_failure_code  => RET_FAIL,
            p_ret_code      => p_ret_code,
            p_ret_info      => p_ret_info
         );
         RETURN;
      END IF;

      DCL.SavePoint(l_savepoint_name);
      l_dml_started := TRUE;

      l_phase := 'create_request';

      l_request_result :=
         MI_Request_Api.create_Request(
            p_inf_id            => cInf_Id,
            p_correlation_id    => p_correlation_id,
            p_original_req_uuid => p_original_request_uuid,
            p_message_uuid      => p_message_uuid,
            p_status_cd         => MI_Request_Api.STATUS_NEW
         );

      IF MI_ResultCtx.is_Failed(l_request_result) THEN
         l_result :=
            failure_From_Cause(
               p_code  => 'MI_0202_REQUEST_HEADER_FAILED',
               p_info  => 'Не удалось создать MI_REQ для MI_0202',
               p_cause => l_request_result
            );
      ELSE
         l_req_id :=
            MI_ResultCtx.result_Number(
               p_result => l_request_result,
               p_name   => 'req_id'
            );

         IF l_req_id IS NULL THEN
            l_result :=
               failure_From_Cause(
                  p_code  => 'MI_0202_REQ_ID_MISSING',
                  p_info  => 'MI_Request_Api did not return req_id',
                  p_cause => l_request_result
               );
         ELSE
            l_phase := 'create_item';

            l_item_result :=
               create_Item_Impl(
                  p_req_id       => l_req_id,
                  p_payload_text => p_payload_text
               );

            IF MI_ResultCtx.is_Failed(l_item_result) THEN
               l_result :=
                  failure_From_Cause(
                     p_code  => 'MI_0202_ITEM_FAILED',
                     p_info  => 'Не удалось создать item для MI_0202',
                     p_cause => l_item_result
                  );
            ELSE
               l_itm_id :=
                  MI_ResultCtx.result_Number(
                     p_result => l_item_result,
                     p_name   => 'itm_id'
                  );

               IF l_itm_id IS NULL THEN
                  l_result :=
                     failure_From_Cause(
                        p_code  => 'MI_0202_ITM_ID_MISSING',
                        p_info  => 'create_Item did not return itm_id',
                        p_cause => l_item_result
                     );
               ELSE
                  l_phase := 'fps_check';
                  l_fps_result := call_Fps_Check(l_itm_id);

                  IF UPPER(SUBSTR(TRIM(l_fps_result), 1, 2)) = 'OK' THEN
                     l_result :=
                        success_Result(
                           p_code   => 'MI_0202_APPLIED',
                           p_info   => l_fps_result,
                           p_req_id => l_req_id,
                           p_itm_id => l_itm_id
                        );
                  ELSE
                     l_result :=
                        failure_Result(
                           p_code    => 'MI_0202_FPS_REJECTED',
                           p_info    => NVL(l_fps_result, 'ФПЗ вернула NULL'),
                           p_details => TO_CLOB('definition=' || cFps_Check)
                        );
                  END IF;
               END IF;
            END IF;
         END IF;
      END IF;

      IF MI_ResultCtx.is_Failed(l_result) THEN
         l_dml_started := FALSE;

         rollback_Or_Raise(
            p_name => l_savepoint_name,
            p_log  => l_log
         );

         l_req_id      := NULL;
         l_itm_id      := NULL;
      END IF;

      p_req_id := l_req_id;
      p_itm_id := l_itm_id;

      MI_ResultCtx.export_Jdbc_Result(
         p_result        => l_result,
         p_success_code  => RET_OK,
         p_failure_code  => RET_FAIL,
         p_ret_code      => p_ret_code,
         p_ret_info      => p_ret_info
      );

      IF MI_ResultCtx.is_Success(l_result) THEN
         p_ret_info := l_fps_result;

         l_log.context(
            p_inf_id         => cInf_Id,
            p_req_id         => l_req_id,
            p_itm_id         => l_itm_id,
            p_correlation_id => p_correlation_id
         );

         l_log.info(
            p_message_text => 'MI_0202 request applied',
            p_action_code  => 'apply'
         );
      END IF;

   EXCEPTION
      WHEN e_Rollback_Failed THEN
         RAISE;

      WHEN OTHERS THEN
         l_sqlcode := SQLCODE;
         l_sqlerrm := SQLERRM;

         IF l_dml_started THEN
            l_dml_started := FALSE;

            rollback_Or_Raise(
               p_name => l_savepoint_name,
               p_log  => l_log
            );
         END IF;

         p_req_id   := NULL;
         p_itm_id   := NULL;
         p_ret_code := RET_FAIL;

         l_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => l_sqlcode,
               p_sqlerrm => l_sqlerrm,
               p_code    =>
                  CASE l_phase
                     WHEN 'fps_check' THEN 'MI_0202_FPS_FAILED'
                     ELSE 'MI_0202_APPLY_FAILED'
                  END,
               p_info    =>
                  CASE l_phase
                     WHEN 'fps_check' THEN 'Ошибка вызова ФПЗ SMEV.202.CHECK'
                     ELSE 'Ошибка применения MI_0202 request'
                  END,
               p_details => TO_CLOB('phase=' || l_phase)
            );

         MI_ResultCtx.put_Number(l_result, 'ret_code', RET_FAIL);

         MI_ResultCtx.export_Jdbc_Result(
            p_result        => l_result,
            p_success_code  => RET_OK,
            p_failure_code  => RET_FAIL,
            p_ret_code      => p_ret_code,
            p_ret_info      => p_ret_info
         );

         l_log.error(
            p_message_text => 'apply_Request failed',
            p_action_code  => l_phase,
            p_details_text => TO_CLOB(l_sqlerrm)
         );
   END apply_Request;


   ---------------------------------------------------------------------------
   PROCEDURE apply_Request (
      p_message_uuid           IN  MI_REQ.MESSAGE_UUID%TYPE,
      p_original_request_uuid  IN  MI_REQ.ORIGINAL_REQ_UUID%TYPE,
      p_correlation_id         IN  MI_REQ.CORRELATION_ID%TYPE,
      p_request_time           IN  TIMESTAMP WITH TIME ZONE,
      p_payload_text           IN  CLOB,

      p_ret_code               OUT NUMBER,
      p_ret_info               OUT VARCHAR2
   )
   IS
      l_req_id MI_REQ.REQ_ID%TYPE;
      l_itm_id MI_0202.ITM_ID%TYPE;
   BEGIN
      apply_Request(
         p_message_uuid          => p_message_uuid,
         p_original_request_uuid => p_original_request_uuid,
         p_correlation_id        => p_correlation_id,
         p_request_time          => p_request_time,
         p_payload_text          => p_payload_text,
         p_req_id                => l_req_id,
         p_itm_id                => l_itm_id,
         p_ret_code              => p_ret_code,
         p_ret_info              => p_ret_info
      );
   END apply_Request;


   ---------------------------------------------------------------------------
   PROCEDURE get_Item_Row (
      p_itm_id      IN  MI_0202.ITM_ID%TYPE,
      p_item        OUT MI_0202%ROWTYPE,
      p_person      OUT MI_PERSON%ROWTYPE,
      p_links       OUT P2A_Row_List_t,
      p_addresses   OUT Address_Row_List_t
   )
   IS
   BEGIN
      SELECT *
        INTO p_item
        FROM MI_0202
       WHERE ITM_ID = p_itm_id;

      IF p_item.PERSON_ID IS NOT NULL THEN
         SELECT *
           INTO p_person
           FROM MI_PERSON
          WHERE PERSON_ID = p_item.PERSON_ID;

         SELECT a.*
           BULK COLLECT INTO p_links
           FROM MI_P2A a
           JOIN MI_ADDR ad
             ON ad.ADDR_ID = a.ADDR_ID
          WHERE a.PERSON_ID = p_item.PERSON_ID
            AND ad.ITM_ID = p_item.ITM_ID
          ORDER BY a.ADDR_ID, a.ITYPE;

         SELECT ad.*
           BULK COLLECT INTO p_addresses
           FROM MI_P2A a
           JOIN MI_ADDR ad
             ON ad.ADDR_ID = a.ADDR_ID
          WHERE a.PERSON_ID = p_item.PERSON_ID
            AND ad.ITM_ID = p_item.ITM_ID
          ORDER BY a.ADDR_ID, a.ITYPE;
      END IF;
   END get_Item_Row;


   ---------------------------------------------------------------------------
   PROCEDURE append_Text (
      p_target IN OUT NOCOPY CLOB,
      p_text   IN            VARCHAR2
   )
   IS
   BEGIN
      IF p_text IS NOT NULL THEN
         DBMS_LOB.WRITEAPPEND(p_target, LENGTH(p_text), p_text);
      END IF;
   END append_Text;


   ---------------------------------------------------------------------------
   PROCEDURE append_Clob (
      p_target IN OUT NOCOPY CLOB,
      p_value  IN            CLOB
   )
   IS
   BEGIN
      IF p_value IS NOT NULL THEN
         DBMS_LOB.APPEND(p_target, p_value);
      END IF;
   END append_Clob;


   ---------------------------------------------------------------------------
   PROCEDURE append_Comma (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN
   )
   IS
   BEGIN
      IF p_first THEN
         p_first := FALSE;
      ELSE
         append_Text(p_target, ',');
      END IF;
   END append_Comma;


   ---------------------------------------------------------------------------
   PROCEDURE append_String_Value (
      p_target IN OUT NOCOPY CLOB,
      p_value  IN            CLOB
   )
   IS
      l_offset PLS_INTEGER := 1;
      l_chunk  VARCHAR2(4000);
   BEGIN
      IF p_value IS NULL THEN
         append_Text(p_target, 'null');
         RETURN;
      END IF;

      append_Text(p_target, '"');

      WHILE l_offset <= DBMS_LOB.GETLENGTH(p_value) LOOP
         l_chunk := DBMS_LOB.SUBSTR(p_value, 4000, l_offset);
         append_Text(p_target, json_Escape(l_chunk));
         l_offset := l_offset + LENGTH(l_chunk);
      END LOOP;

      append_Text(p_target, '"');
   END append_String_Value;


   ---------------------------------------------------------------------------
   PROCEDURE append_String_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            VARCHAR2
   )
   IS
   BEGIN
      append_Comma(p_target, p_first);
      append_Text(p_target, '"' || p_name || '":' || json_String(p_value));
   END append_String_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Clob_String_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            CLOB
   )
   IS
   BEGIN
      append_Comma(p_target, p_first);
      append_Text(p_target, '"' || p_name || '":');
      append_String_Value(p_target, p_value);
   END append_Clob_String_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Number_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            NUMBER
   )
   IS
   BEGIN
      append_Comma(p_target, p_first);
      append_Text(
         p_target,
         '"' || p_name || '":'
         || CASE
               WHEN p_value IS NULL THEN 'null'
               ELSE REPLACE(TO_CHAR(p_value, 'TM9'), ',', '.')
            END
      );
   END append_Number_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Date_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            DATE
   )
   IS
   BEGIN
      append_String_Field(
         p_target,
         p_first,
         p_name,
         CASE
            WHEN p_value IS NULL THEN NULL
            ELSE TO_CHAR(p_value, 'YYYY-MM-DD')
         END
      );
   END append_Date_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Timestamp_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            TIMESTAMP
   )
   IS
   BEGIN
      append_String_Field(
         p_target,
         p_first,
         p_name,
         CASE
            WHEN p_value IS NULL THEN NULL
            ELSE TO_CHAR(p_value, 'YYYY-MM-DD"T"HH24:MI:SS.FF3')
         END
      );
   END append_Timestamp_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Timestamp_Ltz_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            TIMESTAMP WITH LOCAL TIME ZONE
   )
   IS
   BEGIN
      append_String_Field(
         p_target,
         p_first,
         p_name,
         CASE
            WHEN p_value IS NULL THEN NULL
            ELSE TO_CHAR(p_value, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM')
         END
      );
   END append_Timestamp_Ltz_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Json_Field (
      p_target IN OUT NOCOPY CLOB,
      p_first  IN OUT NOCOPY BOOLEAN,
      p_name   IN            VARCHAR2,
      p_value  IN            CLOB
   )
   IS
   BEGIN
      append_Comma(p_target, p_first);
      append_Text(p_target, '"' || p_name || '":');

      IF p_value IS NULL THEN
         append_Text(p_target, 'null');
      ELSE
         append_Clob(p_target, p_value);
      END IF;
   END append_Json_Field;


   ---------------------------------------------------------------------------
   PROCEDURE append_Item (
      p_target IN OUT NOCOPY CLOB,
      p_item   IN            MI_0202%ROWTYPE
   )
   IS
      l_first BOOLEAN := TRUE;
   BEGIN
      append_Text(p_target, '{');
      append_Number_Field(p_target, l_first, 'itm_id', p_item.ITM_ID);
      append_String_Field(p_target, l_first, 'external_uuid', RTRIM(p_item.EXTERNAL_UUID));
      append_Number_Field(p_target, l_first, 'req_id', p_item.REQ_ID);
      append_Number_Field(p_target, l_first, 'person_id', p_item.PERSON_ID);
      append_Number_Field(p_target, l_first, 'icusnum', p_item.ICUSNUM);
      append_String_Field(p_target, l_first, 'kind', p_item.KIND);
      append_Number_Field(p_target, l_first, 'order_id', p_item.ORDER_ID);
      append_Timestamp_Ltz_Field(p_target, l_first, 'order_timestamp', p_item.ORDER_TIMESTAMP);
      append_String_Field(p_target, l_first, 'subservice_code', p_item.SUBSERVICE_CODE);
      append_String_Field(p_target, l_first, 'subservice_title', p_item.SUBSERVICE_TITLE);
      append_Json_Field(p_target, l_first, 'subservice_data', p_item.SUBSERVICE_DATA);
      append_String_Field(p_target, l_first, 'agreement_type', p_item.AGREEMENT_TYPE);
      append_Json_Field(p_target, l_first, 'documents', p_item.DOCUMENTS);
      append_Clob_String_Field(p_target, l_first, 'payload', p_item.PAYLOAD);
      append_Timestamp_Ltz_Field(p_target, l_first, 'created_at', p_item.CREATED_AT);
      append_Number_Field(p_target, l_first, 'ires_code', p_item.IRES_CODE);
      append_Timestamp_Ltz_Field(p_target, l_first, 'tres_time', p_item.TRES_TIME);
      append_Clob_String_Field(p_target, l_first, 'cres_info', p_item.CRES_INFO);
      append_String_Field(p_target, l_first, 'message_uuid', RTRIM(p_item.MESSAGE_UUID));
      append_String_Field(p_target, l_first, 'error_code', p_item.ERROR_CODE);
      append_Text(p_target, '}');
   END append_Item;


   ---------------------------------------------------------------------------
   PROCEDURE append_Person (
      p_target IN OUT NOCOPY CLOB,
      p_person IN            MI_PERSON%ROWTYPE
   )
   IS
      l_first BOOLEAN := TRUE;
   BEGIN
      append_Text(p_target, '{');
      append_Number_Field(p_target, l_first, 'person_id', p_person.PERSON_ID);
      append_Number_Field(p_target, l_first, 'icusnum', p_person.ICUSNUM);
      append_Timestamp_Field(p_target, l_first, 'created_at', p_person.CREATED_AT);
      append_String_Field(p_target, l_first, 'first_name', p_person.FIRST_NAME);
      append_String_Field(p_target, l_first, 'last_name', p_person.LAST_NAME);
      append_String_Field(p_target, l_first, 'middle_name', p_person.MIDDLE_NAME);
      append_String_Field(p_target, l_first, 'first_name_lat', p_person.FIRST_NAME_LAT);
      append_String_Field(p_target, l_first, 'last_name_lat', p_person.LAST_NAME_LAT);
      append_String_Field(p_target, l_first, 'middle_name_lat', p_person.MIDDLE_NAME_LAT);
      append_Number_Field(p_target, l_first, 'gender_id', p_person.GENDER_ID);
      append_Number_Field(p_target, l_first, 'ctzn_type_id', p_person.CTZN_TYPE_ID);
      append_String_Field(p_target, l_first, 'ctzn_country_code', p_person.CTZN_COUNTRY_CODE);
      append_String_Field(p_target, l_first, 'inn', p_person.INN);
      append_String_Field(p_target, l_first, 'snils', p_person.SNILS);
      append_Number_Field(p_target, l_first, 'doc_type_id', p_person.DOC_TYPE_ID);
      append_String_Field(p_target, l_first, 'doc_type_code', p_person.DOC_TYPE_CODE);
      append_String_Field(p_target, l_first, 'doc_ser', p_person.DOC_SER);
      append_String_Field(p_target, l_first, 'doc_num', p_person.DOC_NUM);
      append_Date_Field(p_target, l_first, 'doc_issue_date', p_person.DOC_ISSUE_DATE);
      append_String_Field(p_target, l_first, 'doc_issuer_code', p_person.DOC_ISSUER_CODE);
      append_Date_Field(p_target, l_first, 'doc_expire_date', p_person.DOC_EXPIRE_DATE);
      append_String_Field(p_target, l_first, 'doc_issuer_name', p_person.DOC_ISSUER_NAME);
      append_Date_Field(p_target, l_first, 'doc_invalid_from', p_person.DOC_INVALID_FROM);
      append_Date_Field(p_target, l_first, 'birth_date', p_person.BIRTH_DATE);
      append_String_Field(p_target, l_first, 'birth_date_raw', p_person.BIRTH_DATE_RAW);
      append_String_Field(p_target, l_first, 'birth_place', p_person.BIRTH_PLACE);
      append_Date_Field(p_target, l_first, 'death_date', p_person.DEATH_DATE);
      append_String_Field(p_target, l_first, 'phone', p_person.PHONE);
      append_String_Field(p_target, l_first, 'email', p_person.EMAIL);
      append_String_Field(p_target, l_first, 'region_code', p_person.REGION_CODE);
      append_String_Field(p_target, l_first, 'coid', p_person.COID);
      append_Text(p_target, '}');
   END append_Person;


   ---------------------------------------------------------------------------
   PROCEDURE append_Address (
      p_target  IN OUT NOCOPY CLOB,
      p_address IN            MI_ADDR%ROWTYPE
   )
   IS
      l_first BOOLEAN := TRUE;
   BEGIN
      append_Text(p_target, '{');
      append_Number_Field(p_target, l_first, 'addr_id', p_address.ADDR_ID);
      append_Number_Field(p_target, l_first, 'req_id', p_address.REQ_ID);
      append_Number_Field(p_target, l_first, 'itm_id', p_address.ITM_ID);
      append_String_Field(p_target, l_first, 'ckladr_code', p_address.CKLADR_CODE);
      append_String_Field(p_target, l_first, 'cpostcode', p_address.CPOSTCODE);
      append_String_Field(p_target, l_first, 'cregion_code', p_address.CREGION_CODE);
      append_String_Field(p_target, l_first, 'cregion_type', p_address.CREGION_TYPE);
      append_String_Field(p_target, l_first, 'cregion_name', p_address.CREGION_NAME);
      append_String_Field(p_target, l_first, 'carea_type', p_address.CAREA_TYPE);
      append_String_Field(p_target, l_first, 'carea_name', p_address.CAREA_NAME);
      append_String_Field(p_target, l_first, 'ccity_type', p_address.CCITY_TYPE);
      append_String_Field(p_target, l_first, 'ccity_name', p_address.CCITY_NAME);
      append_String_Field(p_target, l_first, 'cplace_type', p_address.CPLACE_TYPE);
      append_String_Field(p_target, l_first, 'cplace_name', p_address.CPLACE_NAME);
      append_String_Field(p_target, l_first, 'cstreet_type', p_address.CSTREET_TYPE);
      append_String_Field(p_target, l_first, 'cstreet_name', p_address.CSTREET_NAME);
      append_String_Field(p_target, l_first, 'chouse', p_address.CHOUSE);
      append_String_Field(p_target, l_first, 'cbuild', p_address.CBUILD);
      append_String_Field(p_target, l_first, 'capart', p_address.CAPART);
      append_String_Field(p_target, l_first, 'cfias_code', RTRIM(p_address.CFIAS_CODE));
      append_String_Field(p_target, l_first, 'cstrct', p_address.CSTRCT);
      append_String_Field(p_target, l_first, 'cctya3', RTRIM(p_address.CCTYA3));
      append_String_Field(p_target, l_first, 'coktmo_code', p_address.COKTMO_CODE);
      append_String_Field(p_target, l_first, 'cunstrct_addr', p_address.CUNSTRCT_ADDR);
      append_Timestamp_Ltz_Field(p_target, l_first, 'created_at', p_address.CREATED_AT);
      append_Text(p_target, '}');
   END append_Address;


   ---------------------------------------------------------------------------
   FUNCTION get_Item_Json (
      p_itm_id IN MI_0202.ITM_ID%TYPE
   )
      RETURN CLOB
   IS
      l_item       MI_0202%ROWTYPE;
      l_person     MI_PERSON%ROWTYPE;
      l_links      P2A_Row_List_t;
      l_addresses  Address_Row_List_t;

      l_json       CLOB;
      l_first      BOOLEAN := TRUE;
      l_address_first BOOLEAN := TRUE;
   BEGIN
      get_Item_Row(
         p_itm_id    => p_itm_id,
         p_item      => l_item,
         p_person    => l_person,
         p_links     => l_links,
         p_addresses => l_addresses
      );

      DBMS_LOB.CREATETEMPORARY(l_json, TRUE, DBMS_LOB.CALL);
      append_Text(l_json, '{');

      append_Comma(l_json, l_first);
      append_Text(l_json, '"item":');
      append_Item(l_json, l_item);

      append_Comma(l_json, l_first);
      append_Text(l_json, '"person":');

      IF l_item.PERSON_ID IS NULL THEN
         append_Text(l_json, 'null');
      ELSE
         append_Person(l_json, l_person);
      END IF;

      append_Comma(l_json, l_first);
      append_Text(l_json, '"addresses":[');

      IF l_links.COUNT > 0 THEN
         FOR i IN 1 .. l_links.COUNT LOOP
            append_Comma(l_json, l_address_first);
            append_Text(l_json, '{');
            append_Text(l_json, '"itype":' || TO_CHAR(l_links(i).ITYPE, 'TM9'));
            append_Text(
               l_json,
               ',"dbeg_reg":'
               || json_String(
                     CASE
                        WHEN l_links(i).DBEG_REG IS NULL THEN NULL
                        ELSE TO_CHAR(l_links(i).DBEG_REG, 'YYYY-MM-DD')
                     END
                  )
            );
            append_Text(
               l_json,
               ',"dend_reg":'
               || json_String(
                     CASE
                        WHEN l_links(i).DEND_REG IS NULL THEN NULL
                        ELSE TO_CHAR(l_links(i).DEND_REG, 'YYYY-MM-DD')
                     END
                  )
            );
            append_Text(l_json, ',"address":');
            append_Address(l_json, l_addresses(i));
            append_Text(l_json, '}');
         END LOOP;
      END IF;

      append_Text(l_json, ']}');

      RETURN l_json;
   END get_Item_Json;

END MI_0202_Api;
/
