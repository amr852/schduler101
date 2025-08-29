/* ======================================================================
   SCHEDULER DB – FULL RE-RUNNABLE SETUP
   ====================================================================== */

---------------------------
-- 0) Database & Security
---------------------------
IF DB_ID(N'scheduler_db') IS NULL
BEGIN
    PRINT 'Creating database [scheduler_db]...';
    CREATE DATABASE [scheduler_db];
END
GO

-- Compatibility (AT TIME ZONE, OPENJSON need >= 130; we set to 150)
ALTER DATABASE [scheduler_db] SET COMPATIBILITY_LEVEL = 150;
GO

-- Create/repair SQL login at server-level (run as sysadmin)
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'app_user')
BEGIN
    PRINT 'Creating login [app_user]...';
    CREATE LOGIN [app_user]
        WITH PASSWORD = 'YourStrong!Passw0rd',
             CHECK_POLICY = OFF,
             CHECK_EXPIRATION = OFF;
END
ELSE
BEGIN
    PRINT 'Resetting password and unlocking login [app_user]...';
    ALTER LOGIN [app_user] WITH PASSWORD = 'YourStrong!Passw0rd';
    ALTER LOGIN [app_user] WITH PASSWORD = 'YourStrong!Passw0rd' UNLOCK;
END
ALTER LOGIN [app_user] ENABLE;
ALTER LOGIN [app_user] WITH DEFAULT_DATABASE = [scheduler_db];
GO

-- Map login to DB user and grant role (dev convenience)
USE [scheduler_db];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'app_user')
    CREATE USER [app_user] FOR LOGIN [app_user];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id AND r.name = N'db_owner'
    JOIN sys.database_principals m ON m.principal_id = drm.member_principal_id AND m.name = N'app_user'
)
    ALTER ROLE [db_owner] ADD MEMBER [app_user];
GO


-----------------------------------------
-- 1) Create schema (if not exists)
-----------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'app')
    EXEC ('CREATE SCHEMA app AUTHORIZATION dbo;');
GO


------------------------------------------------------------
-- 2) Safe DROP of programmable objects & tables (in order)
------------------------------------------------------------
-- Views
DROP VIEW IF EXISTS app.v_event_full;
DROP VIEW IF EXISTS app.v_event_participant_counts;
DROP VIEW IF EXISTS app.v_user_agenda;
GO

-- Functions
DROP FUNCTION IF EXISTS app.fn_utc_to_local;
DROP FUNCTION IF EXISTS app.fn_is_user_free;
DROP FUNCTION IF EXISTS app.fn_next_event;
DROP FUNCTION IF EXISTS app.fn_event_occurrences;
GO

-- Procedures
DROP PROCEDURE IF EXISTS app.sp_create_event;
DROP PROCEDURE IF EXISTS app.sp_add_participant;
DROP PROCEDURE IF EXISTS app.sp_common_free_slots;
DROP PROCEDURE IF EXISTS app.sp_enqueue_due_reminders;
DROP PROCEDURE IF EXISTS app.sp_write_audit;
GO

-- Triggers
DROP TRIGGER IF EXISTS app.tr_calendars_touch;
DROP TRIGGER IF EXISTS app.tr_events_touch;
GO

-- Tables (children → parents)
DROP TABLE IF EXISTS app.chat_messages;
DROP TABLE IF EXISTS app.chat_conversations;
DROP TABLE IF EXISTS app.audit_log;
DROP TABLE IF EXISTS app.notifications_outbox;
DROP TABLE IF EXISTS app.availability;
DROP TABLE IF EXISTS app.reminders;
DROP TABLE IF EXISTS app.event_participants;
DROP TABLE IF EXISTS app.event_recurrences;
DROP TABLE IF EXISTS app.events;
DROP TABLE IF EXISTS app.calendars;
DROP TABLE IF EXISTS app.sessions;
DROP TABLE IF EXISTS app.auth_local;
DROP TABLE IF EXISTS app.user_roles;
DROP TABLE IF EXISTS app.roles;
DROP TABLE IF EXISTS app.users;
DROP TABLE IF EXISTS app.tenants;
GO


