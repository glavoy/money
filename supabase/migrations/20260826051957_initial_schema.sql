


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."money_stamp_server_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return old;
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;


ALTER FUNCTION "public"."money_stamp_server_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."accounts" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "currency" "text" NOT NULL,
    "opening_balance" double precision DEFAULT 0 NOT NULL,
    "opening_date" timestamp with time zone,
    "archived" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "ledger_id" "text" DEFAULT 'ledger-personal'::"text" NOT NULL,
    "server_updated_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL
);


ALTER TABLE "public"."accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "color" bigint,
    "archived" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "ledger_id" "text" DEFAULT 'ledger-personal'::"text" NOT NULL,
    "server_updated_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fx_rates" (
    "id" "text" NOT NULL,
    "date" timestamp with time zone NOT NULL,
    "usd_ugx" double precision,
    "cad_ugx" double precision,
    "usd_cad" double precision,
    "source" "text" DEFAULT 'api'::"text" NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "server_updated_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL
);


ALTER TABLE "public"."fx_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ledgers" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "archived" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "server_updated_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL
);


ALTER TABLE "public"."ledgers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "text" NOT NULL,
    "date" timestamp with time zone NOT NULL,
    "kind" "text" NOT NULL,
    "amount" double precision NOT NULL,
    "account_id" "text" NOT NULL,
    "category_id" "text",
    "to_account_id" "text",
    "to_amount" double precision,
    "note" "text",
    "created_at" timestamp with time zone NOT NULL,
    "updated_at" timestamp with time zone NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "ledger_id" "text" DEFAULT 'ledger-personal'::"text" NOT NULL,
    "server_updated_at" timestamp with time zone DEFAULT "clock_timestamp"() NOT NULL,
    "exclude_from_report" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fx_rates"
    ADD CONSTRAINT "fx_rates_date_key" UNIQUE ("date");



ALTER TABLE ONLY "public"."fx_rates"
    ADD CONSTRAINT "fx_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ledgers"
    ADD CONSTRAINT "ledgers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "accounts_ledger_id_idx" ON "public"."accounts" USING "btree" ("ledger_id");



CREATE INDEX "accounts_server_updated_at_idx" ON "public"."accounts" USING "btree" ("server_updated_at");



CREATE INDEX "categories_ledger_id_idx" ON "public"."categories" USING "btree" ("ledger_id");



CREATE INDEX "categories_server_updated_at_idx" ON "public"."categories" USING "btree" ("server_updated_at");



CREATE INDEX "fx_rates_server_updated_at_idx" ON "public"."fx_rates" USING "btree" ("server_updated_at");



CREATE INDEX "fx_rates_updated_at_idx" ON "public"."fx_rates" USING "btree" ("updated_at");



CREATE INDEX "ledgers_server_updated_at_idx" ON "public"."ledgers" USING "btree" ("server_updated_at");



CREATE INDEX "transactions_date_idx" ON "public"."transactions" USING "btree" ("date");



CREATE INDEX "transactions_ledger_id_idx" ON "public"."transactions" USING "btree" ("ledger_id");



CREATE INDEX "transactions_server_updated_at_idx" ON "public"."transactions" USING "btree" ("server_updated_at");



CREATE INDEX "transactions_updated_at_idx" ON "public"."transactions" USING "btree" ("updated_at");



CREATE OR REPLACE TRIGGER "accounts_stamp_server_updated_at" BEFORE INSERT OR UPDATE ON "public"."accounts" FOR EACH ROW EXECUTE FUNCTION "public"."money_stamp_server_updated_at"();



CREATE OR REPLACE TRIGGER "categories_stamp_server_updated_at" BEFORE INSERT OR UPDATE ON "public"."categories" FOR EACH ROW EXECUTE FUNCTION "public"."money_stamp_server_updated_at"();



CREATE OR REPLACE TRIGGER "fx_rates_stamp_server_updated_at" BEFORE INSERT OR UPDATE ON "public"."fx_rates" FOR EACH ROW EXECUTE FUNCTION "public"."money_stamp_server_updated_at"();



CREATE OR REPLACE TRIGGER "ledgers_stamp_server_updated_at" BEFORE INSERT OR UPDATE ON "public"."ledgers" FOR EACH ROW EXECUTE FUNCTION "public"."money_stamp_server_updated_at"();



CREATE OR REPLACE TRIGGER "transactions_stamp_server_updated_at" BEFORE INSERT OR UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."money_stamp_server_updated_at"();



ALTER TABLE "public"."accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "authenticated full access" ON "public"."accounts" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated full access" ON "public"."categories" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated full access" ON "public"."fx_rates" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated full access" ON "public"."ledgers" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated full access" ON "public"."transactions" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fx_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ledgers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."money_stamp_server_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."money_stamp_server_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."money_stamp_server_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";


















GRANT ALL ON TABLE "public"."accounts" TO "anon";
GRANT ALL ON TABLE "public"."accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."accounts" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON TABLE "public"."fx_rates" TO "anon";
GRANT ALL ON TABLE "public"."fx_rates" TO "authenticated";
GRANT ALL ON TABLE "public"."fx_rates" TO "service_role";



GRANT ALL ON TABLE "public"."ledgers" TO "anon";
GRANT ALL ON TABLE "public"."ledgers" TO "authenticated";
GRANT ALL ON TABLE "public"."ledgers" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































drop extension if exists "pg_net";


