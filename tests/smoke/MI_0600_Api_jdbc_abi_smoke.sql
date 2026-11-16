SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET VERIFY OFF

PROMPT ============================================================
PROMPT MI_0600_Api JDBC ABI smoke test
PROMPT ============================================================

DECLARE
   c_expected_abi CONSTANT VARCHAR2(4000) :=
         'P_INF_ID:IN,'
      || 'P_CZIP_NAME:IN,'
      || 'P_BZIP_DATA:IN,'
      || 'P_IZIP_SIZE:IN,'
      || 'P_IZIP_FILES_COUNT:IN,'
      || 'P_FILE_NAMES:IN,'
      || 'P_REQ_ID:OUT,'
      || 'P_ITM_ID:OUT,'
      || 'P_RET_CODE:OUT,'
      || 'P_RET_INFO:OUT,'
      || 'P_ORIGINAL_REQ_UUID:IN,'
      || 'P_MESSAGE_UUID:IN,'
      || 'P_CTAXREQ_ID:IN,'
      || 'P_ICREATE_TYPE:IN';

   l_actual_abi  VARCHAR2(4000);
   l_zip_name    MI_0600.CZIP_NAME%TYPE;
   l_zip_blob    BLOB;
   l_req_id      MI_REQ.REQ_ID%TYPE;
   l_itm_id      MI_0600.ITM_ID%TYPE;
   l_ret_code    NUMBER;
   l_ret_info    VARCHAR2(4000);
   l_count       PLS_INTEGER;


   ---------------------------------------------------------------------------
   PROCEDURE fail (
      p_message IN VARCHAR2
   )
   IS
   BEGIN
      RAISE_APPLICATION_ERROR(
         -20990,
         'MI_0600_Api JDBC ABI smoke test failed: ' || p_message
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


BEGIN
   SAVEPOINT before_mi_0600_abi_smoke;

   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('1. USER_ARGUMENTS exposes the common JDBC ABI');

   SELECT LISTAGG(ARGUMENT_NAME || ':' || IN_OUT, ',')
             WITHIN GROUP (ORDER BY POSITION)
     INTO l_actual_abi
     FROM USER_ARGUMENTS
    WHERE PACKAGE_NAME = 'MI_0600_API'
      AND OBJECT_NAME = 'CREATE_REQUEST'
      AND DATA_LEVEL = 0;

   assert_True(
      l_actual_abi = c_expected_abi,
      'unexpected ABI: ' || NVL(l_actual_abi, '<NULL>')
   );

   DBMS_OUTPUT.put_line('   OK');


   ---------------------------------------------------------------------------
   DBMS_OUTPUT.put_line('2. positional call uses the shared PG/Java order');

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
         'ABI_SMOKE_'
      || REPLACE(MI_Utils.uuid_V7, '-', '')
      || '.zip';

   DBMS_LOB.createtemporary(l_zip_blob, TRUE);
   DBMS_LOB.writeappend(
      l_zip_blob,
      22,
      HEXTORAW('504B0506000000000000000000000000000000000000')
   );

   MI_0600_Api.create_Request(
      601,
      l_zip_name,
      l_zip_blob,
      DBMS_LOB.getlength(l_zip_blob),
      1,
      SYS.ODCIVARCHAR2LIST('abi-smoke.xml'),
      l_req_id,
      l_itm_id,
      l_ret_code,
      l_ret_info,
      NULL,
      NULL,
      NULL,
      1
   );

   assert_True(
      l_ret_code = MI_0600_Api.RET_OK,
      'positional create_Request failed: ' || l_ret_info
   );
   assert_True(l_req_id IS NOT NULL, 'p_req_id is NULL');
   assert_True(l_itm_id IS NOT NULL, 'p_itm_id is NULL');

   SELECT COUNT(*)
     INTO l_count
     FROM MI_REQ r
     JOIN MI_0600 i
       ON i.REQ_ID = r.REQ_ID
     JOIN MI_0600_F f
       ON f.ITM_ID = i.ITM_ID
    WHERE r.REQ_ID = l_req_id
      AND i.ITM_ID = l_itm_id
      AND i.CZIP_NAME = l_zip_name
      AND f.CZIP_FILE_NAME = 'abi-smoke.xml';

   assert_True(l_count = 1, 'created journal is incomplete');

   DBMS_OUTPUT.put_line('   OK');

   ROLLBACK TO before_mi_0600_abi_smoke;

   DBMS_LOB.freetemporary(l_zip_blob);

   DBMS_OUTPUT.put_line('MI_0600_Api JDBC ABI smoke test passed');

EXCEPTION
   WHEN OTHERS THEN
      ROLLBACK TO before_mi_0600_abi_smoke;

      IF DBMS_LOB.istemporary(l_zip_blob) = 1 THEN
         DBMS_LOB.freetemporary(l_zip_blob);
      END IF;

      RAISE;
END;
/
