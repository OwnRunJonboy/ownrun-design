#!/usr/bin/env php
<?php

declare(strict_types=1);

$config = require '/opt/ownrun/server/config.example.php';

$config['db']['host'] = getenv('OWNRUN_DB_HOST') ?: 'db';
$config['db']['port'] = (int) (getenv('OWNRUN_DB_PORT') ?: 3306);
$config['db']['name'] = getenv('OWNRUN_DB_NAME') ?: 'ownrun';
$config['db']['user'] = getenv('OWNRUN_DB_USER') ?: 'ownrun';
$config['db']['pass'] = getenv('OWNRUN_DB_PASS') ?: 'ownrun';

$secret = getenv('OWNRUN_JWT_SECRET') ?: '';
if ($secret === '') {
    fwrite(STDERR, "OWNRUN_JWT_SECRET is required\n");
    exit(1);
}
$config['jwt_secret'] = $secret;

$out = "<?php\n\ndeclare(strict_types=1);\n\nreturn " . var_export($config, true) . ";\n";
$path = '/opt/ownrun/server/config.php';
if (file_put_contents($path, $out) === false) {
    fwrite(STDERR, "Could not write {$path}\n");
    exit(1);
}

echo "Wrote {$path}\n";
