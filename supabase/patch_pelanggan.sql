-- Patch sekali jalan: mengizinkan peran kasir menyimpan data pelanggan (kunci 'cust').
-- Aman untuk data yang sudah ada. Jalankan di Supabase SQL Editor.
do $$
declare d text; o text;
begin
  select pg_get_functiondef('public.save_fastrex_state(jsonb,bigint)'::regprocedure) into d;
  o := d;
  d := replace(d, $q$(p_state - 'notas' - 'mats' - 'prods' - 'exp')$q$, $q$(p_state - 'notas' - 'mats' - 'prods' - 'exp' - 'cust')$q$);
  d := replace(d, $q$(v_row.state - 'notas' - 'mats' - 'prods' - 'exp')$q$, $q$(v_row.state - 'notas' - 'mats' - 'prods' - 'exp' - 'cust')$q$);
  d := replace(d, $q$      'notas',v_notes
    );$q$, $q$      'notas',v_notes,
      'cust',coalesce(p_state->'cust',v_row.state->'cust','[]'::jsonb)
    );$q$);
  if d = o then raise exception 'Patch tidak cocok: fungsi sudah dipatch atau berbeda'; end if;
  execute d;
end $$;
