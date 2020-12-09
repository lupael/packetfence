-- PacketFence SQL schema upgrade from X.X.X to X.Y.Z
--


--
-- Setting the major/minor/sub-minor version of the DB
--

SET @MAJOR_VERSION = 10;
SET @MINOR_VERSION = 2;
SET @SUBMINOR_VERSION = 9;



SET @PREV_MAJOR_VERSION = 10;
SET @PREV_MINOR_VERSION = 2;
SET @PREV_SUBMINOR_VERSION = 0;


--
-- The VERSION_INT to ensure proper ordering of the version in queries
--

SET @VERSION_INT = @MAJOR_VERSION << 16 | @MINOR_VERSION << 8 | @SUBMINOR_VERSION;

SET @PREV_VERSION_INT = @PREV_MAJOR_VERSION << 16 | @PREV_MINOR_VERSION << 8 | @PREV_SUBMINOR_VERSION;

DROP PROCEDURE IF EXISTS ValidateVersion;
--
-- Updating to current version
--
DELIMITER //
CREATE PROCEDURE ValidateVersion()
BEGIN
    DECLARE PREVIOUS_VERSION int(11);
    DECLARE PREVIOUS_VERSION_STRING varchar(11);
    DECLARE _message varchar(255);
    SELECT id, version INTO PREVIOUS_VERSION, PREVIOUS_VERSION_STRING FROM pf_version ORDER BY id DESC LIMIT 1;

      IF PREVIOUS_VERSION != @PREV_VERSION_INT THEN
        SELECT CONCAT('PREVIOUS VERSION ', PREVIOUS_VERSION_STRING, ' DOES NOT MATCH ', CONCAT_WS('.', @PREV_MAJOR_VERSION, @PREV_MINOR_VERSION, @PREV_SUBMINOR_VERSION)) INTO _message;
        SIGNAL SQLSTATE VALUE '99999'
              SET MESSAGE_TEXT = _message;
      END IF;
END
//

DELIMITER ;
\! echo "Checking PacketFence schema version...";
call ValidateVersion;
DROP PROCEDURE IF EXISTS ValidateVersion;

DELIMITER //
CREATE TRIGGER `log_event_auth_log_insert` AFTER INSERT ON `auth_log`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "auth_log",
        "tenant_id", NEW.tenant_id,
        "process_name", NEW.process_name,
        "mac", NEW.mac,
        "pid", NEW.pid,
        "status", NEW.status,
        "attempted_at", NEW.attempted_at,
        "completed_at", NEW.completed_at,
        "source", NEW.source,
        "profile", NEW.profile
    );
END;
//

DELIMITER ;

DELIMITER //
CREATE TRIGGER `log_event_admin_api_audit_log_insert` AFTER INSERT ON `admin_api_audit_log`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "admin_api_audit_log",
        "tenant_id", NEW.tenant_id,
        "created_at", NEW.created_at,
        "user_name", NEW.user_name,
        "action", NEW.action,
        "object_id", NEW.object_id,
        "url", NEW.url,
        "method", NEW.method,
        "request", NEW.request,
        "status", NEW.status
    );
END;
//
DELIMITER ;

DELIMITER //
CREATE TRIGGER `log_event_auth_log_update` AFTER UPDATE ON `auth_log`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "auth_log",
        "tenant_id", NEW.tenant_id,
        "process_name", NEW.process_name,
        "mac", NEW.mac,
        "pid", NEW.pid,
        "status", NEW.status,
        "attempted_at", NEW.attempted_at,
        "completed_at", NEW.completed_at,
        "source", NEW.source,
        "profile", NEW.profile
    );
END;
//

DELIMITER ;

\! echo "Incrementing PacketFence schema version...";
INSERT IGNORE INTO pf_version (id, version) VALUES (@VERSION_INT, CONCAT_WS('.', @MAJOR_VERSION, @MINOR_VERSION, @SUBMINOR_VERSION));

\! echo "Upgrade completed successfully.";
