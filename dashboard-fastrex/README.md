# Fastrex Print Suite — Supabase Cloud Edition

Aplikasi HTML + CSS + Vanilla JavaScript. Data operasional tidak lagi memakai `localStorage`; seluruh data POS disimpan di Supabase PostgreSQL. Token login Supabase disimpan di `sessionStorage` pada tab browser.
Autentikasi menggunakan Supabase Auth, penyimpanan menggunakan PostgreSQL (satu dokumen JSONB
untuk menjaga struktur aplikasi saat ini), dan sinkronisasi menggunakan Supabase Realtime private Broadcast.

## File penting

- `index.html` — halaman login dan shell aplikasi.
- `js/app.js` — fitur POS yang sudah ada + login, penyimpanan cloud, dan realtime.
- `js/config.example.js` — contoh konfigurasi Supabase.
- `supabase/setup.sql` — skema, RLS, RPC penyimpanan, dan state awal kosong.

## 1. Siapkan Supabase

1. Buat project di https://supabase.com/dashboard.
2. Buka **SQL Editor** dan jalankan seluruh isi `supabase/setup.sql`.
3. Buka **Project Settings → API** (atau Data API / API Keys pada dashboard baru).
4. Salin Project URL dan **publishable key** (atau anon key lama). Jangan pernah memakai `service_role` / secret key di browser.
5. Buka `js/config.js` dan isi `url` dan `anonKey`. File ini sudah disertakan dengan placeholder.
6. Di Supabase **Project Settings → API**, gunakan Project URL dan publishable key (atau anon key lama).
7. Tidak perlu mengaktifkan publikasi tabel; realtime menggunakan private Broadcast.

Contoh `js/config.js`:

```js
window.FASTREX_SUPABASE = {
  url: 'https://xxxxxxxx.supabase.co',
  anonKey: 'sb_publishable_...'
};
```

`config.js` berisi publishable/anon key yang memang digunakan browser. Keamanan data bergantung pada RLS dan RPC di `setup.sql`; role kasir menerima state yang sudah disanitasi, sedangkan broadcast realtime hanya mengirim nomor versi dan ID pengguna.

## 2. Buat akun admin pertama

1. Di Supabase, buka **Authentication → Users → Add user**.
2. Buat akun admin dengan email dan password yang akan digunakan untuk login Fastrex.
3. Salin UUID user tersebut.
4. Jalankan SQL berikut di SQL Editor, ganti UUID dan nama:

```sql
insert into public.profiles (id, role, display_name)
values ('UUID_USER_ADMIN', 'admin', 'Admin Fastrex');
```

## 3. Buat akun kasir

Untuk setiap kasir:

1. Tambahkan user baru di **Authentication → Users → Add user**.
2. Salin UUID user.
3. Jalankan:

```sql
insert into public.profiles (id, role, display_name)
values ('UUID_USER_KASIR', 'cashier', 'Nama Kasir');
```

Pendaftaran publik tidak disediakan. Hanya akun yang dibuat admin Supabase dan diberi profil yang dapat masuk.

## 4. Hosting gratis dengan GitHub Pages

1. Buat repository GitHub **Public** bernama `fastrex-pos`.
2. Upload isi folder proyek ini ke root repository.
3. Pastikan `index.html`, `css/`, `img/`, `js/`, dan `supabase/` berada di root.
4. Isi `js/config.js` sebelum upload. Publishable/anon key boleh ada di frontend; jangan pernah mengunggah `service_role` atau secret key.
5. Buka **Settings → Pages → Deploy from a branch → main → /(root) → Save**.
6. Buka URL yang diberikan GitHub Pages.

GitHub Pages hanya hosting file statis. Database dan login berjalan di Supabase.

## 5. Perilaku role

- **Admin:** akses semua menu, harga/HPP, stok, kas, pengaturan, backup dan restore.
- **Kasir:** akses dashboard, nota/invoice, dan melihat stok. Kasir dapat membuat/memperbarui nota; database mengizinkan perubahan stok yang timbul dari transaksi, tetapi menolak perubahan katalog, harga, pengaturan, dan pengeluaran.
- Pembatasan peran ditegakkan ulang di database melalui RPC, bukan hanya menyembunyikan menu.

## Catatan penting sebelum dipakai operasional

- Database awal sengaja kosong: katalog produk, bahan, nota, dan pengeluaran harus diisi admin.
- Realtime menyebarkan perubahan setelah server menyimpan data.
- Penyimpanan memakai satu dokumen JSONB dengan nomor versi. Jika dua perangkat menyimpan pada saat bersamaan, satu perubahan bisa ditolak dengan pesan konflik; muat ulang dan ulangi perubahan. Ini mencegah perubahan saling menimpa diam-diam, tetapi belum setara sistem transaksi multi-tabel dengan merge otomatis.
- Gunakan menu Backup JSON secara berkala dan simpan backup di tempat aman.
- Akun kasir dapat mengubah nota yang tersedia di aplikasi. Jangan bagikan akun admin kepada kasir.
- Sebelum pemakaian produksi, uji skenario dua kasir bersamaan, pembayaran, stok, cetak nota, restore backup, dan hak akses.


### Update app.js terbaru
Versi ini sudah menggabungkan pembaruan `app.js` yang dilampirkan: produk di menu Harga & Kalkulator dapat diurutkan dengan drag-and-drop atau tombol naik/turun. Urutan tersimpan ke database cloud melalui mekanisme penyimpanan Supabase yang sudah disiapkan.
