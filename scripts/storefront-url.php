<?php
/**
 * Prints the URL of the first storefront sales channel domain (empty if none),
 * read from DATABASE_URL. Used by setup.sh to keep it in sync with SW_URL.
 */

$url = parse_url((string) getenv('DATABASE_URL'));
try {
    $pdo = new PDO(
    sprintf('mysql:host=%s;port=%d;dbname=%s', $url['host'], $url['port'] ?? 3306, ltrim($url['path'], '/')),
    urldecode($url['user'] ?? ''),
    urldecode($url['pass'] ?? ''),
);
// Storefront sales channel type id, fixed in Shopware's Defaults.
$storefront = hex2bin('8a243080f92e4c719546314b577cf82b');
$stmt = $pdo->prepare(
    'SELECT d.url FROM sales_channel_domain d JOIN sales_channel s ON s.id = d.sales_channel_id
     WHERE s.type_id = ? ORDER BY d.created_at LIMIT 1'
);
$stmt->execute([$storefront]);
echo rtrim((string) $stmt->fetchColumn(), '/');
} catch (PDOException $e) {
    // Not installed yet (no tables): nothing to sync.
}
