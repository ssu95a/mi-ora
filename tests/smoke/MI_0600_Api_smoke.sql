SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0600_Api smoke test
PROMPT ============================================================

DECLARE
   l_result          MI_ResultCtx.exec_Result_t;
   l_transition      MI_ResultCtx.exec_Result_t;

   l_req_id          MI_REQ.REQ_ID%TYPE;
   l_itm_id          MI_0600.ITM_ID%TYPE;
   l_request_uuid    MI_REQ.EXTERNAL_UUID%TYPE;
   l_item_uuid       MI_0600.EXTERNAL_UUID%TYPE;
   l_message_uuid    MI_REQ.MESSAGE_UUID%TYPE;

   l_zip_name        MI_0600.CZIP_NAME%TYPE;
   l_status_cd       MI_REQ.STATUS_CD%TYPE;
   l_ires_code       MI_0600.IRES_CODE%TYPE;
   l_cres_info       VARCHAR2(2000);
   l_error_code      MI_0600.ERROR_CODE%TYPE;
   l_applied_message MI_0600.MESSAGE_UUID%TYPE;
   l_dsend_stamp     MI_0600.DSEND_STAMP%TYPE;

   l_count           PLS_INTEGER;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0600_Api smoke test failed: ' || p_message
      );
   END fail;


   ---------------------------------------------------------------------------
   PROCEDURE assert_True (
      p_condition IN BOOLEAN,
      p_message   IN VARCHAR2
   )
   IS
   BEGIN
      IF p_condition IS NULL OR NOT p_condition THEN
         fail(p_message);
      END IF;
   END assert_True;


   ---------------------------------------------------------------------------
   PROCEDURE assert_Success (
      p_result   IN MI_ResultCtx.exec_Result_t,
      p_message  IN VARCHAR2
   )
   IS
   BEGIN
      IF MI_ResultCtx.is_Failed(p_result) THEN
         fail(
            p_message
            || ' [result_code='
            || NVL(p_result.result_code, '<NULL>')
            || ', result_info='
            || NVL(p_result.result_info, '<NULL>')
            || ', cause_code='
            || NVL(p_result.cause_code, '<NULL>')
            || ', cause_info='
            || NVL(p_result.cause_info, '<NULL>')
            || ']'
         );
      END IF;
   END assert_Success;


   ---------------------------------------------------------------------------
   FUNCTION number_Parameter (
      p_result  IN MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN NUMBER
   IS
   BEGIN
      RETURN TO_NUMBER(p_result.parameters(p_name));

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('result does not contain parameter ' || p_name);
         RETURN NULL;
   END number_Parameter;


   ---------------------------------------------------------------------------
   FUNCTION text_Parameter (
      p_result  IN MI_ResultCtx.exec_Result_t,
      p_name    IN VARCHAR2
   )
      RETURN VARCHAR2
   IS
   BEGIN
      RETURN p_result.parameters(p_name);

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('result does not contain parameter ' || p_name);
         RETURN NULL;
   END text_Parameter;


BEGIN
   SAVEPOINT before_mi_0600_smoke;

   BEGIN
      SELECT 1
        INTO l_count
        FROM MI_INF
       WHERE INF_ID = 601;

   EXCEPTION
      WHEN NO_DATA_FOUND THEN
         fail('MI_INF does not contain required INF_ID=601');
   END;

   l_zip_name :=
         'SMOKE_'
      || REPLACE(MI_Utils.uuid_V7, '-', '')
      || '.zip';


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. create request, item and unique file list');

   l_result :=
      MI_0600_Api.create_Request(
         p_inf_id            => 601,
         p_czip_name         => l_zip_name,
         p_bzip_data         => NULL,
         p_izip_size         => 10,
         p_izip_files_count  => 2,
         p_file_names        =>
            SYS.ODCIVARCHAR2LIST(
               'first.xml',
               'second.xml',
               'first.xml'
            ),
         p_icreate_type      => 1
      );

   assert_Success(l_result, 'create_Request failed');

   assert_True(
      l_result.result_code = 'MI_0600_REQUEST_CREATED',
      'unexpected create result_code=' || l_result.result_code
   );

   l_req_id       := number_Parameter(l_result, 'req_id');
   l_itm_id       := number_Parameter(l_result, 'itm_id');
   l_request_uuid := text_Parameter(l_result, 'request_uuid');
   l_item_uuid    := text_Parameter(l_result, 'item_uuid');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id;

   assert_True(l_count = 2, 'duplicate file name was not ignored');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. reuse duplicate initiator archive');

   l_result :=
      MI_0600_Api.create_Request(
         p_inf_id            => 601,
         p_czip_name         => l_zip_name,
         p_bzip_data         => NULL,
         p_izip_size         => 20,
         p_izip_files_count  => 1,
         p_file_names        => SYS.ODCIVARCHAR2LIST('renamed.xml'),
         p_icreate_type      => 1
      );

   assert_Success(l_result, 'duplicate create_Request failed');

   assert_True(
      l_result.result_code = 'MI_0600_REQUEST_REUSED',
      'duplicate archive was not reused'
   );

   assert_True(
      number_Parameter(l_result, 'req_id') = l_req_id
      AND number_Parameter(l_result, 'itm_id') = l_itm_id,
      'duplicate archive returned different IDs'
   );

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id
      AND CZIP_FILE_NAME = 'renamed.xml';

   assert_True(l_count = 1, 'duplicate archive file list was not replaced');

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('3. BUSY -> SENT stamps MI_0600');

   l_transition := MI_Request_Api.take_For_Proc(l_req_id);
   assert_Success(l_transition, 'take_For_Proc failed');

   l_transition := MI_Request_Api.to_Sent(l_req_id);
   assert_Success(l_transition, 'to_Sent failed');

   SELECT DSEND_STAMP
     INTO l_dsend_stamp
     FROM MI_0600
    WHERE ITM_ID = l_itm_id;

   assert_True(l_dsend_stamp IS NOT NULL, 'DSEND_STAMP was not set');

   assert_True(
      MI_0600_Api.get_Fns_File_Inqueue_Date('  ReNaMeD.xMl  ')
         = TRUNC(CAST(l_dsend_stamp AS DATE)),
      'file queue date lookup failed'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('4. apply successful item result');

   l_message_uuid := MI_Utils.uuid_V7;

   l_result :=
      MI_0600_Api.apply_Item_Result(
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_OK,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB(
            '{"state":7,"message":"accepted"}'
         )
      );

   assert_Success(l_result, 'apply_Item_Result failed');

   SELECT IRES_CODE,
          DBMS_LOB.SUBSTR(CRES_INFO, 2000, 1),
          ERROR_CODE,
          MESSAGE_UUID
     INTO l_ires_code,
          l_cres_info,
          l_error_code,
          l_applied_message
     FROM MI_0600
    WHERE ITM_ID = l_itm_id;

   SELECT STATUS_CD
     INTO l_status_cd
     FROM MI_REQ
    WHERE REQ_ID = l_req_id;

   assert_True(l_ires_code = 7, 'unexpected IRES_CODE');
   assert_True(l_cres_info = 'accepted', 'unexpected CRES_INFO');
   assert_True(l_error_code IS NULL, 'ERROR_CODE must be NULL');
   assert_True(
      TRIM(l_applied_message) = TRIM(l_message_uuid),
      'MESSAGE_UUID was not stored'
   );
   assert_True(
      l_status_cd = MI_Request_Api.STATUS_DONE,
      'request was not completed'
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('5. replay is idempotent');

   l_result :=
      MI_0600_Api.apply_Item_Result(
         p_request_uuid      => l_request_uuid,
         p_message_uuid      => l_message_uuid,
         p_item_uuid         => l_item_uuid,
         p_response_kind     => MI_Item_Result_Api.RESPONSE_OK,
         p_response_code     => NULL,
         p_response_info     => NULL,
         p_response_details  => NULL,
         p_response_time     => SYSTIMESTAMP,
         p_payload_text      => TO_CLOB(
            '{"state":7,"message":"accepted"}'
         )
      );

   assert_Success(l_result, 'idempotent replay failed');

   assert_True(
      l_result.result_code = 'ITEM_RESULT_ALREADY_APPLIED',
      'replay was not recognized as already applied'
   );

   DBMS_OUTPUT.put_line('   OK');


   ROLLBACK TO before_mi_0600_smoke;

   DBMS_OUTPUT.put_line('MI_0600_Api smoke test passed');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_mi_0600_smoke;
      RAISE;
END;
/
