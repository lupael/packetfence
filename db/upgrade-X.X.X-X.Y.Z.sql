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

CREATE FUNCTION IF NOT EXISTS pf_logger RETURNS integer SONAME "pf_udf.so";

DELIMITER /
CREATE OR REPLACE TRIGGER `log_event_auth_log_insert` AFTER INSERT ON `auth_log`
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
/

CREATE OR REPLACE TRIGGER `log_event_admin_api_audit_log_insert` AFTER INSERT ON `admin_api_audit_log`
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
/

CREATE OR REPLACE TRIGGER `log_event_auth_log_update` AFTER UPDATE ON `auth_log`
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
/

CREATE OR REPLACE TRIGGER `log_event_dns_audit_log_insert` AFTER INSERT ON `dns_audit_log`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "dns_audit_log",
        "tenant_id", NEW.tenant_id,
        "created_at", NEW.created_at,
        "ip", NEW.ip,
        "mac", NEW.mac,
        "qname", NEW.qname,
        "qtype", NEW.qtype,
        "scope", NEW.scope,
        "answer", NEW.answer
    );
END;
/

CREATE OR REPLACE TRIGGER `log_event_radius_audit_log_insert` AFTER INSERT ON `radius_audit_log`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "radius_audit_log",
        "tenant_id", NEW.tenant_id,
        "created_at", NEW.created_at,
        "mac", NEW.mac,
        "ip", NEW.ip,
        "computer_name", NEW.computer_name,
        "user_name", NEW.user_name,
        "stripped_user_name", NEW.stripped_user_name,
        "realm", NEW.realm,
        "event_type", NEW.event_type,
        "switch_id", NEW.switch_id,
        "switch_mac", NEW.switch_mac,
        "switch_ip_address", NEW.switch_ip_address,
        "radius_source_ip_address", NEW.radius_source_ip_address,
        "called_station_id", NEW.called_station_id,
        "calling_station_id", NEW.calling_station_id,
        "nas_port_type", NEW.nas_port_type,
        "ssid", NEW.ssid,
        "nas_port_id", NEW.nas_port_id,
        "ifindex", NEW.ifindex,
        "nas_port", NEW.nas_port,
        "connection_type", NEW.connection_type,
        "nas_ip_address", NEW.nas_ip_address,
        "nas_identifier", NEW.nas_identifier,
        "auth_status", NEW.auth_status,
        "reason", NEW.reason,
        "auth_type", NEW.auth_type,
        "eap_type", NEW.eap_type,
        "role", NEW.role,
        "node_status", NEW.node_status,
        "profile", NEW.profile,
        "source", NEW.source,
        "auto_reg", NEW.auto_reg,
        "is_phone", NEW.is_phone,
        "pf_domain", NEW.pf_domain,
        "uuid", NEW.uuid,
        "radius_request", NEW.radius_request,
        "radius_reply", NEW.radius_reply,
        "request_time", NEW.request_time,
        "radius_ip", NEW.radius_ip
    );
END;
/

CREATE OR REPLACE TRIGGER `log_event_dhcp_option82_insert` AFTER INSERT ON `dhcp_option82`
FOR EACH ROW BEGIN
set @k = pf_logger(
        "dhcp_option82",
        "mac", NEW.mac,
        "created_at", NEW.created_at,
        "option82_switch", NEW.option82_switch,
        "switch_id", NEW.switch_id,
        "port", NEW.port,
        "vlan", NEW.vlan,
        "circuit_id_string", NEW.circuit_id_string,
        "module", NEW.module,
        "host", NEW.host
    );
END;
/

CREATE OR REPLACE TRIGGER dhcp_option82_after_update_trigger AFTER UPDATE ON dhcp_option82
FOR EACH ROW
BEGIN
    INSERT INTO dhcp_option82_history
           (
            created_at,
            mac,
            option82_switch,
            switch_id,
            port,
            vlan,
            circuit_id_string,
            module,
            host
           )
    VALUES
           (
            OLD.created_at,
            OLD.mac,
            OLD.option82_switch,
            OLD.switch_id,
            OLD.port,
            OLD.vlan,
            OLD.circuit_id_string,
            OLD.module,
            OLD.host
           );

set @k = pf_logger(
        "dhcp_option82",
        "mac", NEW.mac,
        "created_at", NEW.created_at,
        "option82_switch", NEW.option82_switch,
        "switch_id", NEW.switch_id,
        "port", NEW.port,
        "vlan", NEW.vlan,
        "circuit_id_string", NEW.circuit_id_string,
        "module", NEW.module,
        "host", NEW.host
    );
END;
/
DELIMITER ;

\! echo "Incrementing PacketFence schema version...";
INSERT IGNORE INTO pf_version (id, version) VALUES (@VERSION_INT, CONCAT_WS('.', @MAJOR_VERSION, @MINOR_VERSION, @SUBMINOR_VERSION));

\! echo "Upgrade completed successfully.";
