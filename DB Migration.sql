  CREATE TABLE "ALL_OBJECT_DDL" 
   (	"ID" NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY MINVALUE 1 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 20 NOORDER  NOCYCLE  NOKEEP  NOSCALE  NOT NULL ENABLE, 
	"OBJECT_NAME" VARCHAR2(1000 CHAR), 
	"OBJECT_TYPE" VARCHAR2(1000 CHAR), 
	"OBJECT_DDL" CLOB, 
	"IS_CREATED" VARCHAR2(100 CHAR) DEFAULT 'N', 
	"CREATE_MANUALLY" VARCHAR2(10), 
	"IS_INSERT_GENERATED" VARCHAR2(100) DEFAULT 'N', 
	"IS_SPECIAL_CASE" VARCHAR2(10) DEFAULT 'N', 
	 CONSTRAINT "ALL_OBJECT_DDL_PK" PRIMARY KEY ("ID")
  USING INDEX  ENABLE
   ) ;



  CREATE TABLE "ALL_TABLE_DML" 
   (	"ID" NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY MINVALUE 1 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 20 NOORDER  NOCYCLE  NOKEEP  NOSCALE  NOT NULL ENABLE, 
	"TABLE_NAME" VARCHAR2(1000 CHAR), 
	"TABLE_DML" CLOB, 
	"IS_INSERTED" VARCHAR2(100 CHAR) DEFAULT 'N', 
	"CREATED_AT" TIMESTAMP (6) DEFAULT current_timestamp, 
	"CREATED_BY" VARCHAR2(1000 CHAR) DEFAULT SYS_CONTEXT('APEX$SESSION','APP_USER'), 
	"UPDATED_BY" VARCHAR2(1000 CHAR), 
	"UPDATED_AT" TIMESTAMP (6), 
	 CONSTRAINT "ALL_TABLE_DML_PK" PRIMARY KEY ("ID")
  USING INDEX  ENABLE
   ) ;


  CREATE TABLE "ALL_DML_TABLE_LOGS" 
   (	"ID" NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY MINVALUE 1 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 20 NOORDER  NOCYCLE  NOKEEP  NOSCALE  NOT NULL ENABLE, 
	"OBJECT_NAME" VARCHAR2(1000 CHAR), 
	"LOGS" CLOB, 
	"IS_FROM_DDL" VARCHAR2(10), 
	 CONSTRAINT "ALL_DML_TABLE_LOGS_PK" PRIMARY KEY ("ID")
  USING INDEX  ENABLE
   ) ;

-- REPORT_CONFIG TABLE
-- ALL_DML_TABLE_LOGS
-- ALL_OBJECT_DDL
-- ALL_TABLE_DML


create or replace PROCEDURE SP_DML_MIGRATION_SCRIPT
(
    p_table_name IN varchar2 default null
)
IS
    v_error_log clob;
BEGIN
    FOR TBL_DML IN(SELECT ID, TABLE_DML, TABLE_NAME FROM ALL_TABLE_DML WHERE (p_table_name IS NULL OR TABLE_NAME = p_table_name))
    LOOP
        BEGIN
            EXECUTE IMMEDIATE TBL_DML.TABLE_DML;

            UPDATE ALL_TABLE_DML SET IS_INSERTED = 'Y' WHERE ID = TBL_DML.ID;
        EXCEPTION WHEN OTHERS
            THEN
                v_error_log := 'Error for id '|| TBL_DML.ID || ' : '|| SQLERRM;

                INSERT INTO ALL_DML_TABLE_LOGS(OBJECT_NAME,LOGS,IS_FROM_DDL)
                VALUES(TBL_DML.TABLE_NAME, v_error_log,'From DML');
        END;
    END LOOP; 
end;
/




create or replace PROCEDURE SP_DATA_INGESTION_SCRIPT
(
    p_table_name IN varchar2 default null
)
IS
    v_all_cols clob := '';
    v_all_cols_with_replace clob := '';
    v_insert_into clob;
    -- TYPE t_table_data IS TABLE OF clob;
    -- table_data   t_table_data;
    v_all_insert_stmnts clob;
    v_query clob;
    v_tbl_row_cnt number;
    v_rows_per_page CONSTANT number := 10;
    v_batch_no number := 1;
    v_offset number := 0;
    v_error_log clob;
    v_first_col_name varchar2(4000);
