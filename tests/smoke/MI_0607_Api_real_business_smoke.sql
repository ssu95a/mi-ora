-- Real business integration smoke for MI_0607_Api / RD_PKG.
-- Oracle 12.1; SQL*Plus-compatible.
--
-- Preconditions:
--   1. Execute in an ISOLATED test session / test schema (no pending user DML).
--   2. RD_PKG.CreateBase and RD_PKG.Parsing must be installed and executable.
--   3. Provide a real, schema-valid DOCUMENT_RECEIVED file (UNO or UPO).
--   4. Oracle DIRECTORY must point to the file location accessible to the DB SERVER;
--      the executing schema needs READ on that directory.
--   5. No external/nontransactional side effects should be caused by the test;
--      verify RD_PKG contract before using against shared environments.
--   6. For each PB2 case, use a fixture whose successful Parsing generates
--      the expected number of PB2 rows (0, 1 or several) for its new base.
--
-- This test NEVER COMMITs. It rolls back the package-created MI/RSD rows.
-- If called business code commits or performs autonomous work, rollback cannot
-- guarantee isolation. Do not run against production.
--
-- The existing MI_0607_Api_smoke.sql covers duplicate rejection and validation;
-- this test exercises:
--   1. a REAL CreateBase -> Parsing happy path;
--   2. a deterministic DOC_TYPE_MISMATCH business failure using the same
--      valid payload with the opposite declared docType.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

ACCEPT MI607_DIRECTORY CHAR PROMPT 'Oracle DIRECTORY name containing test JSON: '
ACCEPT MI607_FILE CHAR PROMPT 'Test JSON filename (on DB server): '
ACCEPT MI607_DOCTYPE CHAR PROMPT 'Expected docType (UNO or UPO): '
ACCEPT MI607_PB2_COUNT NUMBER DEFAULT 1 PROMPT 'Expected PB2 row count [1]: '

DECLARE
   l_bfile         BFILE;
   l_body          BLOB;
   l_size          INTEGER;
   l_doc_type       RSD_BASES.FILE_TYPE%TYPE;
   l_wrong_doc_type RSD_BASES.FILE_TYPE%TYPE;
   l_file_name      RSD_BASES.FILE_NAME%TYPE;
   l_journal_name   MI_0600.CZIP_NAME%TYPE;
   l_original_req_uuid MI_REQ.ORIGINAL_REQ_UUID%TYPE := MI_Utils.uuid_V7;
   l_message_uuid   MI_REQ.MESSAGE_UUID%TYPE := MI_Utils.uuid_V7;
   l_task_id        RSD_BASES.TASKID%TYPE := MI_Utils.uuid_V7;
   l_doc_date       RSD_BASES.DOCDATE%TYPE := SYSDATE;

   l_req_id        MI_REQ.REQ_ID%TYPE;
   l_itm_id        MI_0600.ITM_ID%TYPE;
   l_base_id       RSD_BASES.ID%TYPE;
   l_file_type     RSD_BASES.FILE_TYPE%TYPE;
   l_parse_result  NUMBER;
   l_outfile_id    RSD_OUTFILES.ID%TYPE;
   l_expected_pb2  NUMBER := &&MI607_PB2_COUNT;
   l_expected_id   RSD_OUTFILES.ID%TYPE;
   l_ret_code      NUMBER;
   l_ret_info      VARCHAR2(4000);

   l_count         PLS_INTEGER;
   l_base_count    PLS_INTEGER;
   l_journal_body  BLOB;

   PROCEDURE fail(p_message IN VARCHAR2) IS
   BEGIN
      RAISE_APPLICATION_ERROR(-20990, 'MI_0607 real business smoke: ' || p_message);
   END;

   PROCEDURE assert_true(p_ok IN BOOLEAN, p_message IN VARCHAR2) IS
   BEGIN
      IF p_ok IS NULL OR NOT p_ok THEN
         fail(p_message);
      END IF;
   END;