---------------------------
-- 3) TABLES
---------------------------
-- Tenants
CREATE TABLE app.tenants (
  tenant_id   UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  name        NVARCHAR(200) NOT NULL,
  is_active   BIT NOT NULL DEFAULT 1,
  created_at  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Users
CREATE TABLE app.users (
  user_id      UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  tenant_id    UNIQUEIDENTIFIER NOT NULL,
  email        NVARCHAR(320) NOT NULL,
  display_name NVARCHAR(200) NOT NULL,
  phone        NVARCHAR(32) NULL,
  time_zone    NVARCHAR(64) NOT NULL DEFAULT 'Asia/Riyadh',
  is_active    BIT NOT NULL DEFAULT 1,
  created_at   DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at   DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_users_tenant FOREIGN KEY (tenant_id) REFERENCES app.tenants(tenant_id),
  CONSTRAINT UQ_users_tenant_email UNIQUE (tenant_id, email)
);
GO

-- Roles
CREATE TABLE app.roles (
  role_id INT IDENTITY(1,1) PRIMARY KEY,
  code    NVARCHAR(64) NOT NULL UNIQUE,      -- 'admin','manager','user'
  label   NVARCHAR(128) NOT NULL
);
GO

-- user_roles
CREATE TABLE app.user_roles (
  user_id UNIQUEIDENTIFIER NOT NULL,
  role_id INT NOT NULL,
  PRIMARY KEY (user_id, role_id),
  CONSTRAINT FK_user_roles_user FOREIGN KEY (user_id) REFERENCES app.users(user_id),
  CONSTRAINT FK_user_roles_role FOREIGN KEY (role_id) REFERENCES app.roles(role_id)
);
GO

-- Local auth
CREATE TABLE app.auth_local (
  user_id       UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
  password_hash VARBINARY(MAX) NOT NULL,
  password_algo NVARCHAR(32) NOT NULL,
  updated_at    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_authlocal_user FOREIGN KEY (user_id) REFERENCES app.users(user_id)
);
GO

-- Sessions
CREATE TABLE app.sessions (
  session_id UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  user_id    UNIQUEIDENTIFIER NOT NULL,
  created_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  expires_at DATETIME2(3) NOT NULL,
  user_agent NVARCHAR(400) NULL,
  ip_address NVARCHAR(64) NULL,
  CONSTRAINT FK_sessions_user FOREIGN KEY (user_id) REFERENCES app.users(user_id)
);
CREATE INDEX IX_sessions_user_expires ON app.sessions(user_id, expires_at);
GO

-- Calendars
CREATE TABLE app.calendars (
  calendar_id   UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  tenant_id     UNIQUEIDENTIFIER NOT NULL,
  owner_user_id UNIQUEIDENTIFIER NULL,  -- null for shared calendar
  name          NVARCHAR(200) NOT NULL,
  color_hex     CHAR(7) NULL,           -- '#34A853'
  is_primary    BIT NOT NULL DEFAULT 0,
  created_at    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_cal_tenant FOREIGN KEY (tenant_id) REFERENCES app.tenants(tenant_id),
  CONSTRAINT FK_cal_owner  FOREIGN KEY (owner_user_id) REFERENCES app.users(user_id)
);
CREATE UNIQUE INDEX UQ_primary_cal ON app.calendars(owner_user_id, is_primary) WHERE is_primary = 1;
GO

-- Events
CREATE TABLE app.events (
  event_id        UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  calendar_id     UNIQUEIDENTIFIER NOT NULL,
  title           NVARCHAR(300) NOT NULL,
  description     NVARCHAR(MAX) NULL,
  location        NVARCHAR(400) NULL,
  start_utc       DATETIME2(3) NOT NULL,
  end_utc         DATETIME2(3) NOT NULL,
  all_day         BIT NOT NULL DEFAULT 0,
  status          NVARCHAR(24) NOT NULL DEFAULT 'confirmed',   -- tentative|confirmed|cancelled
  visibility      NVARCHAR(24) NOT NULL DEFAULT 'private',     -- private|public|busy
  parent_event_id UNIQUEIDENTIFIER NULL,
  created_by      UNIQUEIDENTIFIER NOT NULL,
  created_at      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  updated_at      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_event_cal     FOREIGN KEY (calendar_id)     REFERENCES app.calendars(calendar_id),
  CONSTRAINT FK_event_creator FOREIGN KEY (created_by)      REFERENCES app.users(user_id),
  CONSTRAINT FK_event_parent  FOREIGN KEY (parent_event_id) REFERENCES app.events(event_id),
  CONSTRAINT CHK_event_time CHECK (end_utc > start_utc)
);
CREATE INDEX IX_events_calendar_time ON app.events(calendar_id, start_utc, end_utc);
GO

-- Recurrence metadata
CREATE TABLE app.event_recurrences (
  event_id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
  rrule    NVARCHAR(500) NOT NULL,
  timezone NVARCHAR(64) NOT NULL,
  EXDATE   NVARCHAR(MAX) NULL,
  RDATE    NVARCHAR(MAX) NULL,
  CONSTRAINT FK_recur_event FOREIGN KEY (event_id) REFERENCES app.events(event_id)
);
GO

-- Participants
CREATE TABLE app.event_participants (
  event_id        UNIQUEIDENTIFIER NOT NULL,
  user_id         UNIQUEIDENTIFIER NOT NULL,
  role            NVARCHAR(24) NOT NULL DEFAULT 'attendee',       -- organizer|attendee
  response_status NVARCHAR(24) NOT NULL DEFAULT 'needsAction',     -- accepted|declined|tentative|needsAction
  is_optional     BIT NOT NULL DEFAULT 0,
  PRIMARY KEY (event_id, user_id),
  CONSTRAINT FK_part_event FOREIGN KEY (event_id) REFERENCES app.events(event_id),
  CONSTRAINT FK_part_user  FOREIGN KEY (user_id)  REFERENCES app.users(user_id)
);
CREATE INDEX IX_part_user ON app.event_participants(user_id);
GO

-- Reminders
CREATE TABLE app.reminders (
  reminder_id    BIGINT IDENTITY(1,1) PRIMARY KEY,
  event_id       UNIQUEIDENTIFIER NOT NULL,
  minutes_before INT NOT NULL,           -- 0..10080
  channel        NVARCHAR(24) NOT NULL DEFAULT 'push', -- push|email|sms
  for_user_id    UNIQUEIDENTIFIER NULL,  -- null = applies to all participants
  CONSTRAINT FK_rem_event FOREIGN KEY (event_id) REFERENCES app.events(event_id),
  CONSTRAINT CHK_minutes_before CHECK (minutes_before >= 0)
);
CREATE INDEX IX_rem_event ON app.reminders(event_id);
GO

-- Availability
CREATE TABLE app.availability (
  availability_id BIGINT IDENTITY(1,1) PRIMARY KEY,
  user_id      UNIQUEIDENTIFIER NOT NULL,
  type         NVARCHAR(24) NOT NULL,  -- 'weekly' | 'exception'
  dow          TINYINT NULL,           -- 1=Mon..7=Sun (for weekly)
  start_local  TIME NULL,
  end_local    TIME NULL,
  date_local   DATE NULL,              -- for 'exception'
  is_available BIT NOT NULL DEFAULT 1,
  timezone     NVARCHAR(64) NOT NULL DEFAULT 'Asia/Riyadh',
  CONSTRAINT FK_avail_user FOREIGN KEY (user_id) REFERENCES app.users(user_id)
);
CREATE INDEX IX_avail_user ON app.availability(user_id);
GO

-- Outbox (no FK to keep loose coupling)
CREATE TABLE app.notifications_outbox (
  id              BIGINT IDENTITY(1,1) PRIMARY KEY,
  tenant_id       UNIQUEIDENTIFIER NOT NULL,
  channel         NVARCHAR(24) NOT NULL, -- email|push|sms|webhook
  to_ref          NVARCHAR(400) NOT NULL,
  subject         NVARCHAR(400) NULL,
  payload_json    NVARCHAR(MAX) NOT NULL,
  send_after_utc  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  sent_at_utc     DATETIME2(3) NULL,
  status          NVARCHAR(24) NOT NULL DEFAULT 'queued', -- queued|sent|failed
  last_error      NVARCHAR(800) NULL
);
CREATE INDEX IX_outbox_ready ON app.notifications_outbox(status, send_after_utc);
GO

-- Audit log
CREATE TABLE app.audit_log (
  audit_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
  tenant_id     UNIQUEIDENTIFIER NOT NULL,
  actor_user_id UNIQUEIDENTIFIER NULL,
  action        NVARCHAR(64) NOT NULL,    -- 'event.create','event.update',...
  entity_type   NVARCHAR(64) NOT NULL,    -- 'event','calendar','user'
  entity_id     NVARCHAR(64) NOT NULL,
  before_json   NVARCHAR(MAX) NULL,
  after_json    NVARCHAR(MAX) NULL,
  created_at    DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Chat
CREATE TABLE app.chat_conversations (
  conversation_id UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  tenant_id       UNIQUEIDENTIFIER NOT NULL,
  started_by      UNIQUEIDENTIFIER NOT NULL,
  started_at      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  status          NVARCHAR(24) NOT NULL DEFAULT 'open'  -- open|closed
);
GO

CREATE TABLE app.chat_messages (
  message_id      UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY,
  conversation_id UNIQUEIDENTIFIER NOT NULL,
  sender_type     NVARCHAR(24) NOT NULL, -- user|assistant|system
  sender_user_id  UNIQUEIDENTIFIER NULL, -- null for assistant/system
  content         NVARCHAR(MAX) NOT NULL,
  created_at      DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  tool_calls_json NVARCHAR(MAX) NULL,
  CONSTRAINT FK_chat_msg_conv FOREIGN KEY (conversation_id) REFERENCES app.chat_conversations(conversation_id)
);
GO


---------------------------
-- 4) VIEWS
---------------------------
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE VIEW app.v_event_full AS
SELECT
  e.event_id, e.title, e.description, e.location,
  e.start_utc, e.end_utc, e.all_day, e.status, e.visibility,
  e.parent_event_id, e.created_by, e.created_at, e.updated_at,
  c.calendar_id, c.name AS calendar_name, c.owner_user_id, c.color_hex,
  u.display_name AS owner_name, u.email AS owner_email, u.time_zone AS owner_tz,
  c.tenant_id
FROM app.events e
JOIN app.calendars c ON c.calendar_id = e.calendar_id
LEFT JOIN app.users u ON u.user_id = c.owner_user_id;
GO

CREATE VIEW app.v_event_participant_counts AS
SELECT
  e.event_id,
  COUNT(*) AS participant_count,
  SUM(CASE WHEN p.response_status = 'accepted'  THEN 1 ELSE 0 END) AS accepted_count,
  SUM(CASE WHEN p.response_status = 'tentative' THEN 1 ELSE 0 END) AS tentative_count,
  SUM(CASE WHEN p.response_status = 'declined'  THEN 1 ELSE 0 END) AS declined_count
FROM app.events e
LEFT JOIN app.event_participants p ON p.event_id = e.event_id
GROUP BY e.event_id;
GO

CREATE VIEW app.v_user_agenda AS
SELECT
  p.user_id,
  e.event_id, e.title, e.start_utc, e.end_utc, e.status, e.all_day,
  c.name AS calendar_name, c.color_hex, c.owner_user_id
FROM app.event_participants p
JOIN app.events e    ON e.event_id = p.event_id
JOIN app.calendars c ON c.calendar_id = e.calendar_id
WHERE e.status <> 'cancelled';
GO


---------------------------
-- 5) FUNCTIONS
---------------------------
CREATE FUNCTION app.fn_utc_to_local (@utc DATETIME2(3), @tz NVARCHAR(64))
RETURNS DATETIME2(3)
AS
BEGIN
  RETURN CAST( ( @utc AT TIME ZONE 'UTC' ) AT TIME ZONE @tz AS DATETIME2(3) );
