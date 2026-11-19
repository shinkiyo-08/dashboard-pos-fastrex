/*
 * Salin file ini menjadi config.js, lalu isi dari Supabase Project Settings > API.
 * Publishable/anon key aman digunakan di browser HANYA jika RLS dan policy SQL aktif.
 * Jangan pernah menaruh service_role / secret key di sini.
 */
window.FASTREX_SUPABASE = {
  url: 'https://PROJECT-REF.supabase.co',
  anonKey: 'SUPABASE_PUBLISHABLE_OR_ANON_KEY'
};
