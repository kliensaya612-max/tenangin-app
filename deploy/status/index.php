<?php
/**
 * Tenangin - halaman status layanan (berdiri sendiri, TIDAK memakai Laravel,
 * supaya tetap bisa tampil walaupun Laravel / database yang bermasalah).
 *
 * Halaman ini PUBLIK, jadi hanya menampilkan nama layanan dan status UP / DOWN.
 * Tidak ada versi, nama database, path, pesan error, angka, atau detail internal.
 *
 *   /             -> halaman HTML
 *   /?format=json -> JSON (untuk UptimeRobot dll). HTTP 503 jika ada layanan DOWN.
 */
header_remove('X-Powered-By');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex');
header('X-Content-Type-Options: nosniff');

$root = dirname(__DIR__, 2);
$core = "$root/apps/core";
$api  = "$root/apps/api-ai";

function envFile(string $path): array {
    $out = [];
    foreach (@file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        if ($line[0] === '#' || !str_contains($line, '=')) continue;
        [$k, $v] = explode('=', $line, 2);
        $out[trim($k)] = trim($v, " \t\"'");
    }
    return $out;
}
$env    = envFile("$core/.env");
$apiEnv = envFile("$api/.env");
$host   = parse_url($env['APP_URL'] ?? '', PHP_URL_HOST) ?: 'localhost';
$https  = (parse_url($env['APP_URL'] ?? '', PHP_URL_SCHEME) === 'https');

$checks = [];
function add(string $name, bool $up): void {
    global $checks;
    $checks[] = ['name' => $name, 'status' => $up ? 'up' : 'down'];
}
function svc(string $unit): bool {
    return trim((string) shell_exec('systemctl is-active ' . escapeshellarg($unit) . ' 2>/dev/null')) === 'active';
}
function httpCode(string $url, array $opt = []): int {
    $ch = curl_init($url);
    curl_setopt_array($ch, $opt + [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 5, CURLOPT_CONNECTTIMEOUT => 3]);
    curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return $code;
}

// Web server & PHP
add('Web server', svc('nginx'));
add('PHP', svc('php' . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '-fpm'));

// Database
try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%s;dbname=%s', $env['DB_HOST'] ?? '127.0.0.1', $env['DB_PORT'] ?? 3306, $env['DB_DATABASE'] ?? ''),
        $env['DB_USERNAME'] ?? '', $env['DB_PASSWORD'] ?? '',
        [PDO::ATTR_TIMEOUT => 3, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $pdo->query('SELECT 1');
    add('Database', true);
} catch (Throwable $e) {
    add('Database', false);
}

// Aplikasi (diuji lewat nginx lokal, termasuk verifikasi SSL)
$opt = $https ? [CURLOPT_RESOLVE => ["$host:443:127.0.0.1"]] : [CURLOPT_RESOLVE => ["$host:80:127.0.0.1"]];
add('Aplikasi', httpCode(($https ? 'https' : 'http') . "://$host/login", $opt) === 200);

// AI & suara
add('Layanan AI', svc('tenangin-api') && httpCode('http://127.0.0.1:5000/docs') === 200);

// Antrean
add('Antrean', svc('tenangin-queue'));

// Kunci API (hanya terisi / belum, isinya tidak pernah ditampilkan)
$oa = $apiEnv['OPENAI_API_KEY'] ?? '';
$dg = $apiEnv['testing_deepgram_tenangin'] ?? '';
add('Analisis AI', $oa !== '' && !str_contains($oa, 'ISI-API-KEY'));
add('Rekam suara', $dg !== '');

// Sertifikat SSL
if ($https) {
    $ctx = stream_context_create(['ssl' => ['capture_peer_cert' => true, 'verify_peer' => false, 'SNI_enabled' => true, 'peer_name' => $host]]);
    $fp = @stream_socket_client('ssl://127.0.0.1:443', $en, $es, 3, STREAM_CLIENT_CONNECT, $ctx);
    $cert = $fp ? (stream_context_get_params($fp)['options']['ssl']['peer_certificate'] ?? null) : null;
    $days = $cert ? (int) floor((openssl_x509_parse($cert)['validTo_time_t'] - time()) / 86400) : -1;
    add('Sertifikat SSL', $days >= 7);
}

// Disk & memori
add('Disk', (1 - disk_free_space('/') / disk_total_space('/')) < 0.95);
$mi = @file_get_contents('/proc/meminfo') ?: '';
if (preg_match('/MemTotal:\s+(\d+)/', $mi, $a) && preg_match('/MemAvailable:\s+(\d+)/', $mi, $b)) {
    add('Memori', $b[1] / $a[1] >= 0.05);
}

$down = array_values(array_map(fn($c) => $c['name'], array_filter($checks, fn($c) => $c['status'] === 'down')));
$overall = $down ? 'down' : 'up';
http_response_code($down ? 503 : 200);

if (($_GET['format'] ?? '') === 'json' || str_contains($_SERVER['HTTP_ACCEPT'] ?? '', 'application/json')) {
    header('Content-Type: application/json');
    echo json_encode(['status' => $overall, 'down' => $down, 'checked_at' => date('c'), 'services' => $checks], JSON_UNESCAPED_UNICODE);
    exit;
}

$h = fn($s) => htmlspecialchars((string) $s, ENT_QUOTES);
?><!doctype html>
<html lang="id">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<meta name="robots" content="noindex">
<title>Status Tenangin</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--text:#1d2433;--muted:#667085;--line:#e4e7ec;--up:#12a150;--down:#d92d20}
@media(prefers-color-scheme:dark){:root{--bg:#10141c;--card:#181e29;--text:#e8ecf3;--muted:#9aa4b5;--line:#2a3342}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,sans-serif}
main{max-width:640px;margin:0 auto;padding:32px 16px}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
.banner{padding:16px 18px;border-radius:12px;color:#fff;font-weight:600;margin-bottom:20px}
.banner.up{background:var(--up)}.banner.down{background:var(--down)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.row{display:flex;gap:12px;align-items:center;padding:14px 18px;border-bottom:1px solid var(--line)}
.row:last-child{border:0}.dot{width:10px;height:10px;border-radius:50%;flex:none}
.dot.up{background:var(--up)}.dot.down{background:var(--down)}
.name{font-weight:600}.badge{margin-left:auto;font-size:12px;font-weight:700;letter-spacing:.04em}
.badge.up{color:var(--up)}.badge.down{color:var(--down)}
</style>
</head>
<body>
<main>
  <h1>Status Tenangin</h1>
  <div class="sub"><?= $h($host) ?> · dicek <?= date('d M Y H:i:s') ?> · refresh otomatis 30 dtk</div>
  <div class="banner <?= $overall ?>"><?= $down ? 'Ada layanan bermasalah: ' . $h(implode(', ', $down)) : 'Semua layanan normal' ?></div>
  <div class="card">
    <?php foreach ($checks as $c): ?>
    <div class="row">
      <span class="dot <?= $c['status'] ?>"></span>
      <div class="name"><?= $h($c['name']) ?></div>
      <div class="badge <?= $c['status'] ?>"><?= strtoupper($c['status']) ?></div>
    </div>
    <?php endforeach; ?>
  </div>
</main>
</body>
</html>