END;
GO

CREATE FUNCTION app.fn_is_user_free (@userId UNIQUEIDENTIFIER, @start DATETIME2(3), @end DATETIME2(3))
RETURNS BIT
AS
BEGIN
  DECLARE @busy BIT = 0;
  IF EXISTS (
    SELECT 1
    FROM app.events e
    JOIN app.event_participants p ON p.event_id = e.event_id
    WHERE p.user_id = @userId
      AND e.status <> 'cancelled'
      AND e.end_utc > @start AND e.start_utc < @end
  )
    SET @busy = 1;
  RETURN IIF(@busy=1,0,1);
END;
GO

CREATE FUNCTION app.fn_next_event (@userId UNIQUEIDENTIFIER)
RETURNS TABLE
AS
RETURN
  SELECT TOP 1 e.*
  FROM app.events e
  JOIN app.event_participants p ON p.event_id = e.event_id
  WHERE p.user_id = @userId
    AND e.status = 'confirmed'
    AND e.start_utc > SYSUTCDATETIME()
  ORDER BY e.start_utc ASC;
GO

CREATE FUNCTION app.fn_event_occurrences (@eventId UNIQUEIDENTIFIER)
RETURNS TABLE
AS
RETURN
  SELECT start_utc, end_utc
  FROM app.events
  WHERE event_id = @eventId;
