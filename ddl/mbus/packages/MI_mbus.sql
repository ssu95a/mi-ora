CREATE OR REPLACE PACKAGE MI_mbus
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.0.0} {17.11.2026} Sulimoff$';


   RESULT_ALREADY_IN_PROGRESS CONSTANT VARCHAR2(100) := 'ALREADY_IN_PROGRESS';
   RESULT_ALREADY_SENT        CONSTANT VARCHAR2(100) := 'ALREADY_SENT';
   RESULT_ALREADY_COMPLETED   CONSTANT VARCHAR2(100) := 'ALREADY_COMPLETED';
   RESULT_MBUS_NOT_IMPLEMENTED CONSTANT VARCHAR2(100) := 'MBUS_NOT_IMPLEMENTED';


   FUNCTION get_Version
      RETURN VARCHAR2;


   /*
      Формирует XXLRequest для существующего request и передаёт его в
      transport boundary.

      BUSY/SENT/DONE являются идемпотентными успешными состояниями.
      NEW/ERROR допускают отправку. Статус request эта процедура не меняет.
   */
   PROCEDURE send_Request (
      p_req_id  IN  MI_REQ.REQ_ID%TYPE,
      p_result  OUT MI_ResultCtx.exec_Result_t
   );


   /*
      Формирует XXLRequest для business response.

      Отправлять допускается только READY response. SENT является
      идемпотентным успешным состоянием. Статус response не меняется.
   */
   PROCEDURE send_Response (
      p_rsp_id  IN  MI_RSP.RSP_ID%TYPE,
      p_result  OUT MI_ResultCtx.exec_Result_t
   );


   /*
      Формирует прямую команду XXL.

      Scope определяется как в PostgreSQL-контракте:

         p_req_id IS NOT NULL -> REQUEST;
         иначе p_inf_id IS NOT NULL -> INF;
         иначе -> XXL.

      Oracle 12.1 divergence: p_parameters передаётся как CLOB с JSON-текстом,
      а не как PostgreSQL jsonb. NULL означает пустой объект {}. Непустое
      значение обязано быть strict JSON object. В XML включается escaped text
      этого JSON object; значения параметров и полный XML не логируются.
   */
   PROCEDURE send_Command (
      p_result      OUT MI_ResultCtx.exec_Result_t,

      p_action      IN  VARCHAR2,

      p_inf_id      IN  MI_INF.INF_ID%TYPE DEFAULT NULL,
      p_req_id      IN  MI_REQ.REQ_ID%TYPE DEFAULT NULL,

      p_parameters  IN  CLOB DEFAULT '{}'
   );

END MI_mbus;
/

