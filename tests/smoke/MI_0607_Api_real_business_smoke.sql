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
--
-- This test NEVER COMMITs. It rolls back the package-created MI/RSD rows.
-- If called business code commits or performs autonomous work, rollback cannot
-- guarantee isolation. Do not run against production.
--
-- The existing MI_0607_Api_smoke.sql covers replay and negative journal fixtures;
-- this test exercises a REAL CreateBase -> Parsing happy path.

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

ACCEPT MI607_DIRECTORY CHAR PROMPT 'Oracle DIRECTORY name containing test JSON: '
ACCEPT MI607_FILE CHAR PROMPT 'Test JSON filename (on DB server): '
ACCEPT MI607_DOCTYPE CHAR PROMPT 'Expected docType (UNO or UPO): '

DECLARE
   l_bfile         BFILE;
   l_body          BLOB;
   l_size          INTEGER;
   l_doc_type      RSD_BASES.FILE_TYPE%TYPE;
   l_file_name     RSD_BASES.FILE_NAME%TYPE;
   l_message_uuid  MI_REQ.MESSAGE_UUID%TYPE := MI_Utils.uuid_V7;
   l_task_id       RSD_BASES.TASKID%TYPE := MI_Utils.uuid_V7;
   l_doc_date      RSD_BASES.DOCDATE%TYPE := SYSDATE;

   l_req_id        MI_REQ.REQ_ID%TYPE;
   l_itm_id        MI_0600.ITM_ID%TYPE;
   l_base_id       RSD_BASES.ID%TYPE;
   l_file_type     RSD_BASES.FILE_TYPE%TYPE;
   l_outfile_id    RSD_OUTFILES.ID%TYPE;
   l_ret_code      NUMBER;
   l_ret_info      VARCHAR2(4000);

   l_count         PLS_INTEGER;
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

   l_bfile := BFILENAME('&&MI607_DIRECTORY', '&&MI607_FILE');
   DBMS_LOB.fileopen(l_bfile, DBMS_LOB.file_readonly);
   l_size := DBMS_LOB.getlength(l_bfile);
   assert_true(l_size > 0, 'input file is empty');

   DBMS_LOB.createtemporary(l_body, TRUE);
   DBMS_LOB.loadfromfile(l_body, l_bfile, l_size);
   DBMS_LOB.fileclose(l_bfile);

   MI_0607_Api.process_Document_Received(
      p_original_req_uuid => NULL,
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
      p_parse_result      => l_outfile_id,
      p_ret_code          => l_ret_code,
      p_ret_info          => l_ret_info
   );

   DBMS_OUTPUT.put_line('ret_code=' || l_ret_code || '; ret_info=' || l_ret_info);
   DBMS_OUTPUT.put_line('req_id=' || l_req_id || '; itm_id=' || l_itm_id
      || '; base_id=' || l_base_id || '; outfile_id=' || l_outfile_id);

   assert_true(l_ret_code = MI_0607_Api.RET_OK,
               'expected RET_OK, got ' || NVL(TO_CHAR(l_ret_code), '<NULL>')
               || ': ' || l_ret_info);
   assert_true(l_req_id IS NOT NULL AND l_itm_id IS NOT NULL,
               'MI journal IDs are missing');
   assert_true(l_base_id IS NOT NULL AND l_outfile_id IS NOT NULL,
               'CreateBase / Parsing IDs are missing');
   assert_true(UPPER(TRIM(l_file_type)) = l_doc_type,
               'detected fileType differs from supplied docType');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ
    WHERE REQ_ID = l_req_id
      AND INF_ID = 607
      AND STATUS_CD = MI_Request_Api.STATUS_DONE
      AND LOWER(TRIM(MESSAGE_UUID)) = LOWER(l_message_uuid);
   assert_true(l_count = 1, 'MI_REQ is not the expected DONE request');

   SELECT BZIP_DATA
     INTO l_journal_body
     FROM MI_0600
    WHERE ITM_ID = l_itm_id
      AND REQ_ID = l_req_id
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
     FROM RSD_BASES
    WHERE ID = l_base_id
      AND TASKID = l_task_id
      AND FILE_TYPE = l_file_type;
   assert_true(l_count = 1, 'RSD_BASES metadata missing');

   SELECT COUNT(*)
     INTO l_count
     FROM RSD_OUTFILES
    WHERE ID = l_outfile_id;
   assert_true(l_count = 1, 'Parsing returned a nonexistent RSD_OUTFILES.ID');

   ROLLBACK TO mi_0607_real_smoke;

   -- Verify rollback actually removes the newly created rows.
   SELECT COUNT(*) INTO l_count FROM MI_REQ WHERE REQ_ID = l_req_id;
   assert_true(l_count = 0, 'MI_REQ survived test rollback');

   SELECT COUNT(*) INTO l_count FROM RSD_BASES WHERE ID = l_base_id;
   assert_true(l_count = 0, 'RSD_BASES survived test rollback');

   SELECT COUNT(*) INTO l_count FROM RSD_OUTFILES WHERE ID = l_outfile_id;
   assert_true(l_count = 0, 'RSD_OUTFILES survived test rollback');

   IF DBMS_LOB.istemporary(l_body) = 1 THEN
      DBMS_LOB.freetemporary(l_body);
   END IF;

   DBMS_OUTPUT.put_line('MI_0607 REAL BUSINESS SMOKE PASSED (all changes rolled back)');

EXCEPTION
   WHEN OTHERS THEN
      IF DBMS_LOB.fileisopen(l_bfile) = 1 THEN
         DBMS_LOB.fileclose(l_bfile);
      END IF;

      BEGIN
         ROLLBACK TO mi_0607_real_smoke;
      EXCEPTION
         WHEN OTHERS THEN
            DBMS_OUTPUT.put_line('WARNING: ROLLBACK TO SAVEPOINT FAILED: ' || SQLERRM);
      END;

      IF DBMS_LOB.istemporary(l_body) = 1 THEN
         DBMS_LOB.freetemporary(l_body);
      END IF;

      RAISE;
END;
/
