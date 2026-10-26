# Tutorial Deploy Tenangin ke VPS (satu perintah)

Hasil akhir: Laravel + FastAPI + queue worker + MariaDB + nginx (+ SSL) terpasang otomatis di VPS,
mirip `start.cmd` di Windows, hanya satu perintah.

## Kebutuhan

**VPS**
- Ubuntu 22.04 atau 24.04 yang masih bersih, RAM minimal 2 GB, akses `root` lewat SSH.
- (Opsional) Domain yang A record-nya sudah mengarah ke IP VPS. Tanpa domain, situs jalan lewat IP dan HTTP saja.

**Komputer Windows Anda**
- Git dan OpenSSH client (sudah bawaan Windows 10/11).
- Semua kode sudah di-commit. `deploy.cmd` hanya mengirim isi commit terakhir.

## Cara 1 - Dari Windows (paling mudah)

Buka CMD atau PowerShell di folder proyek, lalu:

```cmd
git add -A && git commit -m "siap deploy"
deploy.cmd root@IP_VPS_ANDA tenangin.contoh.com email@anda.com
```

- Domain dan email boleh dikosongkan: `deploy.cmd root@IP_VPS_ANDA`
- Domain **dan** email terisi: SSL Let's Encrypt dipasang otomatis.
- Pertama kali, SSH akan meminta password root (atau pakai SSH key).

Proses sekitar 5-10 menit. Di akhir muncul alamat situs.

## Cara 2 - Langsung di server

```bash
ssh root@IP_VPS_ANDA
git clone <URL_REPO_ANDA> /var/www/tenangin
cd /var/www/tenangin
sudo DOMAIN=tenangin.contoh.com EMAIL=email@anda.com \
     OPENAI_API_KEY=sk-xxxx DEEPGRAM_API_KEY=xxxx \
     bash deploy/install.sh
```

## Yang dikerjakan otomatis

1. Memasang nginx, MariaDB, PHP 8.3, Python 3, Node 20, Composer.
2. Membuat database `tenangin-app` dan user `tenangin` dengan password acak (disimpan di `/root/.tenangin/db_pass`).
3. Laravel: membuat `.env` produksi, `composer install`, `npm ci && npm run build`, `key:generate`, `migrate`, seeder (hanya sekali), `storage:link`, cache config/route/view.
4. FastAPI: membuat virtualenv, memasang `requirements.txt`, membuat `apps/api-ai/.env`.
5. Membuat service systemd `tenangin-api` (FastAPI, port 5000 lokal) dan `tenangin-queue` (queue worker), keduanya hidup otomatis saat reboot.
6. nginx: melayani Laravel, dan meneruskan `/ws/` (WebSocket suara) ke FastAPI.
7. Firewall (hanya SSH, 80, 443) dan SSL jika domain dan email diisi.

## Setelah selesai

1. **Isi API key** (jika belum dikirim lewat variabel):
   ```bash
   nano /var/www/tenangin/apps/api-ai/.env     # OPENAI_API_KEY dan testing_deepgram_tenangin
   systemctl restart tenangin-api
   ```
2. **Ganti password akun bawaan.** Seeder membuat `admin@gmail.com` / `admin` dan `user@gmail.com` / `user`, yang berbahaya di internet. Ganti lewat aplikasi atau tinker:
   ```bash
   cd /var/www/tenangin/apps/core
   sudo -u www-data php artisan tinker
   >>> App\Models\User::where('email','admin@gmail.com')->update(['email'=>'emailanda@domain.com','password'=>Hash::make('PasswordKuat!')]);
   ```
3. Buka `https://tenangin.contoh.com` (atau `http://IP_VPS`).

## Update setelah ada perubahan kode

Commit di Windows, lalu jalankan perintah yang sama:

```cmd
deploy.cmd root@IP_VPS_ANDA tenangin.contoh.com email@anda.com
```

Installer aman dijalankan berulang kali. `.env`, database, dan file upload tidak ditimpa, dan seeder tidak dijalankan lagi.

## Perintah berguna di server

```bash
systemctl status tenangin-api tenangin-queue      # status service
journalctl -u tenangin-api -f                     # log FastAPI
tail -f /var/www/tenangin/apps/core/storage/logs/laravel.log
systemctl restart tenangin-api tenangin-queue     # restart setelah ubah .env
```

## Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| 502 Bad Gateway | `systemctl status php8.3-fpm`, lalu cek `/var/log/nginx/error.log` |
| 500 Server Error | Lihat `storage/logs/laravel.log`. Jalankan `php artisan config:clear` setelah ubah `.env` |
| Fitur AI error | API key belum diisi, atau `journalctl -u tenangin-api -f` |
| Rekam suara tidak jalan | Browser mewajibkan **HTTPS** untuk mikrofon, jadi pakai domain + SSL |
| SSL gagal | Pastikan A record domain sudah mengarah ke IP VPS lalu jalankan ulang |
| Permission error | `chown -R www-data:www-data /var/www/tenangin` |
