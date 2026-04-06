#!/usr/bin/env bash
set -euo pipefail

# Generated non-destructive data migration commands
# - Source side: read only
# - Target side: insert only
# - No TRUNCATE/DELETE/ALTER/DROP emitted

# legacy_sales.public.customers -> sales_new.sales_mig.customer_master
psql "host=10.10.1.11 port=5432 dbname=legacy_sales user=asis_ro" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "public"."customers") TO STDOUT WITH (FORMAT csv)' | psql "host=10.20.2.21 port=5432 dbname=sales_new user=tobe_loader" -v ON_ERROR_STOP=1 -c '\COPY "sales_mig"."customer_master" FROM STDIN WITH (FORMAT csv)'

# legacy_sales.public.orders -> sales_new.sales_mig.order_fact
psql "host=10.10.1.11 port=5432 dbname=legacy_sales user=asis_ro" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "public"."orders") TO STDOUT WITH (FORMAT csv)' | psql "host=10.20.2.21 port=5432 dbname=sales_new user=tobe_loader" -v ON_ERROR_STOP=1 -c '\COPY "sales_mig"."order_fact" FROM STDIN WITH (FORMAT csv)'

# legacy_sales.public.order_items -> sales_new.sales_mig.order_item_fact
psql "host=10.10.1.11 port=5432 dbname=legacy_sales user=asis_ro" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "public"."order_items") TO STDOUT WITH (FORMAT csv)' | psql "host=10.20.2.21 port=5432 dbname=sales_new user=tobe_loader" -v ON_ERROR_STOP=1 -c '\COPY "sales_mig"."order_item_fact" FROM STDIN WITH (FORMAT csv)'
