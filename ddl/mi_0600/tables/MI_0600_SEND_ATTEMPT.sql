-- Oracle 12.1/19. Durable single-attempt guard for manual MI_0600/601 send.
--
-- V1 intentionally permits at most one attempt ever per REQ_ID.
-- This is a creation/model-import script, not a repeatable migration.
--
-- Prerequisites:
--    MI_REQ(REQ_ID);
--    tablespaces USERS and INDEXES.


CREATE TABLE MI_0600_SEND_ATTEMPT
(
   REQ_ID                INTEGER                     NOT NULL,
   CALL_UUID             CHAR(36)                    NOT NULL,
   BUS_CORRELATION_ID    VARCHAR2(200)               NOT NULL,

   GATE_ALIAS            VARCHAR2(100)               NOT NULL,
   REQUEST_QUEUE         VARCHAR2(100)               NOT NULL,
   RESPONSE_QUEUE        VARCHAR2(100)               NOT NULL,
   TIMEOUT_SEC           INTEGER                     NOT NULL,

   LOCK_ID               NUMBER(10)                  NOT NULL,
   TOKEN_HASH            RAW(32)                     NOT NULL,

   STATE_CD              CHAR(1)                     NOT NULL,
   CLAIMED_AT            TIMESTAMP WITH TIME ZONE
                            DEFAULT SYSTIMESTAMP      NOT NULL,
   FINISHED_AT           TIMESTAMP WITH TIME ZONE,
   LAST_RECONCILED_AT    TIMESTAMP WITH TIME ZONE,

   RESULT_CODE           VARCHAR2(100),
   RESULT_INFO           VARCHAR2(2000),
   CAUSE_CODE            VARCHAR2(100),
   CAUSE_INFO            VARCHAR2(2000),

   BUS_RESULT_CODE       NUMBER,
   RESPONSE_SIZE         INTEGER,
   DELIVERY_OUTCOME      VARCHAR2(30),
   RETRY_SAFE            NUMBER(1),
   TRANSPORT_ENTERED     NUMBER(1),
   RECEIVE_ENTERED       NUMBER(1),

   CONSTRAINT CK_MI_0600_SA__CALL_UUID
      CHECK (
         REGEXP_LIKE(
            CALL_UUID,
            '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
            'c'
         )
      ),

   CONSTRAINT CK_MI_0600_SA__STATE
      CHECK (STATE_CD IN ('C', 'S', 'U', 'N')),

   CONSTRAINT CK_MI_0600_SA__TIMEOUT
      CHECK (TIMEOUT_SEC > 0),

   CONSTRAINT CK_MI_0600_SA__LOCK_ID
      CHECK (LOCK_ID BETWEEN 0 AND 1073741823),

   CONSTRAINT CK_MI_0600_SA__RETRY_SAFE
      CHECK (RETRY_SAFE IS NULL OR RETRY_SAFE IN (0, 1)),

   CONSTRAINT CK_MI_0600_SA__TRANSPORT
      CHECK (TRANSPORT_ENTERED IS NULL OR TRANSPORT_ENTERED IN (0, 1)),

   CONSTRAINT CK_MI_0600_SA__RECEIVE
      CHECK (RECEIVE_ENTERED IS NULL OR RECEIVE_ENTERED IN (0, 1)),

   CONSTRAINT CK_MI_0600_SA__RESPONSE_SIZE
      CHECK (RESPONSE_SIZE IS NULL OR RESPONSE_SIZE >= 0)
)
TABLESPACE USERS;


-------------------------------------------------------------------------------
-- Primary and unique keys
-------------------------------------------------------------------------------
CREATE UNIQUE INDEX P_MI_0600_SEND_ATTEMPT
   ON MI_0600_SEND_ATTEMPT (REQ_ID)
   TABLESPACE INDEXES
   REVERSE;

ALTER TABLE MI_0600_SEND_ATTEMPT
   ADD CONSTRAINT PK_MI_0600_SEND_ATTEMPT
   PRIMARY KEY (REQ_ID)
   USING INDEX P_MI_0600_SEND_ATTEMPT;


CREATE UNIQUE INDEX U_MI_0600_SA__CALL_UUID
   ON MI_0600_SEND_ATTEMPT (CALL_UUID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600_SEND_ATTEMPT
   ADD CONSTRAINT UK_MI_0600_SA__CALL_UUID
   UNIQUE (CALL_UUID)
   USING INDEX U_MI_0600_SA__CALL_UUID;


CREATE UNIQUE INDEX U_MI_0600_SA__BUS_COR
   ON MI_0600_SEND_ATTEMPT (BUS_CORRELATION_ID)
   TABLESPACE INDEXES;

ALTER TABLE MI_0600_SEND_ATTEMPT
   ADD CONSTRAINT UK_MI_0600_SA__BUS_COR
   UNIQUE (BUS_CORRELATION_ID)
   USING INDEX U_MI_0600_SA__BUS_COR;


-------------------------------------------------------------------------------
-- Operational access paths
-------------------------------------------------------------------------------
CREATE INDEX I_MI_0600_SA__STATE_CLAIMED
   ON MI_0600_SEND_ATTEMPT (STATE_CD, CLAIMED_AT)
   TABLESPACE INDEXES;


-------------------------------------------------------------------------------
-- Referential integrity
-------------------------------------------------------------------------------
ALTER TABLE MI_0600_SEND_ATTEMPT
   ADD CONSTRAINT FK_MI_0600_SA__MI_REQ
   FOREIGN KEY (REQ_ID)
   REFERENCES MI_REQ (REQ_ID)
   ON DELETE CASCADE;


-------------------------------------------------------------------------------
-- Comments
-------------------------------------------------------------------------------
COMMENT ON TABLE MI_0600_SEND_ATTEMPT IS
   'Durable fail-closed attempt for one manual outgoing MI_0600/601 send {$Id$}';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.REQ_ID IS
   'MI_REQ identifier; v1 allows only one attempt ever per request';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.CALL_UUID IS
   'Pinned XXL call_uuid';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.BUS_CORRELATION_ID IS
   'Pinned caller-allocated CBS correlation identifier';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.GATE_ALIAS IS
   'Pinned effective Multi-Bus gate alias';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.REQUEST_QUEUE IS
   'Pinned effective request queue';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.RESPONSE_QUEUE IS
   'Pinned effective response queue used by dispatch and reconciliation';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.TIMEOUT_SEC IS
   'Pinned effective synchronous transport timeout';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.LOCK_ID IS
   'Stable DBMS_LOCK user-lock id shared by dispatch and reconcile';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.TOKEN_HASH IS
   'SHA-256 of one-shot package-session dispatch capability; raw token is not stored';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.STATE_CD IS
   'C=claimed, S=confirmed sent, U=unknown, N=confirmed not enqueued; none authorizes retry';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.CLAIMED_AT IS
   'Durable claim timestamp';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.FINISHED_AT IS
   'Timestamp of latest terminal S/U/N classification';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.LAST_RECONCILED_AT IS
   'Timestamp of latest receive-only reconciliation';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.TRANSPORT_ENTERED IS
   '1 when controlled queryBusClob boundary was entered, 0 for proven pre-transport rejection';

COMMENT ON COLUMN MI_0600_SEND_ATTEMPT.RECEIVE_ENTERED IS
   '1 when receive-only QUERY_RECEIVE boundary was entered';