BEGIN
   -- No DML before this savepoint. Do not allow business code to COMMIT.
   SAVEPOINT mi_0607_real_smoke;

   l_doc_type := UPPER(TRIM('&&MI607_DOCTYPE'));
   l_file_name := '&&MI607_FILE';

   assert_true(l_doc_type IN ('UNO', 'UPO'), 'docType must be UNO or UPO');
   assert_true(l_file_name IS NOT NULL, 'file name must not be empty');
   assert_true(l_expected_pb2 >= 0 AND l_expected_pb2 = TRUNC(l_expected_pb2),
               'expected PB2 count must be a nonnegative integer');

   l_wrong_doc_type := CASE l_doc_type WHEN 'UNO' THEN 'UPO' ELSE 'UNO' END;

   l_bfile := BFILENAME('&&MI607_DIRECTORY', '&&MI607_FILE');
   assert_true(DBMS_LOB.fileexists(l_bfile) = 1,
               'input BFILE does not exist or is not accessible');
   DBMS_LOB.fileopen(l_bfile, DBMS_LOB.file_readonly);
   l_size := DBMS_LOB.getlength(l_bfile);
   assert_true(l_size > 0, 'input file is empty');

   DBMS_LOB.createtemporary(l_body, TRUE);
   DBMS_LOB.loadfromfile(l_body, l_bfile, l_size);
   DBMS_LOB.fileclose(l_bfile);

   MI_0607_Api.process_Document_Received(
      p_original_req_uuid => l_original_req_uuid,
      p_message_uuid      => l_message_uuid,
      p_correlation_id    => NULL,
      p_task_id           => l_task_id,
      p_doc_type          => l_doc_type,
      p_doc_date          => l_doc_date,
      p_file_name         => l_file_name,
      p_file_body         => l_body,
      p_req_id            => l_req_id,
      p_itm_id            => l_itm_id,
      p_base_id           => l_base_id,
      p_file_type         => l_file_type,
      p_parse_result      => l_parse_result,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info,
      p_inf_id            => 607,
      p_outfile_id        => l_outfile_id
   );

   DBMS_OUTPUT.put_line('ret_code=' || l_ret_code || '; ret_info=' || l_ret_info);
   DBMS_OUTPUT.put_line('req_id=' || l_req_id || '; itm_id=' || l_itm_id
      || '; base_id=' || l_base_id || '; parse_result=' || l_parse_result
      || '; outfile_id=' || l_outfile_id);

   assert_true(l_ret_code = MI_0607_Api.RET_OK,
               'expected RET_OK, got ' || NVL(TO_CHAR(l_ret_code), '<NULL>')
               || ': ' || l_ret_info);
   assert_true(l_req_id IS NOT NULL AND l_itm_id IS NOT NULL,
               'MI journal IDs are missing');
   assert_true(l_base_id IS NOT NULL AND l_parse_result IS NOT NULL,
               'CreateBase ID or Parsing result is missing');
   assert_true(UPPER(TRIM(l_file_type)) = l_doc_type,
               'detected fileType differs from supplied docType');

   l_journal_name := 'MI_0607_' || LOWER(TRIM(l_original_req_uuid));

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE REQ_ID = l_req_id
      AND INF_ID = 607
      AND STATUS_CD = MI_Request_Api.STATUS_DONE
      AND LOWER(TRIM(ORIGINAL_REQ_UUID)) = LOWER(l_original_req_uuid)
      AND LOWER(TRIM(MESSAGE_UUID)) = LOWER(l_message_uuid)
      AND LOWER(TRIM(CTAXREQ_ID)) = LOWER(l_task_id);
   assert_true(l_count = 1, 'MI_REQ is not the expected DONE request');

   SELECT BZIP_DATA
     INTO l_journal_body
     FROM MI_0600
    WHERE ITM_ID = l_itm_id
      AND REQ_ID = l_req_id
      AND CZIP_NAME = l_journal_name
      AND LOWER(TRIM(MESSAGE_UUID)) = LOWER(l_message_uuid)
      AND IRES_CODE = MI_Item_Result_Api.RESPONSE_OK
      AND ERROR_CODE IS NULL
      AND TRES_TIME IS NOT NULL
      AND IZIP_SIZE = l_size
      AND IZIP_FILES_COUNT = 1;

   assert_true(DBMS_LOB.compare(l_journal_body, l_body) = 0,
               'stored MI_0600 payload differs from source bytes');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id
      AND CZIP_FILE_NAME = l_file_name;
   assert_true(l_count = 1, 'MI_0600_F filename missing');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 1, 'MI_0600_F contains unexpected filenames');

   SELECT COUNT(*)
     INTO l_count
     FROM RSD_BASES
    WHERE ID = l_base_id
      AND TASKID = l_task_id
      AND FILE_TYPE = l_file_type
      AND FILE_NAME = l_file_name
      AND DOCDATE = l_doc_date;
   assert_true(l_count = 1, 'RSD_BASES metadata missing');

   SELECT COUNT(*), MIN(ID)
     INTO l_count, l_expected_id
     FROM RSD_OUTFILES
    WHERE PID = l_base_id
      AND FILE_TYPE = 'PB2';
   assert_true(l_count = l_expected_pb2,
               'fixture PB2 row count=' || l_count || ', expected=' || l_expected_pb2);
   IF l_count = 1 THEN
      assert_true(l_parse_result = 1, 'expected Parsing result 1 for the single-PB2 fixture');
      assert_true(l_outfile_id = l_expected_id, 'expected actual PB2 row ID in p_outfile_id');
   ELSE
      assert_true(l_outfile_id IS NULL, 'expected NULL p_outfile_id without a unique PB2');
   END IF;

   ROLLBACK TO mi_0607_real_smoke;

   -- Verify rollback actually removes the newly created rows.
   SELECT COUNT(*) INTO l_count FROM MI_REQ WHERE REQ_ID = l_req_id;
   assert_true(l_count = 0, 'MI_REQ survived test rollback');

   SELECT COUNT(*) INTO l_count FROM MI_0600 WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 0, 'MI_0600 survived test rollback');

   SELECT COUNT(*) INTO l_count FROM MI_0600_F WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 0, 'MI_0600_F survived test rollback');

   SELECT COUNT(*) INTO l_count FROM RSD_BASES WHERE ID = l_base_id;
   assert_true(l_count = 0, 'RSD_BASES survived test rollback');

   SELECT COUNT(*) INTO l_count FROM RSD_OUTFILES WHERE PID = l_base_id;
   assert_true(l_count = 0, 'RSD_OUTFILES survived test rollback');

   DBMS_OUTPUT.put_line('1. REAL happy path passed and was rolled back');

   ---------------------------------------------------------------------------
   -- A valid payload with the opposite declared type must be a BUSINESS
   -- failure. CreateBase work is rolled back, while the MI journal remains
   -- available to the caller until the caller rolls back or commits.
   ---------------------------------------------------------------------------
   l_original_req_uuid := MI_Utils.uuid_V7;
   l_message_uuid := MI_Utils.uuid_V7;
   l_task_id := MI_Utils.uuid_V7;
   l_req_id := NULL;
   l_itm_id := NULL;
   l_base_id := NULL;
   l_file_type := NULL;
   l_parse_result := NULL;
   l_outfile_id := -1;
   l_ret_code := NULL;
   l_ret_info := NULL;
   l_journal_name := 'MI_0607_' || LOWER(TRIM(l_original_req_uuid));

   SELECT COUNT(*)
     INTO l_base_count
     FROM RSD_BASES
    WHERE FILE_NAME = l_file_name;

   MI_0607_Api.process_Document_Received(
      p_original_req_uuid => l_original_req_uuid,
      p_message_uuid      => l_message_uuid,
      p_correlation_id    => NULL,
      p_task_id           => l_task_id,
      p_doc_type          => l_wrong_doc_type,
      p_doc_date          => l_doc_date,
      p_file_name         => l_file_name,
      p_file_body         => l_body,
      p_req_id            => l_req_id,
      p_itm_id            => l_itm_id,
      p_base_id           => l_base_id,
      p_file_type         => l_file_type,
      p_parse_result      => l_parse_result,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info,
      p_inf_id            => 607,
      p_outfile_id        => l_outfile_id
   );

   assert_true(l_ret_code = MI_0607_Api.RET_DOC_TYPE_MISMATCH,
               'expected RET_DOC_TYPE_MISMATCH, got '
               || NVL(TO_CHAR(l_ret_code), '<NULL>') || ': ' || l_ret_info);
   assert_true(l_req_id IS NOT NULL AND l_itm_id IS NOT NULL,
               'business failure did not preserve MI journal IDs');
   assert_true(l_base_id IS NULL AND l_parse_result IS NULL AND l_outfile_id IS NULL,
               'business failure exposed rolled-back RSD IDs');
   assert_true(UPPER(TRIM(l_file_type)) = l_doc_type,
               'CreateBase did not detect the real payload type');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE REQ_ID = l_req_id
      AND INF_ID = 607
      AND STATUS_CD = MI_Request_Api.STATUS_DONE
      AND LOWER(TRIM(ORIGINAL_REQ_UUID)) = LOWER(l_original_req_uuid)
      AND LOWER(TRIM(MESSAGE_UUID)) = LOWER(l_message_uuid)
      AND LOWER(TRIM(CTAXREQ_ID)) = LOWER(l_task_id);
   assert_true(l_count = 1,
               'DOC_TYPE_MISMATCH did not preserve the DONE MI_REQ');

   SELECT BZIP_DATA
     INTO l_journal_body
     FROM MI_0600
    WHERE ITM_ID = l_itm_id
      AND REQ_ID = l_req_id
      AND CZIP_NAME = l_journal_name
      AND LOWER(TRIM(MESSAGE_UUID)) = LOWER(l_message_uuid)
      AND IRES_CODE = MI_Item_Result_Api.RESPONSE_FAIL
      AND ERROR_CODE = 'DOC_TYPE_MISMATCH'
      AND CRES_INFO IS NOT NULL
      AND TRES_TIME IS NOT NULL
      AND IZIP_SIZE = l_size
      AND IZIP_FILES_COUNT = 1;

   assert_true(DBMS_LOB.compare(l_journal_body, l_body) = 0,
               'business-failure journal payload differs from source bytes');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id
      AND CZIP_FILE_NAME = l_file_name;
   assert_true(l_count = 1,
               'business-failure journal did not preserve the filename');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_0600_F
    WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 1,
               'business-failure journal contains unexpected filenames');

   SELECT COUNT(*)
     INTO l_count
     FROM RSD_BASES
    WHERE FILE_NAME = l_file_name;
   assert_true(l_count = l_base_count,
               'DOC_TYPE_MISMATCH left an RSD_BASES row behind');

   ROLLBACK TO mi_0607_real_smoke;

   SELECT COUNT(*) INTO l_count FROM MI_REQ WHERE REQ_ID = l_req_id;
   assert_true(l_count = 0, 'failed MI_REQ survived final test rollback');

   SELECT COUNT(*) INTO l_count FROM MI_0600 WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 0, 'failed MI_0600 survived final test rollback');

   SELECT COUNT(*) INTO l_count FROM MI_0600_F WHERE ITM_ID = l_itm_id;
   assert_true(l_count = 0, 'failed MI_0600_F survived final test rollback');

   DBMS_OUTPUT.put_line(
      '2. REAL DOC_TYPE_MISMATCH passed; RSD rolled back, MI journal preserved'
   );

   IF DBMS_LOB.istemporary(l_body) = 1 THEN
      DBMS_LOB.freetemporary(l_body);
   END IF;

   DBMS_OUTPUT.put_line('MI_0607 REAL BUSINESS SMOKE PASSED (all changes rolled back)');

EXCEPTION
   WHEN OTHERS THEN
      -- Cleanup must not mask the original business/Oracle exception.
      BEGIN
         IF l_bfile IS NOT NULL AND DBMS_LOB.fileisopen(l_bfile) = 1 THEN
            DBMS_LOB.fileclose(l_bfile);
         END IF;
      EXCEPTION
         WHEN OTHERS THEN
            DBMS_OUTPUT.put_line('WARNING: BFILE cleanup failed: ' || SQLERRM);
      END;

      BEGIN
         ROLLBACK TO mi_0607_real_smoke;
      EXCEPTION
         WHEN OTHERS THEN
            DBMS_OUTPUT.put_line('WARNING: ROLLBACK TO SAVEPOINT FAILED: ' || SQLERRM);
      END;

      BEGIN
         IF l_body IS NOT NULL AND DBMS_LOB.istemporary(l_body) = 1 THEN
            DBMS_LOB.freetemporary(l_body);
         END IF;
      EXCEPTION
         WHEN OTHERS THEN
            DBMS_OUTPUT.put_line('WARNING: temporary BLOB cleanup failed: ' || SQLERRM);
      END;

      RAISE;
END;
/
