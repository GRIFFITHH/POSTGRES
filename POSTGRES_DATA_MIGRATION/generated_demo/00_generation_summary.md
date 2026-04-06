# Migration Command Generation Summary
- mapping_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/examples/table_mapping.demo.csv
- fk_edges_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/examples/fk_edges.demo.csv

## target_db=hr_new
- tables: 2
- order_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/generated_demo/01_fk_order_hr_new.txt
- command_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/generated_demo/02_commands_hr_new.sh
- fk_cycle_detected: no

## target_db=sales_new
- tables: 3
- order_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/generated_demo/01_fk_order_sales_new.txt
- command_file: /Users/momoto/PYTHON_AUTOMATION/POSTGRES/POSTGRES_DATA_MIGRATION/generated_demo/02_commands_sales_new.sh
- fk_cycle_detected: no
