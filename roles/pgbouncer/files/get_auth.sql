CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE (usename name, passwd text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
  -- pgc get_auth v1
  -- Called by pgbouncer (auth_query). Never returns superusers or expired roles.
  SELECT s.usename, s.passwd
  FROM pg_catalog.pg_shadow s
  WHERE s.usename = p_usename
    AND NOT s.usesuper
    AND (s.valuntil IS NULL OR s.valuntil > now());
$fn$;
