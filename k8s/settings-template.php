<?php
/**
 * Шаблон /opt/www/bitrix/.settings.php для деплоя Битрикс24 в Kubernetes.
 *
 * Порядок настройки:
 * 1. Скопируйте этот файл в /opt/www/bitrix/.settings.php внутри пода (или через init Job).
 * 2. Замените CHANGE_ME_* на реальные значения (или прокиньте через env и getenv()).
 * 3. После первого запуска выполните bitrixsetup.php для установки / restore.php для восстановления.
 * 4. Включите BX_CRONTAB_SUPPORT в dbconn.php.
 *
 * Хосты сервисов в кластере (K8s DNS):
 *   postgres           — PostgreSQL (port 5432)
 *   memcached-headless — все pod IP memcached (consistent hashing, port 11211)
 *   sphinx             — Sphinx searchd (port 9306)
 *   bitrix-push-pub    — Push pub (port 80)
 */

return [

    // -------------------------------------------------------------------------
    // База данных PostgreSQL
    // -------------------------------------------------------------------------
    'connections' => [
        'value' => [
            'default' => [
                'className'  => '\\Bitrix\\Main\\DB\\PgsqlConnection',
                'host'       => 'postgres',
                'database'   => 'bitrix',
                'login'      => 'bitrix',
                'password'   => 'CHANGE_ME_POSTGRES_PASSWORD',
                'options'    => 2,
            ],
        ],
        'readonly' => false,
    ],

    // -------------------------------------------------------------------------
    // Кеш — Memcached кластер через headless Service.
    // headless Service "memcached-headless" возвращает IP всех подов с sidecar memcached.
    // PHP расширение memcache использует consistent hashing для распределения ключей.
    // -------------------------------------------------------------------------
    'cache' => [
        'value' => [
            'type' => [
                'class_name' => '\\Bitrix\\Main\\Data\\CacheEngineMemcache',
                'extension'  => 'memcache',
            ],
            'memcache' => [
                'host' => 'memcached-headless',
                'port' => '11211',
            ],
        ],
        'sid' => $_SERVER['DOCUMENT_ROOT'] . '#01',
    ],

    // -------------------------------------------------------------------------
    // Сессии — режим "separated":
    //   kernel  = encrypted_cookies (токен авторизации в зашифрованной cookie,
    //             не зависит от того, на какой под попал запрос)
    //   general = memcache (прочие данные сессии в memcached)
    // -------------------------------------------------------------------------
    'session' => [
        'value' => [
            'lifetime' => 14400,
            'mode'     => 'separated',
            'handlers' => [
                'kernel'  => 'encrypted_cookies',
                'general' => [
                    'type' => 'memcache',
                    'host' => 'memcached-headless',
                    'port' => '11211',
                ],
            ],
        ],
        'readonly' => false,
    ],

    // -------------------------------------------------------------------------
    // Push-сервер
    // Замените YOUR_DOMAIN на реальный домен из Ingress.
    // path_to_publish — внутренний K8s-адрес push-pub (не через Ingress).
    // -------------------------------------------------------------------------
    'pull' => [
        'value' => [
            'path_to_listener'              => 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_listener_secure'       => 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_modern_listener'       => 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_modern_listener_secure'=> 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_mobile_listener'       => 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_mobile_listener_secure'=> 'https://YOUR_DOMAIN/bitrix/sub/',
            'path_to_websocket'             => 'wss://YOUR_DOMAIN/bitrix/subws/',
            'path_to_websocket_secure'      => 'wss://YOUR_DOMAIN/bitrix/subws/',
            'path_to_publish'               => 'http://bitrix-push-pub/bitrix/pub/',
            'path_to_publish_web'           => 'https://YOUR_DOMAIN/bitrix/rest/',
            'path_to_publish_web_secure'    => 'https://YOUR_DOMAIN/bitrix/rest/',
            'path_to_json_rpc'              => 'https://YOUR_DOMAIN/bitrix/api/',
            'nginx_version'                 => '4',
            'nginx_command_per_hit'         => '100',
            'nginx'                         => 'Y',
            'nginx_headers'                 => 'N',
            'push'                          => 'Y',
            'websocket'                     => 'Y',
            'signature_key'                 => 'CHANGE_ME_PUSH_SECURITY_KEY',
            'signature_algo'                => 'sha1',
            'guest'                         => 'N',
        ],
        'readonly' => false,
    ],

    // -------------------------------------------------------------------------
    // Sphinx — полнотекстовый поиск.
    // Настройки применяются в /bitrix/admin/settings.php?mid=search
    // -------------------------------------------------------------------------
    // Для активации Sphinx через admin UI:
    //   Настройки → Поиск → Морфология → "Sphinx" → строка подключения "sphinx:9306"

    // -------------------------------------------------------------------------
    // Временные файлы вне корня сайта (защита от известных атак)
    // -------------------------------------------------------------------------
    // Добавьте в /opt/www/bitrix/php_interface/dbconn.php:
    //   define("BX_TEMPORARY_FILES_DIRECTORY", "/opt/.bx_temp");
    //   define("BX_CRONTAB_SUPPORT", true);

];
