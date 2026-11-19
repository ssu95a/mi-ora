CREATE OR REPLACE PACKAGE MI_mbus
IS

   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.2.1} {19.11.2026} Sulimoff$';


   RESULT_ALREADY_IN_PROGRESS CONSTANT VARCHAR2(100) := 'ALREADY_IN_PROGRESS';
   RESULT_ALREADY_SENT        CONSTANT VARCHAR2(100) := 'ALREADY_SENT';
   RESULT_ALREADY_COMPLETED   CONSTANT VARCHAR2(100) := 'ALREADY_COMPLETED';
   /* Оставлено для source compatibility; transport больше не возвращает его. */
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
   cErr_Request_Bus_Return CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#X_TO_XXL_TRANSPORT_ERROR';
   cErr_Request_Empty_Response CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#XXL_RESPONSE_EMPTY';
   cErr_Request_Response_Parse CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_REQUEST#XXL_RESPONSE_PARSE_ERROR';

   cErr_Response_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#RESPONSE_NOT_FOUND';
   cErr_Response_Bad_Status CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#BAD_STATUS';
   cErr_Response_Bad_Identity CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#INVALID_IDENTITY';
   cErr_Response_Unexpected CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#UNEXPECTED';
   cErr_Response_Bus_Return CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#X_TO_XXL_TRANSPORT_ERROR';
   cErr_Response_Empty_Response CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#XXL_RESPONSE_EMPTY';
   cErr_Response_Response_Parse CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_RESPONSE#XXL_RESPONSE_PARSE_ERROR';

   cErr_Command_Invalid_Inf CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_INF_ID';
   cErr_Command_Inf_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INF_NOT_FOUND';
   cErr_Command_Request_Not_Found CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#REQUEST_NOT_FOUND';
   cErr_Command_Inf_Mismatch CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INF_ID_MISMATCH';
   cErr_Command_Action_Required CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#ACTION_REQUIRED';
   cErr_Command_Invalid_Action CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_ACTION';
   cErr_Command_Bad_Parameters CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#INVALID_PARAMETERS';
   cErr_Command_Unexpected CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#UNEXPECTED';
   cErr_Command_Bus_Return CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#X_TO_XXL_TRANSPORT_ERROR';
   cErr_Command_Empty_Response CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#XXL_RESPONSE_EMPTY';
   cErr_Command_Response_Parse CONSTANT VARCHAR2(100) :=
      'MI_MBUS.SEND_COMMAND#XXL_RESPONSE_PARSE_ERROR';

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
      MI_ResultCtx.put_Parameter(p_result, 'call_uuid', p_call_uuid);
      MI_ResultCtx.put_Parameter(p_result, 'scope', p_scope);
      MI_ResultCtx.put_Parameter(p_result, 'action', p_action);

      MI_ResultCtx.put_Number(p_result, 'inf_id', p_inf_id);
      MI_ResultCtx.put_Number(p_result, 'req_id', p_req_id);
      MI_ResultCtx.put_Number(p_result, 'itm_id', p_itm_id);
      MI_ResultCtx.put_Number(p_result, 'rsp_id', p_rsp_id);
      MI_ResultCtx.put_Number(p_result, 'status_cd', p_status_cd);
   END put_Common_Context;


   ---------------------------------------------------------------------------
   FUNCTION scoped_Property (
      p_inf_id      IN MI_INF.INF_ID%TYPE,
      p_wsp_id      IN MI_WSP.WSP_ID%TYPE,
      p_property    IN VARCHAR2,
      p_def_value   IN VARCHAR2 DEFAULT NULL
   )
      RETURN VARCHAR2
   IS
      l_value VARCHAR2(32767);
   BEGIN
      l_value :=
         MI_Prp.get_Sys_Property(
            p_prp_id    => p_property,
            p_def_value => p_def_value
         );

      IF p_wsp_id IS NOT NULL THEN
         l_value :=
            MI_Prp.get_Wsp_Property(
               p_wsp_id    => p_wsp_id,
               p_prp_id    => p_property,
               p_def_value => l_value
            );
      END IF;

      IF p_inf_id IS NOT NULL THEN
         l_value :=
            MI_Prp.get_Inf_Property(
               p_inf_id    => p_inf_id,
               p_prp_id    => p_property,
               p_def_value => l_value
            );
      END IF;

      RETURN TRIM(l_value);
   END scoped_Property;


   ---------------------------------------------------------------------------
   PROCEDURE resolve_Transport_Settings (
      p_inf_id          IN  MI_INF.INF_ID%TYPE,
      p_wsp_id          IN  MI_WSP.WSP_ID%TYPE,
      p_gate_alias      OUT VARCHAR2,
      p_request_queue   OUT VARCHAR2,
      p_response_queue  OUT VARCHAR2,
      p_timeout_sec     OUT PLS_INTEGER,
      p_result          OUT MI_ResultCtx.exec_Result_t,
      p_is_valid        OUT BOOLEAN
   )
   IS
      l_gate_alias      VARCHAR2(32767);
      l_request_queue   VARCHAR2(32767);
      l_response_queue  VARCHAR2(32767);
      l_timeout_text    VARCHAR2(32767);
      l_timeout_num     NUMBER;

      PROCEDURE invalid_Property (
         p_property  IN VARCHAR2,
         p_info      IN VARCHAR2
      )
      IS
      BEGIN
         p_result :=
            MI_ResultCtx.failure(
               p_code => cErr_Transport_Config,
               p_info => p_info
            );
         MI_ResultCtx.put_Parameter(p_result, 'property_name', p_property);
      END invalid_Property;
   BEGIN
      p_is_valid := FALSE;

      l_gate_alias :=
         scoped_Property(
            p_inf_id    => p_inf_id,
            p_wsp_id    => p_wsp_id,
            p_property  => 'MBUS_GATE',
            p_def_value => cMultiBus_Gate
         );
      l_request_queue :=
         scoped_Property(
            p_inf_id   => p_inf_id,
            p_wsp_id   => p_wsp_id,
            p_property => 'MBUS_REQUEST_QUEUE'
         );
      l_response_queue :=
         scoped_Property(
            p_inf_id   => p_inf_id,
            p_wsp_id   => p_wsp_id,
            p_property => 'MBUS_RESPONSE_QUEUE'
         );
      l_timeout_text :=
         scoped_Property(
            p_inf_id    => p_inf_id,
            p_wsp_id    => p_wsp_id,
            p_property  => 'MBUS_REQUEST_TIMEOUT_SEC',
            p_def_value => '30'
         );

      IF l_gate_alias IS NULL OR LENGTH(l_gate_alias) > 100 THEN
         invalid_Property(
            'MBUS_GATE',
            'MBUS_GATE is required and must not exceed 100 characters'
         );
         RETURN;
      END IF;

      IF l_request_queue IS NULL OR LENGTH(l_request_queue) > 100 THEN
         invalid_Property(
            'MBUS_REQUEST_QUEUE',
            'MBUS_REQUEST_QUEUE is required and must not exceed 100 characters'
         );
         RETURN;
      END IF;

      IF l_response_queue IS NULL OR LENGTH(l_response_queue) > 100 THEN
         invalid_Property(
            'MBUS_RESPONSE_QUEUE',
            'MBUS_RESPONSE_QUEUE is required and must not exceed 100 characters'
         );
         RETURN;
      END IF;

      BEGIN
         l_timeout_num := TO_NUMBER(l_timeout_text);
      EXCEPTION
         WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            invalid_Property(
               'MBUS_REQUEST_TIMEOUT_SEC',
               'MBUS_REQUEST_TIMEOUT_SEC must be a positive integer'
            );
            RETURN;
      END;

      IF l_timeout_num <= 0
         OR l_timeout_num <> TRUNC(l_timeout_num)
         OR l_timeout_num > 2147483647
      THEN
         invalid_Property(
            'MBUS_REQUEST_TIMEOUT_SEC',
            'MBUS_REQUEST_TIMEOUT_SEC must be a positive integer'
         );
         RETURN;
      END IF;

      p_gate_alias := l_gate_alias;
      p_request_queue := l_request_queue;
      p_response_queue := l_response_queue;
      p_timeout_sec := l_timeout_num;
      p_is_valid := TRUE;
   END resolve_Transport_Settings;


   ---------------------------------------------------------------------------
   PROCEDURE call_Transport (
      p_request_xml         IN  CLOB,
      p_expected_action     IN  VARCHAR2,
      p_request_queue       IN  VARCHAR2,
      p_response_queue      IN  VARCHAR2,
      p_gate_alias          IN  VARCHAR2,
      p_timeout_sec         IN  PLS_INTEGER,
      p_bus_error_code      IN  VARCHAR2,
      p_empty_response_code IN  VARCHAR2,
      p_parse_error_code    IN  VARCHAR2,
      p_result              OUT MI_ResultCtx.exec_Result_t
   )
   IS
      l_response_xml  CLOB;
      l_error_message VARCHAR2(32767);
      l_correlation   VARCHAR2(2000);
      l_bus_result    NUMBER;
      l_response_size PLS_INTEGER := 0;
   BEGIN
      IF p_request_xml IS NULL THEN
         p_result :=
            MI_ResultCtx.failure(
               p_code => 'MI_MBUS.TRANSPORT#EMPTY_REQUEST',
               p_info => 'XXLRequest was not prepared'
            );
         RETURN;
      END IF;

      BEGIN
         l_bus_result :=
            CBS_BUS.QUERY_BUS_CLOB(
               cSqueue_name => p_request_queue,
               cDqueue_name => p_response_queue,
               clXml        => p_request_xml,
               cCor         => l_correlation,
               busType      => p_gate_alias,
               nWait        => p_timeout_sec,
               SOUT         => l_response_xml,
               ERRORMSG     => l_error_message
            );

      EXCEPTION
         WHEN OTHERS THEN
            p_result :=
               MI_ResultCtx.from_Exception(
                  p_sqlcode => SQLCODE,
                  p_sqlerrm => SQLERRM,
                  p_code    => p_bus_error_code,
                  p_info    =>
                     'Oracle Multi-Bus call failed; delivery outcome is unknown'
               );
            MI_ResultCtx.put_Parameter(p_result, 'delivery_outcome', 'UNKNOWN');
            MI_ResultCtx.put_Parameter(p_result, 'retry_safe', '0');
            MI_ResultCtx.put_Parameter(p_result, 'request_queue', p_request_queue);
            MI_ResultCtx.put_Parameter(p_result, 'response_queue', p_response_queue);
            MI_ResultCtx.put_Parameter(p_result, 'gate_alias', p_gate_alias);
            MI_ResultCtx.put_Number(p_result, 'timeout_sec', p_timeout_sec);
            RETURN;
      END;

      IF l_response_xml IS NOT NULL THEN
         l_response_size := DBMS_LOB.getlength(l_response_xml);
      END IF;

      g_log.debug(
         p_message_text => 'Oracle Multi-Bus call completed',
         p_action_code  => 'transport',
         p_details_text =>
               'bus_result_code='
            || NVL(TO_CHAR(l_bus_result, 'TM9'), '<NULL>')
            || '; response_size='
            || TO_CHAR(l_response_size, 'TM9')
      );

      IF NVL(l_bus_result, -1) <> 0 THEN
         p_result :=
            MI_ResultCtx.failure(
               p_code       => p_bus_error_code,
               p_info       => 'Oracle Multi-Bus returned an error',
               p_cause_code => 'MBUS_ERROR',
               p_cause_info => SUBSTR(l_error_message, 1, 2000)
            );
         MI_ResultCtx.put_Parameter(p_result, 'delivery_outcome', 'UNKNOWN');
         MI_ResultCtx.put_Parameter(p_result, 'retry_safe', '0');
      ELSIF l_response_size = 0
         OR REGEXP_LIKE(
               DBMS_LOB.SUBSTR(l_response_xml, 4000, 1),
               '^[[:space:]]*$'
            )
      THEN
         p_result :=
            MI_ResultCtx.failure(
               p_code => p_empty_response_code,
               p_info => 'XXLResponse is empty'
            );
         MI_ResultCtx.put_Parameter(p_result, 'delivery_outcome', 'UNKNOWN');
         MI_ResultCtx.put_Parameter(p_result, 'retry_safe', '0');
      ELSE
         BEGIN
            p_result :=
               MI_ResultCtx.result_From_Xml(
                  p_xml             => l_response_xml,
                  p_expected_action => p_expected_action
               );
         EXCEPTION
            WHEN OTHERS THEN
               p_result :=
                  MI_ResultCtx.from_Exception(
                     p_sqlcode => SQLCODE,
                     p_sqlerrm => SQLERRM,
                     p_code    => p_parse_error_code,
                     p_info    => 'Error parsing XXLResponse'
                  );
               MI_ResultCtx.put_Parameter(p_result, 'delivery_outcome', 'UNKNOWN');
               MI_ResultCtx.put_Parameter(p_result, 'retry_safe', '0');
         END;
      END IF;

      MI_ResultCtx.put_Number(p_result, 'request_size', DBMS_LOB.getlength(p_request_xml));
      MI_ResultCtx.put_Number(p_result, 'response_size', l_response_size);
      MI_ResultCtx.put_Number(p_result, 'bus_result_code', l_bus_result);
      MI_ResultCtx.put_Parameter(p_result, 'bus_correlation_id', l_correlation);
      MI_ResultCtx.put_Parameter(p_result, 'request_queue', p_request_queue);
      MI_ResultCtx.put_Parameter(p_result, 'response_queue', p_response_queue);
      MI_ResultCtx.put_Parameter(p_result, 'gate_alias', p_gate_alias);
      MI_ResultCtx.put_Number(p_result, 'timeout_sec', p_timeout_sec);
   END call_Transport;


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
      l_request_queue   VARCHAR2(100);
      l_response_queue  VARCHAR2(100);
      l_timeout_sec     PLS_INTEGER;
      l_settings_valid  BOOLEAN;

      l_log             MI_Logger_T := g_log;
   BEGIN
      IF p_req_id IS NULL THEN
         p_result :=
            MI_ResultCtx.failure(
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
               MI_ResultCtx.failure(
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
            MI_ResultCtx.success(
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
            MI_ResultCtx.success(
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
            MI_ResultCtx.success(
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
            MI_ResultCtx.failure(
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
            MI_ResultCtx.failure(
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
         p_inf_id         => l_inf_id,
         p_wsp_id         => l_wsp_id,
         p_gate_alias     => l_gate_alias,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_timeout_sec    => l_timeout_sec,
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

      call_Transport(
         p_request_xml         => l_send_x,
         p_expected_action     => 'send',
         p_request_queue       => l_request_queue,
         p_response_queue      => l_response_queue,
         p_gate_alias          => l_gate_alias,
         p_timeout_sec         => l_timeout_sec,
         p_bus_error_code      => cErr_Request_Bus_Return,
         p_empty_response_code => cErr_Request_Empty_Response,
         p_parse_error_code    => cErr_Request_Response_Parse,
         p_result              => p_result
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
      l_wsp_id                MI_INF.WSP_ID%TYPE;
      l_correlation_id        MI_REQ.CORRELATION_ID%TYPE;
      l_original_request_uuid MI_REQ.ORIGINAL_REQ_UUID%TYPE;

      l_call_uuid             VARCHAR2(36) := MI_Utils.uuid_V7;
      l_called_at             TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
      l_send_x                CLOB;

      l_gate_alias            VARCHAR2(100);
      l_request_queue         VARCHAR2(100);
      l_response_queue        VARCHAR2(100);
      l_timeout_sec           PLS_INTEGER;
      l_settings_valid        BOOLEAN;

      l_log                   MI_Logger_T := g_log;
   BEGIN
      IF p_rsp_id IS NULL THEN
         p_result :=
            MI_ResultCtx.failure(
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
                i.WSP_ID,
                TRIM(r.CORRELATION_ID),
                TRIM(r.ORIGINAL_REQ_UUID)
           INTO l_req_id,
                l_itm_id,
                l_rsp_uuid,
                l_status_cd,
                l_inf_id,
                l_wsp_id,
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
               MI_ResultCtx.failure(
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
            MI_ResultCtx.success(
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
            MI_ResultCtx.failure(
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
         OR l_wsp_id IS NULL
         OR l_correlation_id IS NULL
         OR l_original_request_uuid IS NULL
      THEN
         p_result :=
            MI_ResultCtx.failure(
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
         p_inf_id         => l_inf_id,
         p_wsp_id         => l_wsp_id,
         p_gate_alias     => l_gate_alias,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_timeout_sec    => l_timeout_sec,
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

      call_Transport(
         p_request_xml         => l_send_x,
         p_expected_action     => 'send',
         p_request_queue       => l_request_queue,
         p_response_queue      => l_response_queue,
         p_gate_alias          => l_gate_alias,
         p_timeout_sec         => l_timeout_sec,
         p_bus_error_code      => cErr_Response_Bus_Return,
         p_empty_response_code => cErr_Response_Empty_Response,
         p_parse_error_code    => cErr_Response_Response_Parse,
         p_result              => p_result
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
      l_resolved_inf_id MI_INF.INF_ID%TYPE;
      l_wsp_id          MI_INF.WSP_ID%TYPE;

      l_call_uuid       VARCHAR2(36) := MI_Utils.uuid_V7;
      l_called_at       TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
      l_send_x          CLOB;

      l_gate_alias      VARCHAR2(100);
      l_request_queue   VARCHAR2(100);
      l_response_queue  VARCHAR2(100);
      l_timeout_sec     PLS_INTEGER;
      l_settings_valid  BOOLEAN;

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
            MI_ResultCtx.failure(
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
            MI_ResultCtx.failure(
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
            MI_ResultCtx.failure(
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
            MI_ResultCtx.failure(
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
         MI_ResultCtx.put_Number(
            p_result,
            'parameters_size',
            DBMS_LOB.getlength(l_parameters)
         );
         RETURN;
      END IF;

      IF p_req_id IS NOT NULL THEN
         BEGIN
            SELECT r.INF_ID,
                   i.WSP_ID
              INTO l_resolved_inf_id,
                   l_wsp_id
              FROM MI_REQ r
              JOIN MI_INF i
                ON i.INF_ID = r.INF_ID
             WHERE r.REQ_ID = p_req_id;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               p_result :=
                  MI_ResultCtx.failure(
                     p_code => cErr_Command_Request_Not_Found,
                     p_info => 'Request not found in MI_REQ'
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

         IF p_inf_id IS NOT NULL AND p_inf_id <> l_resolved_inf_id THEN
            p_result :=
               MI_ResultCtx.failure(
                  p_code => cErr_Command_Inf_Mismatch,
                  p_info => 'p_inf_id does not match MI_REQ.INF_ID'
               );
            put_Common_Context(
               p_result, l_call_uuid,
               p_scope  => l_scope,
               p_action => l_action,
               p_inf_id => l_resolved_inf_id,
               p_req_id => p_req_id
            );
            MI_ResultCtx.put_Number(p_result, 'provided_inf_id', p_inf_id);
            RETURN;
         END IF;

      ELSIF p_inf_id IS NOT NULL THEN
         BEGIN
            SELECT INF_ID,
                   WSP_ID
              INTO l_resolved_inf_id,
                   l_wsp_id
              FROM MI_INF
             WHERE INF_ID = p_inf_id;

         EXCEPTION
            WHEN NO_DATA_FOUND THEN
               p_result :=
                  MI_ResultCtx.failure(
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
         p_inf_id         => l_resolved_inf_id,
         p_wsp_id         => l_wsp_id,
         p_gate_alias     => l_gate_alias,
         p_request_queue  => l_request_queue,
         p_response_queue => l_response_queue,
         p_timeout_sec    => l_timeout_sec,
         p_result         => p_result,
         p_is_valid       => l_settings_valid
      );

      IF NOT l_settings_valid THEN
         put_Common_Context(
            p_result, l_call_uuid,
            p_scope  => l_scope,
            p_action => l_action,
            p_inf_id => l_resolved_inf_id,
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
                         WHEN l_resolved_inf_id IS NOT NULL
                         THEN TO_CHAR(l_resolved_inf_id, 'TM9')
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
         p_inf_id => l_resolved_inf_id,
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

      call_Transport(
         p_request_xml         => l_send_x,
         p_expected_action     => l_action,
         p_request_queue       => l_request_queue,
         p_response_queue      => l_response_queue,
         p_gate_alias          => l_gate_alias,
         p_timeout_sec         => l_timeout_sec,
         p_bus_error_code      => cErr_Command_Bus_Return,
         p_empty_response_code => cErr_Command_Empty_Response,
         p_parse_error_code    => cErr_Command_Response_Parse,
         p_result              => p_result
      );

      put_Common_Context(
         p_result, l_call_uuid,
         p_scope  => l_scope,
         p_action => l_action,
         p_inf_id => l_resolved_inf_id,
         p_req_id => p_req_id
      );
      MI_ResultCtx.put_Number(
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
            p_inf_id => l_resolved_inf_id,
            p_req_id => p_req_id
         );
   END send_Command;

END MI_mbus;
/
