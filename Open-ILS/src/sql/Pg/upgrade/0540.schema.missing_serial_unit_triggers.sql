-- Evergreen DB patch 0540.schema.missing_serial_unit_triggers.sql
--
-- Bring serial.unit into line with asset.copy
--
BEGIN;


-- check whether patch can be applied
INSERT INTO config.upgrade_log (version) VALUES ('0540'); -- dbwells

CREATE TRIGGER sunit_status_changed_trig
    BEFORE UPDATE ON serial.unit
    FOR EACH ROW EXECUTE PROCEDURE asset.acp_status_changed();

SELECT auditor.create_auditor ( 'serial', 'unit' );
CREATE INDEX aud_serial_unit_hist_creator_idx      ON auditor.serial_unit_history ( creator );
CREATE INDEX aud_serial_unit_hist_editor_idx       ON auditor.serial_unit_history ( editor );

COMMIT;