CREATE OR REPLACE PACKAGE BODY MI_mbus
IS

   cLogger         CONSTANT VARCHAR2(64)  := 'mi.mbus';
   cMultiBus_Gate  CONSTANT VARCHAR2(100) := 'r-xxl-gate';

   cErr_Request_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#REQUEST_NOT_FOUND_IN_X';
   cErr_Request_Bad_Status CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#BAD_STATUS';
   cErr_Request_Bad_Identity CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#INVALID_IDENTITY';
   cErr_Request_Unexpected CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#UNEXPECTED';

   cErr_Response_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#RESPONSE_NOT_FOUND';
   cErr_Response_Bad_Status CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#BAD_STATUS';
   cErr_Response_Bad_Identity CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#INVALID_IDENTITY';
   cErr_Response_Unexpected CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#UNEXPECTED';

   cErr_Command_Invalid_Inf CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_INF_ID';
   cErr_Command_Inf_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INF_NOT_FOUND';
   cErr_Command_Action_Required CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#ACTION_REQUIRED';
   cErr_Command_Invalid_Action CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_ACTION';
   cErr_Command_Bad_Parameters CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_PARAMETERS';
   cErr_Command_Unexpected CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#UNEXPECTED';

   cErr_Transport_Config CONSTANT VARCHAR2(100) :=
      'MI_MBUS.TRANSPORT#INVALID_CONFIGURATION';


   g_log CONSTANT MI_Logger_T :=
      MI_Logger_T(
         p_logger_name  => cLogger,
         p_package_name => $$PLSQL_UNIT
      );


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   PROCEDURE put_Parameter (
      p_result  IN OUT NOCOPY MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2,
      p_value   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_value IS NOT NULL THEN
         p_result.parameters(p_name) := SUBSTR(p_value, 1, 2000);
      END IF;
   END put_Parameter;


   ---------------------------------------------------------------------------
   PROCEDURE put_Number (
      p_result  IN OUT NOCOPY MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2,
      p_value   IN NUMBER
   )
   IS
   BEGIN
      IF p_value IS NOT NULL THEN
         put_Parameter(
            p_result => p_result,
            p_name   => p_name,
            p_value  => TO_CHAR(p_value, 'TM9')
         );
      END IF;
   END put_Number;


   ---------------------------------------------------------------------------
   PROCEDURE put_Common_Context (
      p_result        IN OUT NOCOPY MI_ResultCtx.exec_Result_t,
      p_call_uuid     IN VARCHAR2,
      p_scope         IN VARCHAR2 DEFAULT NULL,
      p_action        IN VARCHAR2 DEFAULT NULL,
      p_inf_id        IN NUMBER   DEFAULT NULL,
      p_req_id        IN NUMBER   DEFAULT NULL,
      p_itm_id        IN NUMBER   DEFAULT NULL,
      p_rsp_id        IN NUMBER   DEFAULT NULL,
      p_status_cd     IN NUMBER   DEFAULT NULL
   )
   IS
   BEGIN
      put_Parameter(p_result, 'call_uuid', p_call_uuid);
      put_Parameter(p_result, 'scope', p_scope);
      put_Parameter(p_result, 'action', p_action);

      put_Number(p_result, 'inf_id', p_inf_id);
      put_Number(p_result, 'req_id', p_req_id);
      put_Number(p_result, 'itm_id', p_itm_id);
      put_Number(p_result, 'rsp_id', p_rsp_id);
      put_Number(p_result, 'status_cd', p_status_cd);
   END put_Common_Context;


   ---------------------------------------------------------------------------
   FUNCTION success_Result (
      p_code  IN VARCHAR2,
      p_info  IN VARCHAR2
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
   BEGIN
      RETURN
         MI_ResultCtx.success(
            p_code => p_code,
            p_info => p_info
         );
   END success_Result;


   ---------------------------------------------------------------------------
   FUNCTION failure_Result (
      p_code     IN VARCHAR2,
      p_info     IN VARCHAR2,
      p_details  IN CLOB DEFAULT NULL
   )
      RETURN MI_ResultCtx.exec_Result_t
   IS
   BEGIN
      RETURN
         MI_ResultCtx.failure(
            p_code    => p_code,
            p_info    => p_info,
            p_details => p_details
         );
   END failure_Result;


   ---------------------------------------------------------------------------
   PROCEDURE resolve_Transport_Settings (
      p_gate_alias      OUT VARCHAR2,
      p_request_ttl_ms  OUT PLS_INTEGER,
      p_result          OUT MI_ResultCtx.exec_Result_t,
      p_is_valid        OUT BOOLEAN
   )
   IS
      l_timeout_text VARCHAR2(100);
      l_timeout_num  NUMBER;
   BEGIN
      p_is_valid := FALSE;

      p_gate_alias :=
         TRIM(
            MI_Prp.get_Sys_Property(
               p_prp_id    => 'MBUS_GATE',
               p_def_value => cMultiBus_Gate
            )
         );

      IF p_gate_alias IS NULL THEN
         p_gate_alias := cMultiBus_Gate;
      END IF;

      l_timeout_text :=
         TRIM(
            MI_Prp.get_Sys_Property(
               p_prp_id    => 'MBUS_REQUEST_TIMEOUT',
               p_def_value => '30000'
            )
         );

      BEGIN
         l_timeout_num := TO_NUMBER(l_timeout_text);
      EXCEPTION
         WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            p_result :=
               failure_Result(
                  p_code => cErr_Transport_Config,
                  p_info => 'MBUS_REQUEST_TIMEOUT must be a positive integer'
               );
            put_Parameter(p_result, 'property_name', 'MBUS_REQUEST_TIMEOUT');
            RETURN;
      END;

      IF l_timeout_num <= 0
         OR l_timeout_num <> TRUNC(l_timeout_num)
         OR l_timeout_num > 2147483647
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Transport_Config,
               p_info => 'MBUS_REQUEST_TIMEOUT must be a positive integer'
            );
         put_Parameter(p_result, 'property_name', 'MBUS_REQUEST_TIMEOUT');
         RETURN;
      END IF;

      p_request_ttl_ms := l_timeout_num;
      p_is_valid := TRUE;
   END resolve_Transport_Settings;


   ---------------------------------------------------------------------------
   PROCEDURE call_Transport_Stub (
      p_request_xml     IN  CLOB,
      p_request_queue   IN  VARCHAR2,
      p_response_queue  IN  VARCHAR2,
      p_gate_alias      IN  VARCHAR2,
      p_request_ttl_ms  IN  PLS_INTEGER,
      p_result          OUT MI_ResultCtx.exec_Result_t
   )
   IS
      l_result_x     CLOB;
      l_result_info  VARCHAR2(2000);
      l_result_corr  VARCHAR2(2000);
      l_result_code  NUMBER;
   BEGIN
      IF p_request_xml IS NULL THEN
         p_result :=
            failure_Result(
               p_code => 'MI_MBUS.TRANSPORT#EMPTY_REQUEST',
               p_info => 'XXLRequest was not prepared'
            );
         RETURN;
      END IF;

      /*
         Единственная точка подстановки реального Oracle Multi-Bus API.

         Источник queue names в актуальном Oracle DDL пока UNKNOWN. Поэтому
         p_request_queue/p_response_queue намеренно остаются NULL до
         подтверждения контракта разработчиком шины. PG-вызов имеет вид:

         cbs_Bus_X.query_Bus_Text(
            cSqueue_name => p_request_queue,
            cDqueue_name => p_response_queue,
            cXml         => p_request_xml,
            busType      => p_gate_alias,
            nWait        => p_request_ttl_ms,
            SOUT         => l_result_x,
            ERRORMSG     => l_result_info,
            cCor         => l_result_corr,
            res          => l_result_code
         );

         После подстановки здесь должны проверяться l_result_code, непустой
         l_result_x и разбираться XXLResponse. До подтверждения API вызов
         запрещён: нельзя имитировать успешную публикацию.
      */

      p_result :=
         failure_Result(
            p_code => RESULT_MBUS_NOT_IMPLEMENTED,
            p_info =>
               'XXLRequest prepared; Oracle Multi-Bus transport is not implemented'
         );

      put_Parameter(p_result, 'request_prepared', '1');
      put_Number(p_result, 'request_size', DBMS_LOB.getlength(p_request_xml));
      put_Parameter(p_result, 'gate_alias', p_gate_alias);
      put_Number(p_result, 'request_ttl_ms', p_request_ttl_ms);
      put_Parameter(p_result, 'request_queue', p_request_queue);
      put_Parameter(p_result, 'response_queue', p_response_queue);
   END call_Transport_Stub;


   ---------------------------------------------------------------------------
   PROCEDURE send_Request (
      p_req_id  IN  MI_REQ.REQ_ID%TYPE,
      p_result  OUT MI_ResultCtx.exec_Result_t
   )
   IS
      l_inf_id          MI_REQ.INF_ID%TYPE;
      l_wsp_id          MI_INF.WSP_ID%TYPE;
      l_status_cd       MI_REQ.STATUS_CD%TYPE;
      l_correlation_id  MI_REQ.CORRELATION_ID%TYPE;
      l_external_uuid   MI_REQ.EXTERNAL_UUID%TYPE;

      l_call_uuid       VARCHAR2(36) := MI_Utils.uuid_V7;
      l_called_at       TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
      l_send_x          CLOB;

      l_gate_alias      VARCHAR2(100);
      l_request_ttl_ms  PLS_INTEGER;
      l_settings_valid  BOOLEAN;

      /* Queue source is intentionally UNKNOWN until Oracle bus API review. */
      l_request_queue   VARCHAR2(200) := NULL;
      l_response_queue  VARCHAR2(200) := NULL;

      l_log             MI_Logger_T := g_log;
   BEGIN
      IF p_req_id IS NULL THEN
         p_result :=
            failure_Result(
               p_code => cErr_Request_Not_Found,
               p_info => 'p_req_id is required'
            );
         put_Common_Context(p_result, l_call_uuid, p_req_id => p_req_id);
         RETURN;
      END IF;

      BEGIN
         SELECT r.INF_ID,
                i.WSP_ID,
                r.STATUS_CD,
                TRIM(r.CORRELATION_ID),
                TRIM(r.EXTERNAL_UUID)
           INTO l_inf_id,
                l_wsp_id,
                l_status_cd,
                l_correlation_id,
                l_external_uuid
           FROM MI_REQ r
           JOIN MI_INF i
             ON i.INF_ID = r.INF_ID
          WHERE r.REQ_ID = p_req_id;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_result :=
               failure_Result(
                  p_code => cErr_Request_Not_Found,
                  p_info => 'Request not found in MI_REQ'
               );
            put_Common_Context(p_result, l_call_uuid, p_req_id => p_req_id);
            RETURN;
      END;

      l_log.context(
         p_inf_id         => l_inf_id,
         p_req_id         => p_req_id,
         p_correlation_id => l_correlation_id
      );

      IF l_status_cd = MI_Request_Api.STATUS_BUSY THEN
         p_result :=
            success_Result(
               p_code => RESULT_ALREADY_IN_PROGRESS,
               p_info => 'Request is already in progress'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => p_req_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      ELSIF l_status_cd = MI_Request_Api.STATUS_SENT THEN
         p_result :=
            success_Result(
               p_code => RESULT_ALREADY_SENT,
               p_info => 'Request is already sent, waiting item responses'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => p_req_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      ELSIF l_status_cd = MI_Request_Api.STATUS_DONE THEN
         p_result :=
            success_Result(
               p_code => RESULT_ALREADY_COMPLETED,
               p_info => 'Request is already completed'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => p_req_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      ELSIF l_status_cd NOT IN (
         MI_Request_Api.STATUS_NEW,
         MI_Request_Api.STATUS_ERROR
      )
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Request_Bad_Status,
               p_info => 'Invalid request status for send'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => p_req_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      END IF;

      IF l_inf_id IS NULL
         OR l_wsp_id IS NULL
         OR l_correlation_id IS NULL
         OR l_external_uuid IS NULL
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Request_Bad_Identity,
               p_info => 'Request identity is incomplete'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => p_req_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      END IF;

      resolve_Transport_Settings(
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result,
         p_is_valid       => l_settings_valid
      );

      IF NOT l_settings_valid THEN
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );
         RETURN;
      END IF;

      SELECT XMLSERIALIZE(
                DOCUMENT XMLELEMENT(
                   "XXLRequest",
                   XMLATTRIBUTES(
                      '1.0' AS "version",
                      'send' AS "action",
                      'auto' AS "mode",
                      TO_CHAR(p_req_id, 'TM9') AS "req_id",
                      TO_CHAR(l_wsp_id, 'TM9') AS "wsp_id",
                      TO_CHAR(l_inf_id, 'TM9') AS "inf_id",
                      l_correlation_id AS "correlation_id",
                      l_external_uuid AS "external_uuid",
                      l_call_uuid AS "call_uuid",
                      TO_CHAR(
                         l_called_at,
                         'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM'
                      ) AS "timestamp"
                   )
                )
                AS CLOB
             )
        INTO l_send_x
        FROM DUAL;

      l_log.debug(
         p_message_text => 'XXLRequest prepared',
         p_action_code  => 'prepare',
         p_details_text =>
               'call_uuid='
            || l_call_uuid
            || '; request_size='
            || DBMS_LOB.getlength(l_send_x)
      );

      call_Transport_Stub(
         p_request_xml    => l_send_x,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result
      );

      put_Common_Context(
         p_result, l_call_uuid,
         p_scope     => 'REQUEST',
         p_action    => 'send',
         p_inf_id    => l_inf_id,
         p_req_id    => p_req_id,
         p_status_cd => l_status_cd
      );

   EXCEPTION
      WHEN OTHERS THEN
         p_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => SQLCODE,
               p_sqlerrm => SQLERRM,
               p_code    => cErr_Request_Unexpected,
               p_info    => 'Unexpected error in MI_mbus.send_Request'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id => l_inf_id,
            p_req_id => p_req_id
         );
   END send_Request;


   ---------------------------------------------------------------------------
   PROCEDURE send_Response (
      p_rsp_id  IN  MI_RSP.RSP_ID%TYPE,
      p_result  OUT MI_ResultCtx.exec_Result_t
   )
   IS
      l_req_id                MI_RSP.REQ_ID%TYPE;
      l_itm_id                MI_RSP.ITM_ID%TYPE;
      l_rsp_uuid              MI_RSP.RSP_UUID%TYPE;
      l_status_cd             MI_RSP.STATUS_CD%TYPE;

      l_inf_id                MI_REQ.INF_ID%TYPE;
      l_correlation_id        MI_REQ.CORRELATION_ID%TYPE;
      l_original_request_uuid MI_REQ.ORIGINAL_REQ_UUID%TYPE;

      l_call_uuid             VARCHAR2(36) := MI_Utils.uuid_V7;
      l_called_at             TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
      l_send_x                CLOB;

      l_gate_alias            VARCHAR2(100);
      l_request_ttl_ms        PLS_INTEGER;
      l_settings_valid        BOOLEAN;

      /* Queue source is intentionally UNKNOWN until Oracle bus API review. */
      l_request_queue         VARCHAR2(200) := NULL;
      l_response_queue        VARCHAR2(200) := NULL;

      l_log                   MI_Logger_T := g_log;
   BEGIN
      IF p_rsp_id IS NULL THEN
         p_result :=
            failure_Result(
               p_code => cErr_Response_Not_Found,
               p_info => 'p_rsp_id is required'
            );
         put_Common_Context(p_result, l_call_uuid, p_rsp_id => p_rsp_id);
         RETURN;
      END IF;

      BEGIN
         SELECT s.REQ_ID,
                s.ITM_ID,
                TRIM(s.RSP_UUID),
                s.STATUS_CD,
                r.INF_ID,
                TRIM(r.CORRELATION_ID),
                TRIM(r.ORIGINAL_REQ_UUID)
           INTO l_req_id,
                l_itm_id,
                l_rsp_uuid,
                l_status_cd,
                l_inf_id,
                l_correlation_id,
                l_original_request_uuid
           FROM MI_RSP s
           JOIN MI_REQ r
             ON r.REQ_ID = s.REQ_ID
           JOIN MI_INF i
             ON i.INF_ID = r.INF_ID
          WHERE s.RSP_ID = p_rsp_id;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            p_result :=
               failure_Result(
                  p_code => cErr_Response_Not_Found,
                  p_info => 'Response not found in MI_RSP'
               );
            put_Common_Context(p_result, l_call_uuid, p_rsp_id => p_rsp_id);
            RETURN;
      END;

      l_log.context(
         p_inf_id         => l_inf_id,
         p_req_id         => l_req_id,
         p_itm_id         => l_itm_id,
         p_rsp_id         => p_rsp_id,
         p_correlation_id => l_correlation_id
      );

      IF l_status_cd = MI_Response_Api.STATUS_SENT THEN
         p_result :=
            success_Result(
               p_code => RESULT_ALREADY_SENT,
               p_info => 'Response is already sent'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => l_req_id,
            p_itm_id    => l_itm_id,
            p_rsp_id    => p_rsp_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      END IF;

      IF l_status_cd <> MI_Response_Api.STATUS_READY THEN
         p_result :=
            failure_Result(
               p_code => cErr_Response_Bad_Status,
               p_info => 'Invalid response status for send'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => l_req_id,
            p_itm_id    => l_itm_id,
            p_rsp_id    => p_rsp_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      END IF;

      IF l_req_id IS NULL
         OR l_itm_id IS NULL
         OR l_rsp_uuid IS NULL
         OR l_inf_id IS NULL
         OR l_correlation_id IS NULL
         OR l_original_request_uuid IS NULL
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Response_Bad_Identity,
               p_info => 'Response identity is incomplete'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id    => l_inf_id,
            p_req_id    => l_req_id,
            p_itm_id    => l_itm_id,
            p_rsp_id    => p_rsp_id,
            p_status_cd => l_status_cd
         );
         RETURN;
      END IF;

      resolve_Transport_Settings(
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result,
         p_is_valid       => l_settings_valid
      );

      IF NOT l_settings_valid THEN
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id => l_inf_id,
            p_req_id => l_req_id,
            p_itm_id => l_itm_id,
            p_rsp_id => p_rsp_id
         );
         RETURN;
      END IF;

      SELECT XMLSERIALIZE(
                DOCUMENT XMLELEMENT(
                   "XXLRequest",
                   XMLATTRIBUTES(
                      '1.0' AS "version",
                      'send' AS "action",
                      'response' AS "message_type",
                      TO_CHAR(p_rsp_id, 'TM9') AS "rsp_id",
                      TO_CHAR(l_req_id, 'TM9') AS "req_id",
                      TO_CHAR(l_itm_id, 'TM9') AS "itm_id",
                      TO_CHAR(l_inf_id, 'TM9') AS "inf_id",
                      l_rsp_uuid AS "external_uuid",
                      l_original_request_uuid AS "original_request",
                      l_correlation_id AS "correlation_id",
                      l_call_uuid AS "call_uuid",
                      TO_CHAR(
                         l_called_at,
                         'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM'
                      ) AS "timestamp"
                   )
                )
                AS CLOB
             )
        INTO l_send_x
        FROM DUAL;

      l_log.debug(
         p_message_text => 'XXL response command prepared',
         p_action_code  => 'prepare',
         p_details_text =>
               'call_uuid='
            || l_call_uuid
            || '; request_size='
            || DBMS_LOB.getlength(l_send_x)
      );

      call_Transport_Stub(
         p_request_xml    => l_send_x,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result
      );

      put_Common_Context(
         p_result, l_call_uuid,
         p_scope     => 'RESPONSE',
         p_action    => 'send',
         p_inf_id    => l_inf_id,
         p_req_id    => l_req_id,
         p_itm_id    => l_itm_id,
         p_rsp_id    => p_rsp_id,
         p_status_cd => l_status_cd
      );

   EXCEPTION
      WHEN OTHERS THEN
         p_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => SQLCODE,
               p_sqlerrm => SQLERRM,
               p_code    => cErr_Response_Unexpected,
               p_info    => 'Unexpected error in MI_mbus.send_Response'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_inf_id => l_inf_id,
            p_req_id => l_req_id,
            p_itm_id => l_itm_id,
            p_rsp_id => p_rsp_id
         );
   END send_Response;


   ---------------------------------------------------------------------------
   PROCEDURE send_Command (
      p_result      OUT MI_ResultCtx.exec_Result_t,

      p_action      IN  VARCHAR2,

      p_inf_id      IN  MI_INF.INF_ID%TYPE DEFAULT NULL,
      p_req_id      IN  MI_REQ.REQ_ID%TYPE DEFAULT NULL,

      p_parameters  IN  CLOB DEFAULT '{}'
   )
   IS
      l_action          VARCHAR2(32767);
      l_scope           VARCHAR2(10);
      l_parameters      CLOB;
      l_is_json         PLS_INTEGER;
      l_dummy           PLS_INTEGER;

      l_call_uuid       VARCHAR2(36) := MI_Utils.uuid_V7;
      l_called_at       TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
      l_send_x          CLOB;

      l_gate_alias      VARCHAR2(100);
      l_request_ttl_ms  PLS_INTEGER;
      l_settings_valid  BOOLEAN;

      /* Queue source is intentionally UNKNOWN until Oracle bus API review. */
      l_request_queue   VARCHAR2(200) := NULL;
      l_response_queue  VARCHAR2(200) := NULL;

      l_log             MI_Logger_T := g_log;
   BEGIN
      l_action := LOWER(TRIM(p_action));
      l_parameters := p_parameters;

      IF l_parameters IS NULL THEN
         l_parameters := '{}';
      END IF;

      l_scope :=
         CASE
            WHEN p_req_id IS NOT NULL THEN 'REQUEST'
            WHEN p_inf_id IS NOT NULL THEN 'INF'
            ELSE 'XXL'
         END;

      IF p_inf_id IS NOT NULL AND p_inf_id <= 0 THEN
         p_result :=
            failure_Result(
               p_code => cErr_Command_Invalid_Inf,
               p_info => 'p_inf_id must be positive or NULL'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => l_action,
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
         RETURN;
      END IF;

      IF l_action IS NULL THEN
         p_result :=
            failure_Result(
               p_code => cErr_Command_Action_Required,
               p_info => 'p_action is required'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
         RETURN;
      END IF;

      /*
         Confirmed action whitelist is UNKNOWN. Validate a bounded routing key
         without inventing business commands. Whitespace/control characters
         are rejected; XML escaping handles the remaining printable text.
      */
      IF LENGTH(l_action) > 100
         OR REGEXP_LIKE(l_action, '[[:space:][:cntrl:]]')
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Command_Invalid_Action,
               p_info => 'p_action must be a printable routing key up to 100 characters'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => SUBSTR(l_action, 1, 100),
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
         RETURN;
      END IF;

      SELECT CASE
                WHEN l_parameters IS JSON (STRICT) THEN 1
                ELSE 0
             END
        INTO l_is_json
        FROM DUAL;

      IF l_is_json = 0
         OR NOT REGEXP_LIKE(l_parameters, '^[[:space:]]*[{]', 'n')
         OR NOT REGEXP_LIKE(l_parameters, '[}][[:space:]]*$', 'n')
      THEN
         p_result :=
            failure_Result(
               p_code => cErr_Command_Bad_Parameters,
               p_info => 'p_parameters must be a strict JSON object'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => l_action,
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
         put_Number(
            p_result,
            'parameters_size',
            DBMS_LOB.getlength(l_parameters)
         );
         RETURN;
      END IF;

      IF p_inf_id IS NOT NULL THEN
         BEGIN
            SELECT 1
              INTO l_dummy
              FROM MI_INF
             WHERE INF_ID = p_inf_id;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               p_result :=
                  failure_Result(
                     p_code => cErr_Command_Inf_Not_Found,
                     p_info => 'Information type not found in MI_INF'
                  );
               put_Common_Context(
                  p_result, l_call_uuid,
                  p_scope  => l_scope,
                  p_action => l_action,
                  p_inf_id => p_inf_id,
                  p_req_id => p_req_id
               );
               RETURN;
         END;
      END IF;

      resolve_Transport_Settings(
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result,
         p_is_valid       => l_settings_valid
      );

      IF NOT l_settings_valid THEN
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => l_action,
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
         RETURN;
      END IF;

      SELECT XMLSERIALIZE(
                DOCUMENT XMLELEMENT(
                   "XXLRequest",
                   XMLATTRIBUTES(
                      '1.0' AS "version",
                      l_action AS "action",
                      CASE
                         WHEN p_req_id IS NOT NULL
                         THEN TO_CHAR(p_req_id, 'TM9')
                      END AS "req_id",
                      CASE
                         WHEN p_inf_id IS NOT NULL
                         THEN TO_CHAR(p_inf_id, 'TM9')
                      END AS "inf_id",
                      l_call_uuid AS "call_uuid",
                      TO_CHAR(
                         l_called_at,
                         'YYYY-MM-DD"T"HH24:MI:SS.FF3 TZH:TZM'
                      ) AS "timestamp"
                   ),
                   XMLELEMENT("parameters", l_parameters)
                )
                AS CLOB
             )
        INTO l_send_x
        FROM DUAL;

      l_log.context(
         p_inf_id => p_inf_id,
         p_req_id => p_req_id
      );
      l_log.debug(
         p_message_text => 'XXL command prepared',
         p_action_code  => 'prepare',
         p_details_text =>
               'scope='
            || l_scope
            || '; action='
            || l_action
            || '; call_uuid='
            || l_call_uuid
            || '; request_size='
            || DBMS_LOB.getlength(l_send_x)
            || '; parameters_size='
            || DBMS_LOB.getlength(l_parameters)
      );

      call_Transport_Stub(
         p_request_xml    => l_send_x,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_gate_alias     => l_gate_alias,
         p_request_ttl_ms => l_request_ttl_ms,
         p_result         => p_result
      );

      put_Common_Context(
         p_result, l_call_uuid,
         p_scope  => l_scope,
         p_action => l_action,
         p_inf_id => p_inf_id,
         p_req_id => p_req_id
      );
      put_Number(
         p_result,
         'parameters_size',
         DBMS_LOB.getlength(l_parameters)
      );

   EXCEPTION
      WHEN OTHERS THEN
         p_result :=
            MI_ResultCtx.from_Exception(
               p_sqlcode => SQLCODE,
               p_sqlerrm => SQLERRM,
               p_code    => cErr_Command_Unexpected,
               p_info    => 'Unexpected error in MI_mbus.send_Command'
            );
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => l_action,
            p_inf_id => p_inf_id,
            p_req_id => p_req_id
         );
   END send_Command;

END MI_mbus;
/
