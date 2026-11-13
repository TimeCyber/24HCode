-- Read-only diagnostics for the cloud MySQL CodeAssist database.
-- Select the application database before running. No DELETE/ALTER/OPTIMIZE.
SELECT DATABASE() AS current_database, VERSION() AS mysql_version;

SELECT TABLE_NAME, ENGINE, TABLE_ROWS AS estimated_rows,
       ROUND(DATA_LENGTH / 1024 / 1024, 2) AS data_mb,
       ROUND(INDEX_LENGTH / 1024 / 1024, 2) AS index_mb,
       ROUND(DATA_FREE / 1024 / 1024, 2) AS reusable_mb,
       MAX_DATA_LENGTH
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND LEFT(TABLE_NAME, 3) = 'ca_'
ORDER BY DATA_LENGTH + INDEX_LENGTH DESC;

SHOW VARIABLES WHERE Variable_name IN (
  'datadir', 'tmpdir', 'innodb_data_file_path', 'innodb_file_per_table',
  'max_heap_table_size', 'tmp_table_size'
);

SHOW CREATE TABLE ca_task;
SHOW CREATE TABLE ca_prompt;
SHOW CREATE TABLE ca_prompt_delivery;
SHOW INDEX FROM ca_task;
SHOW INDEX FROM ca_prompt;
SHOW INDEX FROM ca_prompt_delivery;

-- Optional on a large production database: these queries scan history.
-- Run after checking disk/quota and the MySQL error log.
-- SELECT status, COUNT(*) AS rows_count, MIN(create_time) AS oldest,
--        MAX(create_time) AS newest FROM ca_task GROUP BY status;
-- SELECT status, COUNT(*) AS rows_count, MIN(create_time) AS oldest,
--        MAX(create_time) AS newest FROM ca_prompt GROUP BY status;
-- SELECT status, COUNT(*) AS rows_count, MIN(create_time) AS oldest,
--        MAX(create_time) AS newest FROM ca_prompt_delivery GROUP BY status;
