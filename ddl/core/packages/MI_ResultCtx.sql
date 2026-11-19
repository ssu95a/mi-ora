CREATE OR REPLACE PACKAGE MI_ResultCtx
IS
   PRAGMA SERIALLY_REUSABLE;


   VERSION CONSTANT VARCHAR2(100) :=
      '$Id: {1.3.0} {19.11.2026} Sulimoff$';


   cResult_Success CONSTANT VARCHAR2(100) := 'SUCCESS';
   cResult_Error   CONSTANT VARCHAR2(100) := 'ERROR';

   /*
      Технический код transport exception.

      Он не является бизнес-кодом ошибки.
      Реальный код результата хранится в exec_Result_t.result_code.
   */
   cResult_Failed_Code CONSTANT PLS_INTEGER := -20002;


   /*
      Результат выполнения операции.

      parameters — произвольный набор именованных строковых параметров.
      Тип объявлен в MI_Utils, чтобы использовать единый контракт
      во всём MI Core.
   */
   TYPE exec_Result_t IS RECORD
   (
      is_success      BOOLEAN,

      result_code     VARCHAR2(100),
      result_info     VARCHAR2(300),
      result_details  CLOB,

      cause_code      VARCHAR2(100),
      cause_info      VARCHAR2(2000),
      cause_details   CLOB,

      parameters      MI_Utils.ParameterList_t
   );


   /*
      Исключение-транспорт для exec_Result_t.

      Структурированный результат хранится во внутреннем package state
      и существует только в пределах текущего server call.
   */
   result_Failed_Exc EXCEPTION;

   PRAGMA EXCEPTION_INIT(
      result_Failed_Exc,
      -20002
   );


   FUNCTION get_Version
      RETURN VARCHAR2;


   FUNCTION success (
      p_code     IN VARCHAR2 DEFAULT NULL,
      p_info     IN VARCHAR2 DEFAULT 'Завершено успешно',
      p_details  IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   FUNCTION failure (
      p_code          IN VARCHAR2 DEFAULT NULL,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   FUNCTION is_Success (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN;


   FUNCTION is_Failed (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN;


   /*
      Единый доступ к именованным parameters результата.

      NULL не записывается, чтобы отсутствие параметра сохраняло прежнюю
      семантику. result_Number возвращает NULL как для отсутствующего, так и
      для нечислового значения.
   */
   PROCEDURE put_Parameter (
      p_result  IN OUT NOCOPY exec_Result_t,
      p_name    IN VARCHAR2,
      p_value   IN VARCHAR2
   );


   PROCEDURE put_Number (
      p_result  IN OUT NOCOPY exec_Result_t,
      p_name    IN VARCHAR2,
      p_value   IN NUMBER
   );


   FUNCTION result_Number (
      p_result  IN exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN NUMBER;


   /*
      Экспорт structured result в старый JDBC OUT contract.

      Коды успеха/ошибки задаёт вызывающий API: MI_ResultCtx не владеет
      бизнес-значениями RET_*.
   */
   PROCEDURE export_Jdbc_Result (
      p_result        IN  exec_Result_t,
      p_success_code  IN  NUMBER,
      p_failure_code  IN  NUMBER,
      p_ret_code      OUT NUMBER,
      p_ret_info      OUT VARCHAR2
   );


   /*
      Разобрать синхронный XXLResponse.

      Oracle 12.1 не предоставляет JSON_OBJECT_T. Поэтому JSON object из
      элемента parameters разбирается без зависимости от APEX_JSON:

         scalar string  -> декодированная строка;
         number/boolean -> JSON lexical value;
         object/array   -> JSON text;
         null           -> NULL.

      Имена ограничены контрактом ParameterList_t (100 символов), значения —
      2000 символов. Значение, которое нельзя представить без потери данных,
      считается ошибкой формата ответа.

      Для успешного ответа p_expected_action, если он задан, должен совпадать
      с action. Failure-response сохраняется независимо от action: Java error
      mapper может выставлять для него action по умолчанию.
   */
   FUNCTION result_From_Xml (
      p_xml              IN CLOB,
      p_expected_action  IN VARCHAR2 DEFAULT NULL
   )
      RETURN exec_Result_t;


   /*
      Доступ к текущему structured result, сохранённому transport exception.
   */
   FUNCTION has_Current_Result
      RETURN BOOLEAN;


   FUNCTION current_Result
      RETURN exec_Result_t;


   PROCEDURE clear_Current;


   /*
      Бросить structured error.

      Если p_result успешный, процедура ничего не делает.
   */
   PROCEDURE raise_Error (
      p_result IN exec_Result_t
   );


   PROCEDURE raise_Error (
      p_code          IN VARCHAR2,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   );


   /*
      Преобразовать пойманное Oracle exception в exec_Result_t.

      Вызывать из EXCEPTION handler:

         l_result := MI_ResultCtx.from_Exception(
            p_sqlcode => SQLCODE,
            p_sqlerrm => SQLERRM
         );

      SQLCODE/SQLERRM передаются явно, потому что вне exception handler
      SQLCODE возвращает 0.

      Если p_sqlcode = cResult_Failed_Code и package содержит current result,
      исходный structured result возвращается без потери данных.
   */
   FUNCTION from_Exception (
      p_sqlcode IN PLS_INTEGER,
      p_sqlerrm IN VARCHAR2,

      p_code    IN VARCHAR2 DEFAULT NULL,
      p_info    IN VARCHAR2 DEFAULT NULL,
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;


   /*
      Обернуть существующий result новым уровнем ошибки.

      Исходный result становится cause.
      Его parameters сохраняются.
   */
   FUNCTION wrap_Exception (
      p_cause   IN exec_Result_t,

      p_code    IN VARCHAR2,
      p_info    IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t;

END MI_ResultCtx;
/

CREATE OR REPLACE PACKAGE BODY MI_ResultCtx
IS
   PRAGMA SERIALLY_REUSABLE;


   g_exec_result exec_Result_t;
   g_has_current BOOLEAN := FALSE;


   ---------------------------------------------------------------------------
   FUNCTION get_Version
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN VERSION;
   END get_Version;


   ---------------------------------------------------------------------------
   PROCEDURE clear_Current
   IS
   BEGIN
      g_exec_result.is_success     := NULL;

      g_exec_result.result_code    := NULL;
      g_exec_result.result_info    := NULL;
      g_exec_result.result_details := NULL;

      g_exec_result.cause_code     := NULL;
      g_exec_result.cause_info     := NULL;
      g_exec_result.cause_details  := NULL;

      g_exec_result.parameters.DELETE;

      g_has_current := FALSE;
   END clear_Current;


   ---------------------------------------------------------------------------
   PROCEDURE set_Current (
      p_result IN exec_Result_t
   )
   IS
   BEGIN
      g_exec_result.is_success     := p_result.is_success;

      g_exec_result.result_code    := p_result.result_code;
      g_exec_result.result_info    := p_result.result_info;
      g_exec_result.result_details := p_result.result_details;

      g_exec_result.cause_code     := p_result.cause_code;
      g_exec_result.cause_info     := p_result.cause_info;
      g_exec_result.cause_details  := p_result.cause_details;

      g_exec_result.parameters := p_result.parameters;

      g_has_current := TRUE;
   END set_Current;


   ---------------------------------------------------------------------------
   FUNCTION has_Current_Result
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN g_has_current;
   END has_Current_Result;


   ---------------------------------------------------------------------------
   FUNCTION current_Result
      RETURN exec_Result_t
   IS
   BEGIN
      RETURN g_exec_result;
   END current_Result;


   ---------------------------------------------------------------------------
   FUNCTION success (
      p_code     IN VARCHAR2 DEFAULT NULL,
      p_info     IN VARCHAR2 DEFAULT 'Завершено успешно',
      p_details  IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result.is_success := TRUE;

      l_result.result_code :=
         SUBSTR(
            NVL(p_code, cResult_Success),
            1,
            100
         );

      l_result.result_info :=
         SUBSTR(
            p_info,
            1,
            300
         );

      l_result.result_details := p_details;

      RETURN l_result;
   END success;


   ---------------------------------------------------------------------------
   FUNCTION failure (
      p_code          IN VARCHAR2 DEFAULT NULL,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result.is_success := FALSE;

      l_result.result_code :=
         SUBSTR(
            NVL(p_code, cResult_Error),
            1,
            100
         );

      l_result.result_info :=
         SUBSTR(
            p_info,
            1,
            300
         );

      l_result.result_details := p_details;

      l_result.cause_code :=
         SUBSTR(
            p_cause_code,
            1,
            100
         );

      l_result.cause_info :=
         SUBSTR(
            p_cause_info,
            1,
            2000
         );

      l_result.cause_details := p_cause_details;

      RETURN l_result;
   END failure;


   ---------------------------------------------------------------------------
   FUNCTION is_Success (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN
   IS
   BEGIN
      IF p_result.is_success THEN
         RETURN TRUE;
      END IF;

      RETURN FALSE;
   END is_Success;


   ---------------------------------------------------------------------------
   FUNCTION is_Failed (
      p_result IN exec_Result_t
   )
      RETURN BOOLEAN
   IS
   BEGIN
      RETURN NOT is_Success(p_result);
   END is_Failed;


   ---------------------------------------------------------------------------
   PROCEDURE put_Parameter (
      p_result  IN OUT NOCOPY exec_Result_t,
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
      p_result  IN OUT NOCOPY exec_Result_t,
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
   FUNCTION result_Number (
      p_result  IN exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters(p_name));
   EXCEPTION
      WHEN NO_DATA_FOUND OR VALUE_ERROR OR INVALID_NUMBER THEN
         RETURN NULL;
   END result_Number;


   ---------------------------------------------------------------------------
   PROCEDURE export_Jdbc_Result (
      p_result        IN  exec_Result_t,
      p_success_code  IN  NUMBER,
      p_failure_code  IN  NUMBER,
      p_ret_code      OUT NUMBER,
      p_ret_info      OUT VARCHAR2
   )
   IS
   BEGIN
      p_ret_code := result_Number(p_result, 'ret_code');

      IF p_ret_code IS NULL THEN
         IF is_Success(p_result) THEN
            p_ret_code := p_success_code;
         ELSE
            p_ret_code := p_failure_code;
         END IF;
      END IF;

      p_ret_info :=
         SUBSTR(
               NVL(p_result.result_code, '<NO_RESULT_CODE>')
            || ': '
            || NVL(p_result.result_info, '<NO_RESULT_INFO>')
            || CASE
                  WHEN p_result.cause_code IS NOT NULL
                     OR p_result.cause_info IS NOT NULL
                  THEN
                        '; cause='
                     || NVL(p_result.cause_code, '<NO_CAUSE_CODE>')
                     || ': '
                     || NVL(p_result.cause_info, '<NO_CAUSE_INFO>')
                  ELSE NULL
               END,
            1,
            4000
         );
   END export_Jdbc_Result;


   ---------------------------------------------------------------------------
   PROCEDURE response_Parse_Error (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20011,
         SUBSTR('Invalid XXLResponse: ' || p_message, 1, 2000)
      );
   END response_Parse_Error;


   ---------------------------------------------------------------------------
   FUNCTION json_Char (
      p_json  IN CLOB,
      p_pos   IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN DBMS_LOB.SUBSTR(p_json, 1, p_pos);
   END json_Char;


   ---------------------------------------------------------------------------
   PROCEDURE json_Skip_Whitespace (
      p_json  IN     CLOB,
      p_pos   IN OUT PLS_INTEGER,
      p_len   IN     PLS_INTEGER
   )
   IS
      l_char VARCHAR2(1);
   BEGIN
      WHILE p_pos <= p_len LOOP
         l_char := json_Char(p_json, p_pos);
         EXIT WHEN l_char NOT IN (' ', CHR(9), CHR(10), CHR(13));
         p_pos := p_pos + 1;
      END LOOP;
   END json_Skip_Whitespace;


   ---------------------------------------------------------------------------
   FUNCTION json_String_End (
      p_json       IN CLOB,
      p_start_pos  IN PLS_INTEGER,
      p_len        IN PLS_INTEGER
   )
      RETURN PLS_INTEGER
   IS
      l_pos   PLS_INTEGER := p_start_pos + 1;
      l_char  VARCHAR2(1);
   BEGIN
      WHILE l_pos <= p_len LOOP
         l_char := json_Char(p_json, l_pos);

         IF l_char = CHR(92) THEN
            l_pos := l_pos + 2;
         ELSIF l_char = '"' THEN
            RETURN l_pos;
         ELSE
            l_pos := l_pos + 1;
         END IF;
      END LOOP;

      response_Parse_Error('unterminated JSON string');
      RETURN NULL;
   END json_String_End;


   ---------------------------------------------------------------------------
   FUNCTION json_Composite_End (
      p_json       IN CLOB,
      p_start_pos  IN PLS_INTEGER,
      p_len        IN PLS_INTEGER
   )
      RETURN PLS_INTEGER
   IS
      l_pos    PLS_INTEGER := p_start_pos;
      l_depth  PLS_INTEGER := 0;
      l_char   VARCHAR2(1);
   BEGIN
      WHILE l_pos <= p_len LOOP
         l_char := json_Char(p_json, l_pos);

         IF l_char = '"' THEN
            l_pos := json_String_End(p_json, l_pos, p_len) + 1;
         ELSE
            IF l_char IN ('{', '[') THEN
               l_depth := l_depth + 1;
            ELSIF l_char IN ('}', ']') THEN
               l_depth := l_depth - 1;

               IF l_depth = 0 THEN
                  RETURN l_pos;
               END IF;
            END IF;

            l_pos := l_pos + 1;
         END IF;
      END LOOP;

      response_Parse_Error('unterminated JSON object or array');
      RETURN NULL;
   END json_Composite_End;


   ---------------------------------------------------------------------------
   FUNCTION json_Value_End (
      p_json       IN CLOB,
      p_start_pos  IN PLS_INTEGER,
      p_len        IN PLS_INTEGER
   )
      RETURN PLS_INTEGER
   IS
      l_pos   PLS_INTEGER := p_start_pos;
      l_char  VARCHAR2(1);
   BEGIN
      l_char := json_Char(p_json, l_pos);

      IF l_char = '"' THEN
         RETURN json_String_End(p_json, l_pos, p_len);
      ELSIF l_char IN ('{', '[') THEN
         RETURN json_Composite_End(p_json, l_pos, p_len);
      END IF;

      WHILE l_pos <= p_len LOOP
         l_char := json_Char(p_json, l_pos);
         EXIT WHEN l_char IN (',', '}');
         l_pos := l_pos + 1;
      END LOOP;

      RETURN l_pos - 1;
   END json_Value_End;


   ---------------------------------------------------------------------------
   FUNCTION decode_Json_String (
      p_json       IN CLOB,
      p_start_pos  IN PLS_INTEGER,
      p_end_pos    IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
      l_json_value  CLOB;
      l_value       VARCHAR2(2000);
   BEGIN
      DBMS_LOB.CREATETEMPORARY(l_json_value, TRUE, DBMS_LOB.CALL);
      DBMS_LOB.WRITEAPPEND(l_json_value, 1, '[');
      DBMS_LOB.COPY(
         dest_lob     => l_json_value,
         src_lob      => p_json,
         amount       => p_end_pos - p_start_pos + 1,
         dest_offset  => 2,
         src_offset   => p_start_pos
      );
      DBMS_LOB.WRITEAPPEND(l_json_value, 1, ']');

      SELECT JSON_VALUE(
                l_json_value,
                '$[0]' RETURNING VARCHAR2(2000) ERROR ON ERROR
             )
        INTO l_value
        FROM DUAL;

      DBMS_LOB.FREETEMPORARY(l_json_value);
      RETURN l_value;

   EXCEPTION
      WHEN OTHERS THEN
         IF DBMS_LOB.ISTEMPORARY(l_json_value) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_json_value);
         END IF;

         response_Parse_Error(
            'JSON string parameter cannot be represented in 2000 characters'
         );
         RETURN NULL;
   END decode_Json_String;


   ---------------------------------------------------------------------------
   PROCEDURE parse_Json_Parameters (
      p_json        IN     CLOB,
      p_parameters  IN OUT NOCOPY MI_Utils.ParameterList_t
   )
   IS
      l_is_json       PLS_INTEGER;
      l_len           PLS_INTEGER;
      l_pos           PLS_INTEGER := 1;
      l_key_start     PLS_INTEGER;
      l_key_end       PLS_INTEGER;
      l_value_start   PLS_INTEGER;
      l_value_end     PLS_INTEGER;
      l_value_len     PLS_INTEGER;
      l_key           VARCHAR2(2000);
      l_value         VARCHAR2(2000);
      l_char          VARCHAR2(1);
   BEGIN
      IF p_json IS NULL THEN
         RETURN;
      END IF;

      SELECT CASE
                WHEN p_json IS JSON (STRICT) THEN 1
                ELSE 0
             END
        INTO l_is_json
        FROM DUAL;

      IF l_is_json = 0 THEN
         response_Parse_Error('parameters is not strict JSON');
      END IF;

      l_len := DBMS_LOB.getlength(p_json);
      json_Skip_Whitespace(p_json, l_pos, l_len);

      IF l_pos > l_len OR json_Char(p_json, l_pos) <> '{' THEN
         response_Parse_Error('parameters must be a JSON object');
      END IF;

      l_pos := l_pos + 1;
      json_Skip_Whitespace(p_json, l_pos, l_len);

      IF l_pos <= l_len AND json_Char(p_json, l_pos) = '}' THEN
         RETURN;
      END IF;

      LOOP
         IF l_pos > l_len OR json_Char(p_json, l_pos) <> '"' THEN
            response_Parse_Error('JSON parameter name expected');
         END IF;

         l_key_start := l_pos;
         l_key_end := json_String_End(p_json, l_key_start, l_len);

         l_key :=
            decode_Json_String(
               p_json      => p_json,
               p_start_pos => l_key_start,
               p_end_pos   => l_key_end
            );

         IF l_key IS NULL OR LENGTH(l_key) > 100 THEN
            response_Parse_Error('JSON parameter name must contain 1..100 characters');
         END IF;

         l_pos := l_key_end + 1;
         json_Skip_Whitespace(p_json, l_pos, l_len);

         IF l_pos > l_len OR json_Char(p_json, l_pos) <> ':' THEN
            response_Parse_Error('colon expected after JSON parameter name');
         END IF;

         l_pos := l_pos + 1;
         json_Skip_Whitespace(p_json, l_pos, l_len);

         IF l_pos > l_len THEN
            response_Parse_Error('JSON parameter value expected');
         END IF;

         l_value_start := l_pos;
         l_value_end := json_Value_End(p_json, l_value_start, l_len);
         l_value_len := l_value_end - l_value_start + 1;
         l_char := json_Char(p_json, l_value_start);

         IF l_char = '"' THEN
            l_value :=
               decode_Json_String(
                  p_json      => p_json,
                  p_start_pos => l_value_start,
                  p_end_pos   => l_value_end
               );
         ELSIF l_char IN ('{', '[') THEN
            IF l_value_len > 2000 THEN
               response_Parse_Error(
                  'JSON parameter object or array exceeds 2000 characters'
               );
            END IF;

            l_value := DBMS_LOB.SUBSTR(p_json, l_value_len, l_value_start);
         ELSE
            WHILE l_value_end >= l_value_start
              AND json_Char(p_json, l_value_end) IN
                     (' ', CHR(9), CHR(10), CHR(13))
            LOOP
               l_value_end := l_value_end - 1;
            END LOOP;

            l_value_len := l_value_end - l_value_start + 1;

            IF l_value_len > 2000 THEN
               response_Parse_Error(
                  'JSON scalar parameter exceeds 2000 characters'
               );
            END IF;

            l_value := DBMS_LOB.SUBSTR(p_json, l_value_len, l_value_start);

            IF LOWER(l_value) = 'null' THEN
               l_value := NULL;
            END IF;
         END IF;

         p_parameters(l_key) := l_value;

         l_pos := l_value_end + 1;
         json_Skip_Whitespace(p_json, l_pos, l_len);

         IF l_pos > l_len THEN
            response_Parse_Error('unterminated parameters object');
         END IF;

         l_char := json_Char(p_json, l_pos);

         IF l_char = '}' THEN
            EXIT;
         ELSIF l_char <> ',' THEN
            response_Parse_Error('comma expected between JSON parameters');
         END IF;

         l_pos := l_pos + 1;
         json_Skip_Whitespace(p_json, l_pos, l_len);
      END LOOP;

   END parse_Json_Parameters;


   ---------------------------------------------------------------------------
   FUNCTION result_From_Xml (
      p_xml              IN CLOB,
      p_expected_action  IN VARCHAR2
   )
      RETURN exec_Result_t
   IS
      l_doc               XMLTYPE;
      l_result            exec_Result_t;
      l_version           VARCHAR2(4000);
      l_action            VARCHAR2(4000);
      l_is_success_text   VARCHAR2(4000);
      l_result_code       VARCHAR2(4000);
      l_result_info       VARCHAR2(4000);
      l_result_details    CLOB;
      l_cause_code        VARCHAR2(4000);
      l_cause_info        VARCHAR2(4000);
      l_cause_details     CLOB;
      l_parameters_text   CLOB;
      l_boolean_text      VARCHAR2(4000);
   BEGIN
      IF p_xml IS NULL OR DBMS_LOB.getlength(p_xml) = 0 THEN
         response_Parse_Error('XML is empty');
      END IF;

      BEGIN
         l_doc := XMLTYPE.createXML(p_xml);
      EXCEPTION
         WHEN OTHERS THEN
            response_Parse_Error('malformed XML: ' || SQLERRM);
      END;

      BEGIN
         SELECT x.version_txt,
                x.action_txt,
                x.is_success_txt,
                x.result_code,
                x.result_info,
                x.result_details,
                x.cause_code,
                x.cause_info,
                x.cause_details,
                x.parameters_text
           INTO l_version,
                l_action,
                l_is_success_text,
                l_result_code,
                l_result_info,
                l_result_details,
                l_cause_code,
                l_cause_info,
                l_cause_details,
                l_parameters_text
           FROM XMLTABLE(
                   '/XXLResponse'
                   PASSING l_doc
                   COLUMNS
                      version_txt      VARCHAR2(4000) PATH 'string(@version)',
                      action_txt       VARCHAR2(4000) PATH 'string(@action)',
                      is_success_txt   VARCHAR2(4000) PATH 'string(@is_success)',
                      result_code      VARCHAR2(4000) PATH 'string(@result_code)',
                      result_info      VARCHAR2(4000) PATH 'string(@result_info)',
                      result_details   CLOB           PATH 'string(details)',
                      cause_code       VARCHAR2(4000) PATH 'string(@cause_code)',
                      cause_info       VARCHAR2(4000) PATH 'string(@cause_info)',
                      cause_details    CLOB           PATH 'string(cause_details)',
                      parameters_text  CLOB           PATH 'string(parameters)'
                ) x;

      EXCEPTION
         WHEN NO_DATA_FOUND THEN
            response_Parse_Error('root element XXLResponse not found');
      END;

      l_version := TRIM(l_version);
      l_action := TRIM(l_action);

      IF l_version IS NOT NULL AND l_version <> '1.0' THEN
         response_Parse_Error('unsupported XXLResponse version');
      END IF;

      l_boolean_text := LOWER(TRIM(l_is_success_text));

      IF l_boolean_text IN ('true', 't', '1', 'yes', 'y') THEN
         l_result.is_success := TRUE;
      ELSIF l_boolean_text IN ('false', 'f', '0', 'no', 'n') THEN
         l_result.is_success := FALSE;
      ELSE
         response_Parse_Error('required boolean is_success is invalid');
      END IF;

      IF l_result.is_success
         AND p_expected_action IS NOT NULL
      THEN
         IF l_action IS NULL THEN
            response_Parse_Error('action is required for successful response');
         ELSIF l_action <> TRIM(p_expected_action) THEN
            response_Parse_Error(
               'successful response action does not match request'
            );
         END IF;
      END IF;

      l_result_code := TRIM(l_result_code);

      IF l_result_code IS NULL THEN
         response_Parse_Error('required field result_code is empty');
      ELSIF LENGTH(l_result_code) > 100 THEN
         response_Parse_Error('result_code exceeds 100 characters');
      END IF;

      IF LENGTH(TRIM(l_result_info)) > 300 THEN
         response_Parse_Error('result_info exceeds 300 characters');
      END IF;

      IF LENGTH(TRIM(l_cause_code)) > 100 THEN
         response_Parse_Error('cause_code exceeds 100 characters');
      END IF;

      IF LENGTH(TRIM(l_cause_info)) > 2000 THEN
         response_Parse_Error('cause_info exceeds 2000 characters');
      END IF;

      l_result.result_code := l_result_code;
      l_result.result_info := TRIM(l_result_info);
      l_result.result_details := l_result_details;
      l_result.cause_code := TRIM(l_cause_code);
      l_result.cause_info := TRIM(l_cause_info);
      l_result.cause_details := l_cause_details;

      parse_Json_Parameters(
         p_json       => l_parameters_text,
         p_parameters => l_result.parameters
      );

      IF l_version IS NOT NULL THEN
         l_result.parameters('xml_version') := l_version;
      END IF;

      IF l_action IS NOT NULL THEN
         l_result.parameters('xml_action') := SUBSTR(l_action, 1, 2000);
      END IF;

      RETURN l_result;
   END result_From_Xml;


   ---------------------------------------------------------------------------
   FUNCTION oracle_Error_Code (
      p_sqlcode IN PLS_INTEGER
   )
      RETURN VARCHAR2
   IS
   BEGIN
      IF p_sqlcode = 1 THEN
         RETURN 'USER_DEFINED_EXCEPTION';
      ELSIF p_sqlcode = 100 THEN
         RETURN 'ORA-01403';
      ELSIF p_sqlcode < 0 THEN
         RETURN 'ORA-' || LPAD(TO_CHAR(ABS(p_sqlcode)), 5, '0');
      ELSIF p_sqlcode = 0 THEN
         RETURN NULL;
      ELSE
         RETURN 'ORA-' || TO_CHAR(p_sqlcode);
      END IF;
   END oracle_Error_Code;


   ---------------------------------------------------------------------------
   FUNCTION current_Error_Details
      RETURN CLOB
   IS
      l_stack      VARCHAR2(4000);
      l_backtrace  VARCHAR2(4000);
      l_details    CLOB;
   BEGIN
      l_stack     := DBMS_UTILITY.format_error_stack;
      l_backtrace := DBMS_UTILITY.format_error_backtrace;

      IF l_stack IS NOT NULL THEN
         l_details := l_stack;
      END IF;

      IF l_backtrace IS NOT NULL THEN
         IF l_details IS NOT NULL THEN
            l_details := l_details || CHR(10);
         END IF;

         l_details :=
            l_details
            || 'BACKTRACE:'
            || CHR(10)
            || l_backtrace;
      END IF;

      RETURN l_details;
   END current_Error_Details;


   ---------------------------------------------------------------------------
   FUNCTION wrapped_Cause_Details (
      p_result IN exec_Result_t
   )
      RETURN CLOB
   IS
      l_details CLOB;
   BEGIN
      l_details := p_result.result_details;

      IF p_result.cause_code IS NOT NULL
         OR p_result.cause_info IS NOT NULL
         OR p_result.cause_details IS NOT NULL
      THEN
         IF l_details IS NOT NULL THEN
            l_details := l_details || CHR(10);
         END IF;

         l_details := l_details || 'CAUSE:';

         IF p_result.cause_code IS NOT NULL THEN
            l_details :=
               l_details
               || ' '
               || p_result.cause_code;
         END IF;

         IF p_result.cause_info IS NOT NULL THEN
            l_details :=
               l_details
               || CHR(10)
               || p_result.cause_info;
         END IF;

         IF p_result.cause_details IS NOT NULL THEN
            l_details :=
               l_details
               || CHR(10)
               || p_result.cause_details;
         END IF;
      END IF;

      RETURN l_details;
   END wrapped_Cause_Details;


   ---------------------------------------------------------------------------
   PROCEDURE raise_Error (
      p_result IN exec_Result_t
   )
   IS
      l_result  exec_Result_t;
      l_message VARCHAR2(2000);
   BEGIN
      /*
         raise_Error(success) является no-op.
      */
      IF is_Success(p_result) THEN
         RETURN;
      END IF;


      l_result := p_result;

      l_result.is_success := FALSE;

      IF l_result.result_code IS NULL THEN
         l_result.result_code := cResult_Error;
      ELSE
         l_result.result_code :=
            SUBSTR(
               l_result.result_code,
               1,
               100
            );
      END IF;

      l_result.result_info :=
         SUBSTR(
            l_result.result_info,
            1,
            300
         );

      l_result.cause_code :=
         SUBSTR(
            l_result.cause_code,
            1,
            100
         );

      l_result.cause_info :=
         SUBSTR(
            l_result.cause_info,
            1,
            2000
         );


      set_Current(l_result);


      l_message := l_result.result_code;

      IF l_result.result_info IS NOT NULL THEN
         l_message :=
            l_message
            || ': '
            || l_result.result_info;
      END IF;


      RAISE_APPLICATION_ERROR(
         cResult_Failed_Code,
         SUBSTR(l_message, 1, 2000)
      );

   END raise_Error;


   ---------------------------------------------------------------------------
   PROCEDURE raise_Error (
      p_code          IN VARCHAR2,
      p_info          IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details       IN CLOB     DEFAULT NULL,

      p_cause_code    IN VARCHAR2 DEFAULT NULL,
      p_cause_info    IN VARCHAR2 DEFAULT NULL,
      p_cause_details IN CLOB     DEFAULT NULL
   )
   IS
      l_result exec_Result_t;
   BEGIN
      l_result :=
         failure(
            p_code          => p_code,
            p_info          => p_info,
            p_details       => p_details,
            p_cause_code    => p_cause_code,
            p_cause_info    => p_cause_info,
            p_cause_details => p_cause_details
         );

      raise_Error(l_result);
   END raise_Error;


   ---------------------------------------------------------------------------
   FUNCTION from_Exception (
      p_sqlcode IN PLS_INTEGER,
      p_sqlerrm IN VARCHAR2,

      p_code    IN VARCHAR2 DEFAULT NULL,
      p_info    IN VARCHAR2 DEFAULT NULL,
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      /*
         Наш transport exception: возвращаем исходный structured result.
      */
      IF p_sqlcode = cResult_Failed_Code
         AND g_has_current
      THEN
         RETURN g_exec_result;
      END IF;


      l_result :=
         failure(
            p_code          => NVL(p_code, 'UNEXPECTED_ERROR'),
            p_info          => NVL(p_info, 'Внутренняя ошибка системы'),
            p_details       => p_details,

            p_cause_code    => oracle_Error_Code(p_sqlcode),
            p_cause_info    => p_sqlerrm,
            p_cause_details => current_Error_Details
         );


      l_result.parameters('sqlcode') := TO_CHAR(p_sqlcode);

      RETURN l_result;
   END from_Exception;


   ---------------------------------------------------------------------------
   FUNCTION wrap_Exception (
      p_cause   IN exec_Result_t,

      p_code    IN VARCHAR2,
      p_info    IN VARCHAR2 DEFAULT 'Операция завершилась ошибкой',
      p_details IN CLOB     DEFAULT NULL
   )
      RETURN exec_Result_t
   IS
      l_result exec_Result_t;
   BEGIN
      l_result :=
         failure(
            p_code          => p_code,
            p_info          => p_info,
            p_details       => p_details,

            p_cause_code    => p_cause.result_code,
            p_cause_info    => p_cause.result_info,
            p_cause_details => wrapped_Cause_Details(p_cause)
         );


      /*
         Технический контекст исходной ошибки не теряем.
      */
      l_result.parameters := p_cause.parameters;


      RETURN l_result;
   END wrap_Exception;

END MI_ResultCtx;
/
