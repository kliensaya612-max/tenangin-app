<?php
/**
 * Tenangin - halaman status layanan (berdiri sendiri, TIDAK memakai Laravel,
 * supaya tetap bisa tampil walaupun Laravel / database yang bermasalah).
 *
 *   /            -> halaman HTML
 *   /?format=json -> JSON (untuk UptimeRobot dll). HTTP 503 jika ada layanan DOWN.
 */
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex');

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
function add(string $key, string $name, string $status, string $detail, ?int $ms = null): void {
    global $checks;
    $checks[] = ['key' => $key, 'name' => $name, 'status' => $status, 'detail' => $detail, 'ms' => $ms];
}
function svc(string $unit): bool {
    return trim((string) shell_exec('systemctl is-active ' . escapeshellarg($unit) . ' 2>/dev/null')) === 'active';
}
function http(string $url, array $opt = []): array {
    $t = microtime(true);
    $ch = curl_init($url);
    curl_setopt_array($ch, $opt + [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 5,
        CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_NOBODY => false]);
    curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);
    return [$code, $err, (int) round((microtime(true) - $t) * 1000)];
}

// 1. nginx + php-fpm (kalau halaman ini tampil, keduanya jelas hidup; cek unitnya tetap)
$phpUnit = 'php' . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '-fpm';
add('nginx', 'Web server (nginx)', svc('nginx') ? 'ok' : 'down', svc('nginx') ? 'berjalan' : 'service nginx mati');
add('php', 'PHP-FPM', svc($phpUnit) ? 'ok' : 'down', svc($phpUnit) ? "$phpUnit berjalan" : "$phpUnit mati");

// 2. Database
$t = microtime(true);
try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%s;dbname=%s', $env['DB_HOST'] ?? '127.0.0.1', $env['DB_PORT'] ?? 3306, $env['DB_DATABASE'] ?? ''),
        $env['DB_USERNAME'] ?? '', $env['DB_PASSWORD'] ?? '',
        [PDO::ATTR_TIMEOUT => 3, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $pdo->query('SELECT 1');
    add('db', 'Database (MySQL)', 'ok', 'koneksi berhasil, database ' . ($env['DB_DATABASE'] ?? '?'), (int) round((microtime(true) - $t) * 1000));
} catch (Throwable $e) {
    $pdo = null;
    add('db', 'Database (MySQL)', 'down', 'gagal konek: ' . substr($e->getMessage(), 0, 120));
}

// 3. Aplikasi Laravel (diuji lewat nginx lokal + verifikasi SSL sungguhan)
$url = ($https ? 'https' : 'http') . "://$host/login";
$opt = $https ? [CURLOPT_RESOLVE => ["$host:443:127.0.0.1"]] : [CURLOPT_RESOLVE => ["$host:80:127.0.0.1"]];
[$code, $err, $ms] = http($url, $opt);
add('app', 'Aplikasi Laravel', $code === 200 ? 'ok' : 'down',
    $code === 200 ? 'halaman login merespons 200' : ($code ? "HTTP $code pada /login (cek storage/logs/laravel.log)" : "tidak merespons: $err"), $ms);

// 4. FastAPI (AI & suara)
$apiUp = svc('tenangin-api');
[$code, $err, $ms] = http('http://127.0.0.1:5000/docs');
if (!$apiUp)            add('api', 'FastAPI (AI & suara)', 'down', 'service tenangin-api mati: systemctl restart tenangin-api');
elseif ($code !== 200)  add('api', 'FastAPI (AI & suara)', 'down', 'service hidup tapi tidak merespons' . ($err ? ": $err" : " (HTTP $code)"), $ms);
else                    add('api', 'FastAPI (AI & suara)', 'ok', 'merespons 200', $ms);

// 5. Kunci API pihak ketiga
$oa = $apiEnv['OPENAI_API_KEY'] ?? '';
add('openai', 'OpenAI API key', ($oa === '' || str_contains($oa, 'ISI-API-KEY')) ? 'warn' : 'ok',
    ($oa === '' || str_contains($oa, 'ISI-API-KEY')) ? 'belum diisi di apps/api-ai/.env' : 'terisi (validitas tidak diuji)');
$dg = $apiEnv['testing_deepgram_tenangin'] ?? '';
add('deepgram', 'Deepgram API key', $dg === '' ? 'warn' : 'ok',
    $dg === '' ? 'belum diisi di apps/api-ai/.env (rekam suara tidak jalan)' : 'terisi (validitas tidak diuji)');

// 6. Queue worker + antrean
$qUp = svc('tenangin-queue');
$detail = $qUp ? 'worker berjalan' : 'service tenangin-queue mati: systemctl restart tenangin-queue';
$status = $qUp ? 'ok' : 'down';
if ($pdo) {
    try {
        $pending = (int) $pdo->query('SELECT COUNT(*) FROM jobs')->fetchColumn();
        $failed  = (int) $pdo->query('SELECT COUNT(*) FROM failed_jobs')->fetchColumn();
        $detail .= ", antrean $pending, gagal $failed";
        if ($qUp && ($failed > 0 || $pending > 100)) $status = 'warn';
    } catch (Throwable $e) { /* tabel belum ada */ }
}
add('queue', 'Queue worker', $status, $detail);