GO


---------------------------
-- 6) PROCEDURES
---------------------------
CREATE PROCEDURE app.sp_create_event
  @calendar_id       UNIQUEIDENTIFIER,
  @title             NVARCHAR(300),
  @description       NVARCHAR(MAX) = NULL,
  @location          NVARCHAR(400) = NULL,
  @start_utc         DATETIME2(3),
  @end_utc           DATETIME2(3),
  @all_day           BIT = 0,
  @status            NVARCHAR(24) = 'confirmed',
  @visibility        NVARCHAR(24) = 'private',
  @created_by        UNIQUEIDENTIFIER,
  @participants_json NVARCHAR(MAX) = NULL,  -- JSON array of user_ids
  @reminders_json    NVARCHAR(MAX) = NULL   -- JSON array of objects
AS
BEGIN
  SET NOCOUNT ON;
  BEGIN TRY
    BEGIN TRAN;

    DECLARE @event_id UNIQUEIDENTIFIER = NEWID();

    INSERT INTO app.events(event_id, calendar_id, title, description, location,
                           start_utc, end_utc, all_day, status, visibility, created_by)
    VALUES (@event_id, @calendar_id, @title, @description, @location,
            @start_utc, @end_utc, @all_day, @status, @visibility, @created_by);

    -- participants
    IF @participants_json IS NOT NULL
    BEGIN
      INSERT INTO app.event_participants(event_id, user_id, role, response_status)
      SELECT @event_id, TRY_CONVERT(UNIQUEIDENTIFIER, value), 'attendee', 'needsAction'
      FROM OPENJSON(@participants_json);
    END

    -- ensure creator is organizer
    IF NOT EXISTS (SELECT 1 FROM app.event_participants WHERE event_id=@event_id AND user_id=@created_by)
    BEGIN
      INSERT INTO app.event_participants(event_id, user_id, role, response_status)
      VALUES (@event_id, @created_by, 'organizer', 'accepted');
    END

    -- reminders
    IF @reminders_json IS NOT NULL
    BEGIN
      INSERT INTO app.reminders(event_id, minutes_before, channel, for_user_id)
      SELECT
        @event_id,
        TRY_CONVERT(INT, JSON_VALUE(value,'$.minutes_before')),
        ISNULL(JSON_VALUE(value,'$.channel'),'push'),
        TRY_CONVERT(UNIQUEIDENTIFIER, JSON_VALUE(value,'$.for_user_id'))
      FROM OPENJSON(@reminders_json);
    END

    COMMIT;
    SELECT @event_id AS event_id;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
  END CATCH
