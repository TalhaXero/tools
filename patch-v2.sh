
#!/usr/bin/env bash
# Written by Talha
# Script: patch.sh
# Purpose: Mitigate CVE-2026-109619 and CVE-2026-115560
# Platform: cPanel/WHM - EasyApache 4 PHP
#
# Settings:
#   All EA4 PHP versions: session.upload_progress.enabled = Off
#   PHP 8.5:              fatal_error_backtraces = Off
#
# Note: This does not cover CloudLinux Alt-PHP.

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

readonly EA_PHP_BASE="/opt/cpanel"
readonly INI_FILENAME="local-disable-upload-progress.ini"

echo "=========================================================="
echo " PHP Security Mitigation"
echo " CVE-2026-109619 / CVE-2026-115560"
echo "=========================================================="

declare -a PHP_DIRS=()
declare -a FAILED_FILES=()
declare -a FAILED_SERVICES=()

# Discover installed EasyApache PHP configurations.
for php_d in "${EA_PHP_BASE}"/ea-php*/root/etc/php.d; do
    [[ -d "$php_d" ]] || continue
    PHP_DIRS+=("$php_d")
done

if [[ ${#PHP_DIRS[@]} -eq 0 ]]; then
    echo "[ERROR] No EasyApache PHP installations found."
    exit 1
fi

echo "[+] Applying PHP configuration overrides..."

for php_d in "${PHP_DIRS[@]}"; do
    php_version="$(basename "$(dirname "$(dirname "$(dirname "$php_d")")")")"
    target_file="${php_d}/${INI_FILENAME}"
    tmp_file="${target_file}.tmp"

    if [[ "$php_version" == "ea-php85" ]]; then
        cat > "$tmp_file" <<'EOF'
; Security mitigation for CVE-2026-109619 and CVE-2026-115560
session.upload_progress.enabled = Off
fatal_error_backtraces = Off
EOF
    else
        cat > "$tmp_file" <<'EOF'
; Security mitigation for CVE-2026-109619 and CVE-2026-115560
session.upload_progress.enabled = Off
EOF
    fi

    if chmod 644 "$tmp_file" &&
       mv -f "$tmp_file" "$target_file"; then
        echo "    [OK] ${php_version}"
    else
        echo "    [FAILED] ${php_version}: could not write configuration"
        FAILED_FILES+=("$target_file")
        rm -f "$tmp_file"
    fi
done

echo
echo "[+] Restarting installed PHP-FPM services..."

while read -r service; do
    [[ -n "$service" ]] || continue

    echo "    -> ${service}"
    if ! systemctl restart "$service"; then
        echo "    [FAILED] ${service}"
        FAILED_SERVICES+=("$service")
    fi
done < <(
    systemctl list-unit-files \
        --type=service --no-legend 'ea-php*-php-fpm.service' |
        awk '{print $1}'
)

# Restart the active web server to reload non-FPM PHP handlers
# where applicable. This does not replace LSAPI-specific verification.
if systemctl is-active --quiet httpd; then
    echo "[+] Restarting Apache..."
    systemctl restart httpd || FAILED_SERVICES+=("httpd")
elif systemctl is-active --quiet lsws; then
    echo "[+] Restarting LiteSpeed..."
    systemctl restart lsws || FAILED_SERVICES+=("lsws")
fi

echo
echo "=========================================================="
echo " Verification (CLI PHP configuration)"
echo "=========================================================="

VERIFY_FAILED=0

for php_bin in "${EA_PHP_BASE}"/ea-php*/root/usr/bin/php; do
    [[ -x "$php_bin" ]] || continue

    php_version="$(echo "$php_bin" | grep -oE 'ea-php[0-9]+' | head -n 1)"
    upload_progress="$("$php_bin" -r \
        'echo ini_get("session.upload_progress.enabled");' 2>/dev/null)" || {
        echo "    [FAILED] ${php_version}: CLI query failed"
        VERIFY_FAILED=1
        continue
    }

    echo -n "    [${php_version}] session.upload_progress.enabled=${upload_progress}"

    if [[ "$upload_progress" != "0" ]]; then
        echo " [FAILED]"
        VERIFY_FAILED=1
        continue
    fi

    if [[ "$php_version" == "ea-php85" ]]; then
        backtraces="$("$php_bin" -r \
            'echo ini_get("fatal_error_backtraces");' 2>/dev/null)" || {
            echo " [FAILED: backtrace query failed]"
            VERIFY_FAILED=1
            continue
        }

        echo -n " | fatal_error_backtraces=${backtraces}"

        if [[ "$backtraces" != "0" ]]; then
            echo " [FAILED]"
            VERIFY_FAILED=1
            continue
        fi
    fi

    echo " [OK]"
done

echo
echo "=========================================================="
echo " Final Result"
echo "=========================================================="

if [[ ${#FAILED_FILES[@]} -gt 0 ||
      ${#FAILED_SERVICES[@]} -gt 0 ||
      "$VERIFY_FAILED" -ne 0 ]]; then
    echo "[WARNING] Some operations failed. Review the output above."
    [[ ${#FAILED_FILES[@]} -eq 0 ]] ||
        printf 'Failed configuration files: %s\n' "${FAILED_FILES[*]}"
    [[ ${#FAILED_SERVICES[@]} -eq 0 ]] ||
        printf 'Failed service restarts: %s\n' "${FAILED_SERVICES[*]}"
    exit 1
fi

echo "[SUCCESS] Mitigation settings verified for detected CLI PHP versions."
echo "[IMPORTANT] CLI verification does not prove every web handler is protected."
echo "[IMPORTANT] CloudLinux Alt-PHP requires separate coverage."
echo "[IMPORTANT] Install vendor security updates as soon as available."
exit 0