// 7. Sertifikat SSL
if ($https) {
    $ctx = stream_context_create(['ssl' => ['capture_peer_cert' => true, 'verify_peer' => false, 'SNI_enabled' => true, 'peer_name' => $host]]);
    $fp = @stream_socket_client("ssl://127.0.0.1:443", $en, $es, 3, STREAM_CLIENT_CONNECT, $ctx);
    $cert = $fp ? stream_context_get_params($fp)['options']['ssl']['peer_certificate'] ?? null : null;
    if ($cert) {
        $days = (int) floor((openssl_x509_parse($cert)['validTo_time_t'] - time()) / 86400);
        add('ssl', 'Sertifikat SSL', $days < 7 ? 'down' : ($days < 21 ? 'warn' : 'ok'), "berlaku $days hari lagi");
    } else {
        add('ssl', 'Sertifikat SSL', 'down', 'tidak bisa membaca sertifikat di port 443');
    }
}

// 8. Disk & memori
$free = disk_free_space('/'); $total = disk_total_space('/');
$usedPct = (int) round(100 - $free / $total * 100);
add('disk', 'Disk', $usedPct >= 95 ? 'down' : ($usedPct >= 85 ? 'warn' : 'ok'), "terpakai $usedPct% (sisa " . round($free / 1073741824, 1) . ' GB)');
$mi = @file_get_contents('/proc/meminfo') ?: '';
if (preg_match('/MemTotal:\s+(\d+)/', $mi, $a) && preg_match('/MemAvailable:\s+(\d+)/', $mi, $b)) {
    $availPct = (int) round($b[1] / $a[1] * 100);
    add('mem', 'Memori', $availPct < 5 ? 'down' : ($availPct < 10 ? 'warn' : 'ok'), "tersedia $availPct% (" . round($b[1] / 1048576, 1) . ' GB)');
}

$overall = 'ok';
foreach ($checks as $c) {
    if ($c['status'] === 'down') { $overall = 'down'; break; }
    if ($c['status'] === 'warn') $overall = 'warn';
}
$down = array_values(array_map(fn($c) => $c['name'], array_filter($checks, fn($c) => $c['status'] === 'down')));
http_response_code($overall === 'down' ? 503 : 200);

if (($_GET['format'] ?? '') === 'json' || str_contains($_SERVER['HTTP_ACCEPT'] ?? '', 'application/json')) {
    header('Content-Type: application/json');
    echo json_encode(['status' => $overall, 'down' => $down, 'checked_at' => date('c'), 'checks' => $checks], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);
    exit;
}

$label = ['ok' => 'Semua layanan normal', 'warn' => 'Ada peringatan', 'down' => 'Ada layanan bermasalah'];
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
:root{--bg:#f6f7f9;--card:#fff;--text:#1d2433;--muted:#667085;--line:#e4e7ec;--ok:#12a150;--warn:#d98a00;--down:#d92d20}
@media(prefers-color-scheme:dark){:root{--bg:#10141c;--card:#181e29;--text:#e8ecf3;--muted:#9aa4b5;--line:#2a3342}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:32px 16px}
h1{font-size:20px;margin:0 0 4px}.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
.banner{padding:16px 18px;border-radius:12px;color:#fff;font-weight:600;margin-bottom:20px}
.banner.ok{background:var(--ok)}.banner.warn{background:var(--warn)}.banner.down{background:var(--down)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.row{display:flex;gap:12px;align-items:flex-start;padding:14px 18px;border-bottom:1px solid var(--line)}
.row:last-child{border:0}.dot{width:10px;height:10px;border-radius:50%;margin-top:7px;flex:none}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.down{background:var(--down)}
.name{font-weight:600}.det{color:var(--muted);font-size:13px;word-break:break-word}
.ms{margin-left:auto;color:var(--muted);font-size:12px;white-space:nowrap}
</style>
</head>
<body>
<main>
  <h1>Status Tenangin</h1>
  <div class="sub"><?= $h($host) ?> · dicek <?= date('d M Y H:i:s') ?> · refresh otomatis 30 dtk · <a href="?format=json" style="color:inherit">JSON</a></div>
  <div class="banner <?= $overall ?>"><?= $label[$overall] ?><?= $down ? ': ' . $h(implode(', ', $down)) : '' ?></div>
  <div class="card">
    <?php foreach ($checks as $c): ?>
    <div class="row">
      <span class="dot <?= $c['status'] ?>"></span>
      <div><div class="name"><?= $h($c['name']) ?></div><div class="det"><?= $h($c['detail']) ?></div></div>
      <?php if ($c['ms'] !== null): ?><div class="ms"><?= $c['ms'] ?> ms</div><?php endif; ?>
    </div>
    <?php endforeach; ?>
  </div>
</main>
</body>
</html>