END;
GO

CREATE PROCEDURE app.sp_add_participant
  @event_id UNIQUEIDENTIFIER,
  @user_id  UNIQUEIDENTIFIER,
  @role     NVARCHAR(24) = 'attendee'
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS (SELECT 1 FROM app.event_participants WHERE event_id=@event_id AND user_id=@user_id)
  BEGIN
    INSERT INTO app.event_participants(event_id,user_id,role,response_status)
    VALUES (@event_id,@user_id,COALESCE(@role,'attendee'),'needsAction');
  END
END;
GO

CREATE PROCEDURE app.sp_common_free_slots
  @userA UNIQUEIDENTIFIER,
  @userB UNIQUEIDENTIFIER,
  @from  DATETIME2(3),
  @to    DATETIME2(3)
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH Busy AS (
    SELECT DISTINCT p.user_id, e.start_utc, e.end_utc
    FROM app.events e
    JOIN app.event_participants p ON p.event_id = e.event_id
    WHERE e.status <> 'cancelled'
      AND e.end_utc > @from AND e.start_utc < @to
      AND p.user_id IN (@userA,@userB)
  )
  SELECT
    @from AS range_start,
    @to   AS range_end,
    CASE WHEN EXISTS (SELECT 1 FROM Busy WHERE user_id=@userA)
           OR EXISTS (SELECT 1 FROM Busy WHERE user_id=@userB)
         THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS both_free;
