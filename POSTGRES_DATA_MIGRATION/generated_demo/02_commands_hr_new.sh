#!/usr/bin/env bash
set -euo pipefail

# Generated non-destructive data migration commands
# - Source side: read only
# - Target side: insert only
# - No TRUNCATE/DELETE/ALTER/DROP emitted

# legacy_hr.hr.employees -> hr_new.hr_mig.employee_master
psql "host=172.30.72.162 port=5432 dbname=legacy_hr user=postgres" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "hr"."employees" WHERE active = true) TO STDOUT WITH (FORMAT csv)' | psql "host=10.10.11.11 port=5432 dbname=hr_new user=postgres" -v ON_ERROR_STOP=1 -c '\COPY "hr_mig"."employee_master" FROM STDIN WITH (FORMAT csv)'

# legacy_hr.hr.employee_salary -> hr_new.hr_mig.employee_salary_hist
psql "host=172.30.72.162 port=5432 dbname=legacy_hr user=postgres" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "hr"."employee_salary") TO STDOUT WITH (FORMAT csv)' | psql "host=10.10.11.11 port=5432 dbname=hr_new user=postgres" -v ON_ERROR_STOP=1 -c '\COPY "hr_mig"."employee_salary_hist" FROM STDIN WITH (FORMAT csv)'