BEGIN
    for all_tables in (
        select * from ALL_OBJECT_DDL where OBJECT_TYPE = 'TABLE'
        and (p_table_name is null or ALL_OBJECT_DDL.OBJECT_NAME = p_table_name)
        AND IS_INSERT_GENERATED != 'Y'
        and ALL_OBJECT_DDL.IS_SPECIAL_CASE = 'N'
        
    )
    loop
        begin
            EXECUTE IMMEDIATE 'select count(*) from ' || all_tables.OBJECT_NAME INTO v_tbl_row_cnt;
        EXCEPTION WHEN OTHERS
            THEN
                DBMS_OUTPUT.PUT_LINE('ERROR : ' || SQLERRM);
        end;

        IF v_tbl_row_cnt > 0
            THEN

            BEGIN
                SELECT LISTAGG(COLUMN_NAME,',') WITHIN GROUP(ORDER BY COLUMN_ID)  AS COLUMN_NAMES INTO v_all_cols FROM ALL_TAB_COLUMNS
                WHERE TABLE_NAME = all_tables.OBJECT_NAME;

                SELECT COLUMN_NAME INTO v_first_col_name FROM ALL_TAB_COLUMNS WHERE TABLE_NAME = all_tables.OBJECT_NAME AND COLUMN_ID = 1;
            EXCEPTION WHEN OTHERS
                THEN
                    DBMS_OUTPUT.PUT_LINE('Error for ' || all_tables.OBJECT_NAME || ' in line 39 : ' || SQLERRM);
            END;

            v_insert_into := 'INSERT INTO '||all_tables.OBJECT_NAME||'('||v_all_cols||')';

            SELECT REPLACE(v_all_cols, ',', '|| '','' ||' ) INTO v_all_cols_with_replace FROM DUAL;
            
            IF v_tbl_row_cnt > v_rows_per_page
                THEN

                WHILE v_offset < v_tbl_row_cnt
                    LOOP

                    v_query := '
                    SELECT 
                        REPLACE(REPLACE(REPLACE(LISTAGG(' || v_all_cols_with_replace || ', '';'' ) 
                        WITHIN GROUP (ORDER BY ' || v_first_col_name || '), '','', '''''',''''''), '';'', '''''';''''''), '';'', ''); 
                        INSERT INTO '|| all_tables.OBJECT_NAME ||'(' || v_all_cols || ') VALUES('') AS all_columns_agg
                    FROM (SELECT * FROM ' || all_tables.OBJECT_NAME || ' ORDER BY ' || v_first_col_name || ' OFFSET '|| v_offset || 'ROWS FETCH NEXT ' || v_rows_per_page || 'ROWS ONLY)';

                    BEGIN
                        EXECUTE IMMEDIATE v_query
                        INTO v_all_insert_stmnts;
                    EXCEPTION WHEN OTHERS THEN
                        DBMS_OUTPUT.PUT_LINE('Error for ' || all_tables.OBJECT_NAME || ' ' || SQLERRM);
                    END;

                    v_all_insert_stmnts := v_insert_into || ' VALUES(''' || v_all_insert_stmnts || ''');';

                    BEGIN

                        INSERT INTO ALL_TABLE_DML(TABLE_NAME,TABLE_DML)
                        VALUES(all_tables.OBJECT_NAME,v_all_insert_stmnts);

                        UPDATE ALL_OBJECT_DDL SET IS_INSERT_GENERATED = 'Y' WHERE ID = all_tables.ID; -- update the table and set the is generated column as Y

                        v_batch_no := v_batch_no + 1;

                        v_offset := (v_batch_no - 1) * v_rows_per_page;

                    EXCEPTION WHEN OTHERS THEN
                        
                        v_error_log := 'Error : ' || SQLERRM;

                        INSERT INTO ALL_DML_TABLE_LOGS(OBJECT_NAME,LOGS)
                        VALUES(all_tables.OBJECT_NAME, v_error_log);
                    END
                    COMMIT;
                END LOOP;
            
            ELSE

                v_query := '
                SELECT 
                    REPLACE(REPLACE(REPLACE(LISTAGG(' || v_all_cols_with_replace || ', '';'' ) 
                    WITHIN GROUP (ORDER BY ' || v_first_col_name || '), '','', '''''',''''''), '';'', '''''';''''''), '';'', ''); 
                    INSERT INTO '|| all_tables.OBJECT_NAME ||'(' || v_all_cols || ') VALUES('') AS all_columns_agg
                FROM (SELECT * FROM ' || all_tables.OBJECT_NAME || ' ORDER BY ' || v_first_col_name || ')';

                BEGIN
                    EXECUTE IMMEDIATE v_query
                    INTO v_all_insert_stmnts;
                EXCEPTION WHEN OTHERS THEN

                    DBMS_OUTPUT.PUT_LINE('Error for ' || all_tables.OBJECT_NAME || ' ' || SQLERRM);
                END;

                v_all_insert_stmnts := v_insert_into || ' VALUES(''' || v_all_insert_stmnts || ''');';

                BEGIN

                    INSERT INTO ALL_TABLE_DML(TABLE_NAME,TABLE_DML)
                    VALUES(all_tables.OBJECT_NAME,v_all_insert_stmnts);

                    UPDATE ALL_OBJECT_DDL SET IS_INSERT_GENERATED = 'Y' WHERE ID = all_tables.ID; -- update the table and set the is generated column as Y

                EXCEPTION WHEN OTHERS THEN

                    v_error_log := 'Error : ' || SQLERRM;

                    INSERT INTO ALL_DML_TABLE_LOGS(OBJECT_NAME,LOGS)
                    VALUES(all_tables.OBJECT_NAME, v_error_log);
                END;

                COMMIT;

            END IF;

        END IF;

    end loop;

END;
/
