\set ON_ERROR_STOP on
\encoding UTF8
\pset tuples_only on
\pset format unaligned
\pset pager off
\set QUIET 1

/*
   Generates an Oracle 12.1 SQL script for one-shot synchronization:

      PostgreSQL xxi.mi_wsp -> Oracle MI_WSP
      PostgreSQL xxi.mi_inf -> Oracle MI_INF

   Output is idempotent MERGE DML. No target rows are deleted.

   Preferred launcher:

      tools\migration\export-mi-wsp-inf.cmd

   It writes:

      <repo-root>\mi-wsp-inf.oracle.sql

   Then apply to Oracle:

      tools\apply-sql.cmd mi-wsp-inf.oracle.sql
*/


/*
   Oracle SQL literal.

   - NULL stays SQL NULL.
   - single quotes are doubled;
   - CR/LF are emitted through CHR() so generated SQL remains structurally safe;
   - '&' needs no special handling because generated script uses SET DEFINE OFF.
*/
CREATE OR REPLACE FUNCTION pg_temp.ora_literal (
   p_value text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
   SELECT CASE
             WHEN p_value IS NULL
             THEN 'NULL'

             ELSE
                   ''''
                || replace(
                      replace(
                         replace(
                            replace(
                               p_value,
                               '''',
                               ''''''
                            ),
                            chr(13) || chr(10),
                            $q$' || CHR(13) || CHR(10) || '$q$
                         ),
                         chr(13),
                         $q$' || CHR(13) || '$q$
                      ),
                      chr(10),
                      $q$' || CHR(10) || '$q$
                   )
                || ''''
          END;
$function$;


/*
   Preflight for lengths that are wider in PostgreSQL than in the current
   Oracle model. Other string columns are already bounded by PG varchar sizes.
*/
DO $block$
DECLARE
   l_id  numeric;
   l_len integer;
BEGIN
   SELECT wsp_id,
          length(note)
     INTO STRICT l_id,
                 l_len
     FROM xxi.mi_wsp
    WHERE note IS NOT NULL
      AND length(note) > 500
    ORDER BY wsp_id
    LIMIT 1;

   RAISE EXCEPTION
      'MI_WSP.NOTE too long for Oracle VARCHAR2(500): WSP_ID=%, length=%',
      l_id,
      l_len;

EXCEPTION
   WHEN NO_DATA_FOUND THEN
      NULL;
END;
$block$;


DO $block$
DECLARE
   l_id  numeric;
   l_len integer;
BEGIN
   SELECT inf_id,
          length(note)
     INTO STRICT l_id,
                 l_len
     FROM xxi.mi_inf
    WHERE note IS NOT NULL
      AND length(note) > 500
    ORDER BY inf_id
    LIMIT 1;

   RAISE EXCEPTION
      'MI_INF.NOTE too long for Oracle VARCHAR2(500): INF_ID=%, length=%',
      l_id,
      l_len;

EXCEPTION
   WHEN NO_DATA_FOUND THEN
      NULL;
END;
$block$;

\set QUIET 0

\echo SET DEFINE OFF
\echo SET SQLBLANKLINES ON
\echo WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
\echo
\echo PROMPT ============================================================
\echo PROMPT PostgreSQL -> Oracle core data: MI_WSP / MI_INF
\echo PROMPT ============================================================
\echo

SELECT '-- Source MI_WSP rows: ' || count(*)
  FROM xxi.mi_wsp;

SELECT '-- Source MI_INF rows: ' || count(*)
  FROM xxi.mi_inf;

\echo
\echo PROMPT === MI_WSP ==================================================

SELECT
      'MERGE INTO MI_WSP t' || chr(10)
   || 'USING (' || chr(10)
   || '   SELECT '
   || wsp_id::text
   || ' AS WSP_ID, '
   || pg_temp.ora_literal(name)
   || ' AS NAME, '
   || pg_temp.ora_literal(note)
   || ' AS NOTE'
   || chr(10)
   || '     FROM dual'
   || chr(10)
   || ') s'
   || chr(10)
   || 'ON (t.WSP_ID = s.WSP_ID)'
   || chr(10)
   || 'WHEN MATCHED THEN UPDATE SET'
   || chr(10)
   || '   t.NAME = s.NAME,'
   || chr(10)
   || '   t.NOTE = s.NOTE'
   || chr(10)
   || 'WHEN NOT MATCHED THEN INSERT ('
   || chr(10)
   || '   WSP_ID, NAME, NOTE'
   || chr(10)
   || ') VALUES ('
   || chr(10)
   || '   s.WSP_ID, s.NAME, s.NOTE'
   || chr(10)
   || ');'
   || chr(10)
  FROM xxi.mi_wsp
 ORDER BY wsp_id;


\echo
\echo PROMPT === MI_INF ==================================================

SELECT
      'MERGE INTO MI_INF t' || chr(10)
   || 'USING (' || chr(10)
   || '   SELECT '
   || inf_id::text
   || ' AS INF_ID, '
   || wsp_id::text
   || ' AS WSP_ID, '
   || initiator_cd::text
   || ' AS INITIATOR_CD, '
   || pg_temp.ora_literal(name_inf)
   || ' AS NAME_INF, '
   || pg_temp.ora_literal(name_official)
   || ' AS NAME_OFFICIAL, '
   || pg_temp.ora_literal(namespace_inf)
   || ' AS NAMESPACE_INF, '
   || pg_temp.ora_literal(gate_alias)
   || ' AS GATE_ALIAS, '
   || pg_temp.ora_literal(request_queue)
   || ' AS REQ_QUEUE, '
   || pg_temp.ora_literal(response_queue)
   || ' AS RSP_QUEUE, '
   || coalesce(request_ttl_ms::text, 'NULL')
   || ' AS REQ_TTL_MS, '
   || coalesce(response_ttl_ms::text, 'NULL')
   || ' AS RSP_TTL_MS, '
   || pg_temp.ora_literal(url_doc)
   || ' AS URL_DOC, '
   || pg_temp.ora_literal(note)
   || ' AS NOTE, '
   || CASE WHEN audit_on THEN '1' ELSE '0' END
   || ' AS AUDIT_ON'
   || chr(10)
   || '     FROM dual'
   || chr(10)
   || ') s'
   || chr(10)
   || 'ON (t.INF_ID = s.INF_ID)'
   || chr(10)
   || 'WHEN MATCHED THEN UPDATE SET'
   || chr(10)
   || '   t.WSP_ID         = s.WSP_ID,'
   || chr(10)
   || '   t.INITIATOR_CD   = s.INITIATOR_CD,'
   || chr(10)
   || '   t.NAME_INF       = s.NAME_INF,'
   || chr(10)
   || '   t.NAME_OFFICIAL  = s.NAME_OFFICIAL,'
   || chr(10)
   || '   t.NAMESPACE_INF  = s.NAMESPACE_INF,'
   || chr(10)
   || '   t.GATE_ALIAS     = s.GATE_ALIAS,'
   || chr(10)
   || '   t.REQ_QUEUE      = s.REQ_QUEUE,'
   || chr(10)
   || '   t.RSP_QUEUE      = s.RSP_QUEUE,'
   || chr(10)
   || '   t.REQ_TTL_MS     = s.REQ_TTL_MS,'
   || chr(10)
   || '   t.RSP_TTL_MS     = s.RSP_TTL_MS,'
   || chr(10)
   || '   t.URL_DOC        = s.URL_DOC,'
   || chr(10)
   || '   t.NOTE           = s.NOTE,'
   || chr(10)
   || '   t.AUDIT_ON       = s.AUDIT_ON'
   || chr(10)
   || 'WHEN NOT MATCHED THEN INSERT ('
   || chr(10)
   || '   INF_ID, WSP_ID, INITIATOR_CD,'
   || chr(10)
   || '   NAME_INF, NAME_OFFICIAL, NAMESPACE_INF,'
   || chr(10)
   || '   GATE_ALIAS, REQ_QUEUE, RSP_QUEUE,'
   || chr(10)
   || '   REQ_TTL_MS, RSP_TTL_MS,'
   || chr(10)
   || '   URL_DOC, NOTE, AUDIT_ON'
   || chr(10)
   || ') VALUES ('
   || chr(10)
   || '   s.INF_ID, s.WSP_ID, s.INITIATOR_CD,'
   || chr(10)
   || '   s.NAME_INF, s.NAME_OFFICIAL, s.NAMESPACE_INF,'
   || chr(10)
   || '   s.GATE_ALIAS, s.REQ_QUEUE, s.RSP_QUEUE,'
   || chr(10)
   || '   s.REQ_TTL_MS, s.RSP_TTL_MS,'
   || chr(10)
   || '   s.URL_DOC, s.NOTE, s.AUDIT_ON'
   || chr(10)
   || ');'
   || chr(10)
  FROM xxi.mi_inf
 ORDER BY inf_id;


\echo
\echo COMMIT;
\echo
\echo PROMPT ============================================================
\echo PROMPT Verification
\echo PROMPT ============================================================
\echo
\echo SELECT COUNT(*) AS MI_WSP_COUNT FROM MI_WSP;
\echo SELECT COUNT(*) AS MI_INF_COUNT FROM MI_INF;
\echo
\echo PROMPT PostgreSQL -> Oracle core data completed
