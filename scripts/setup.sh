#!/bin/sh
# Installs or upgrades Shopware and applies the stack's environment.
#
# Runs on every `docker compose up` and is safe to repeat:
# - Shopware's deployment helper installs Shopware on an empty database
#   (admin user, storefront sales channel, theme) or, on later runs, runs the
#   migrations when the image's version changed, refreshes plugins and
#   compiles the theme into the shared `theme` volume.
# - The storefront URL follows SW_URL (it is stored in the database).
# - SMTP settings follow SMTP_* when SMTP_HOST is set.
# - Initial settings (shop name and email) are applied once (marker
#   core.dockerStack.initialized); later changes in the administration are kept.
set -eu

cd /var/www/html

console() { php bin/console --no-interaction "$@"; }

# Sets a system config value only if it differs (setting it clears caches).
set_config() {
    if [ "$(console system:config:get "$1" --format=scalar 2>/dev/null || true)" != "$2" ]; then
        console system:config:set "$1" "$2" > /dev/null
        echo "    $1 updated"
    fi
}

# URL change: move the existing storefront to SW_URL *before* the deployment
# helper runs, otherwise the helper creates a second storefront sales channel
# for the new URL (it does that for any SALES_CHANNEL_URL that doesn't exist).
current_url="$(php /usr/local/share/stack/scripts/storefront-url.php)"
if [ -n "${current_url}" ] && [ "${current_url}" != "${SW_URL%/}" ]; then
    echo "==> Storefront URL ${current_url} -> ${SW_URL%/}"
    console sales-channel:replace:url "${current_url}" "${SW_URL%/}"
fi

echo "==> Shopware ${SW_VERSION}: deployment helper"
# Assets are built into the image; the web container can't see files the
# setup container writes outside the shared volumes.
php vendor/bin/shopware-deployment-helper run --skip-assets-install

echo "==> Applying environment (SMTP)"

if [ -n "${SMTP_HOST}" ]; then
    case "$(echo "${SMTP_SECURE}" | tr '[:upper:]' '[:lower:]')" in
        tls) encryption=tls ;;
        ssl) encryption=ssl ;;
        *) encryption=null ;;
    esac
    set_config core.mailerSettings.emailAgent smtp
    set_config core.mailerSettings.host "${SMTP_HOST}"
    # shellcheck disable=SC2153 # set by compose
    set_config core.mailerSettings.port "${SMTP_PORT}"
    set_config core.mailerSettings.encryption "${encryption}"
    set_config core.mailerSettings.username "${SMTP_USER}"
    set_config core.mailerSettings.password "${SMTP_PASSWORD}"
    if [ -n "${SMTP_FROM}" ]; then
        set_config core.basicInformation.email "${SMTP_FROM}"
    fi
fi

if [ -z "$(console system:config:get core.dockerStack.initialized --format=scalar 2>/dev/null || true)" ]; then
    echo "==> Initial settings"
    set_config core.basicInformation.shopName "${SW_SHOP_NAME}"
    set_config core.dockerStack.initialized "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

echo "==> Done: Shopware ${SW_VERSION}"
echo "    Store: ${SW_URL}"
echo "    Admin: ${SW_URL%/}/admin (${INSTALL_ADMIN_USERNAME})"