END;
GO

CREATE PROCEDURE app.sp_enqueue_due_reminders
AS
BEGIN
  SET NOCOUNT ON;

  INSERT INTO app.notifications_outbox (tenant_id, channel, to_ref, subject, payload_json, send_after_utc)
  SELECT DISTINCT
    u.tenant_id,
    r.channel,
    COALESCE(u.email, u.phone, N'') AS to_ref,
    CONCAT(N'Reminder: ', e.title),
    CONCAT(
      N'{"event_id":"', CONVERT(NVARCHAR(36), e.event_id),
      N'","title":"', REPLACE(e.title,'"','""'),
      N'","start_utc":"', CONVERT(NVARCHAR(33), e.start_utc, 127), N'"}'
    ),
    SYSUTCDATETIME()
  FROM app.reminders r
  JOIN app.events e ON e.event_id = r.event_id
  JOIN (
      SELECT DISTINCT COALESCE(r.for_user_id, e.created_by, p.user_id) AS target_user_id, e.event_id
      FROM app.reminders r
      JOIN app.events e ON e.event_id = r.event_id
      LEFT JOIN app.event_participants p ON p.event_id = e.event_id
  ) t ON t.event_id = e.event_id
  JOIN app.users u ON u.user_id = t.target_user_id
  WHERE e.start_utc > SYSUTCDATETIME()
    AND e.start_utc <= DATEADD(MINUTE, r.minutes_before, SYSUTCDATETIME())
    AND NOT EXISTS (
      SELECT 1 FROM app.notifications_outbox o
      WHERE o.status = 'queued'
        AND o.payload_json LIKE CONCAT('%"event_id":"', CONVERT(NVARCHAR(36), e.event_id), '"%')
        AND o.to_ref = COALESCE(u.email, u.phone, N'')
    );
END;
GO

CREATE PROCEDURE app.sp_write_audit
  @tenantId   UNIQUEIDENTIFIER,
  @actorUser  UNIQUEIDENTIFIER = NULL,
  @action     NVARCHAR(64),
  @entityType NVARCHAR(64),
  @entityId   NVARCHAR(64),
  @before     NVARCHAR(MAX) = NULL,
  @after      NVARCHAR(MAX)  = NULL
AS
BEGIN
  INSERT INTO app.audit_log(tenant_id, actor_user_id, action, entity_type, entity_id, before_json, after_json)
  VALUES (@tenantId, @actorUser, @action, @entityType, @entityId, @before, @after);
END;
GO


---------------------------
-- 7) TRIGGERS
---------------------------
CREATE TRIGGER app.tr_calendars_touch ON app.calendars
AFTER UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE c SET updated_at = SYSUTCDATETIME()
  FROM app.calendars c
  JOIN inserted i ON i.calendar_id = c.calendar_id;
END;
GO

CREATE TRIGGER app.tr_events_touch ON app.events
AFTER UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE e SET updated_at = SYSUTCDATETIME()
  FROM app.events e
  JOIN inserted i ON i.event_id = e.event_id;
END;
GO


---------------------------
-- 8) SEED DATA (idempotent)
---------------------------
-- Roles
IF NOT EXISTS (SELECT 1 FROM app.roles)
  INSERT INTO app.roles(code,label)
  VALUES (N'admin',N'Administrator'),(N'manager',N'Manager'),(N'user',N'User');
GO

-- Tenant + users + primary calendars + sample event
DECLARE @tenant UNIQUEIDENTIFIER = (SELECT TOP 1 tenant_id FROM app.tenants ORDER BY created_at);
IF @tenant IS NULL
BEGIN
  SET @tenant = NEWID();
  INSERT INTO app.tenants(tenant_id, name) VALUES (@tenant, N'Demo Tenant');
END

DECLARE @alice UNIQUEIDENTIFIER = (SELECT user_id FROM app.users WHERE email = N'alice@example.com');
IF @alice IS NULL
BEGIN
  SET @alice = NEWID();
  INSERT INTO app.users(user_id, tenant_id, email, display_name)
  VALUES (@alice, @tenant, N'alice@example.com', N'Alice');
END

DECLARE @bob UNIQUEIDENTIFIER = (SELECT user_id FROM app.users WHERE email = N'bob@example.com');
IF @bob IS NULL
BEGIN
  SET @bob = NEWID();
  INSERT INTO app.users(user_id, tenant_id, email, display_name)
  VALUES (@bob, @tenant, N'bob@example.com', N'Bob');
END

IF NOT EXISTS (SELECT 1 FROM app.user_roles WHERE user_id=@alice)
  INSERT INTO app.user_roles(user_id, role_id)
  SELECT @alice, role_id FROM app.roles WHERE code='admin';

DECLARE @calAlice UNIQUEIDENTIFIER = (SELECT TOP 1 calendar_id FROM app.calendars WHERE owner_user_id=@alice ORDER BY is_primary DESC, created_at);
IF @calAlice IS NULL
BEGIN
  SET @calAlice = NEWID();
  INSERT INTO app.calendars(calendar_id, tenant_id, owner_user_id, name, is_primary)
  VALUES (@calAlice, @tenant, @alice, N'Alice Calendar', 1);
END

DECLARE @calBob UNIQUEIDENTIFIER = (SELECT TOP 1 calendar_id FROM app.calendars WHERE owner_user_id=@bob ORDER BY is_primary DESC, created_at);
IF @calBob IS NULL
BEGIN
  SET @calBob = NEWID();
  INSERT INTO app.calendars(calendar_id, tenant_id, owner_user_id, name, is_primary)
  VALUES (@calBob, @tenant, @bob, N'Bob Calendar', 1);
END

DECLARE @now      DATETIME2(3) = SYSUTCDATETIME();
DECLARE @startUtc DATETIME2(3) = DATEADD(MINUTE, 60,  @now);  -- +1h
DECLARE @endUtc   DATETIME2(3) = DATEADD(MINUTE, 120, @now);  -- +2h
DECLARE @participants NVARCHAR(MAX) = N'["' + CONVERT(NVARCHAR(36), @bob) + N'"]';
DECLARE @reminders    NVARCHAR(MAX) = N'[{"minutes_before":30,"channel":"email"}]';

IF NOT EXISTS (SELECT 1 FROM app.events WHERE title = N'Project Kickoff' AND calendar_id = @calAlice)
BEGIN
  EXEC app.sp_create_event
    @calendar_id       = @calAlice,
    @title             = N'Project Kickoff',
    @description       = N'Initial meeting',
    @location          = N'Meeting Room A',
    @start_utc         = @startUtc,
    @end_utc           = @endUtc,
    @all_day           = 0,
    @status            = 'confirmed',
    @visibility        = 'private',
    @created_by        = @alice,
    @participants_json = @participants,
    @reminders_json    = @reminders;
END
GO

PRINT '✔ Scheduler DB setup complete.';
