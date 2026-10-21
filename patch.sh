#!/usr/bin/env bash
# Written by Talha
# Script: patch.sh
# Purpose: Globally disable session.upload_progress.enabled across all EasyApache 4 
#          PHP installations on cPanel/WHM systems to mitigate CVE-2026-109618 / CVE-2026-109619.
#

set -euo pipefail

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run as root." >&2
   exit 1
fi

INI_FILENAME="local-disable-upload-progress.ini"
EA_PHP_BASE="/opt/cpanel"

echo "=========================================================="
echo " Starting PHP session.upload_progress Mitigation"
echo "=========================================================="

# Step 1: Apply drop-in INI file to all installed EA4 PHP versions
echo "[+] Creating drop-in configuration files..."

FOUND_VERSIONS=0
for php_d in "${EA_PHP_BASE}"/ea-php*/root/etc/php.d/; do
    if [[ -d "$php_d" ]]; then
        FOUND_VERSIONS=1
        target_file="${php_d}${INI_FILENAME}"
        
        # Write the override setting
        cat << 'EOF' > "$target_file"
; Mitigation for PHP session.upload_progress Heap UAF
session.upload_progress.enabled = Off
EOF
        chmod 644 "$target_file"
        echo "    -> Applied to: ${target_file}"
    fi
done

if [[ $FOUND_VERSIONS -eq 0 ]]; then
    echo "[!] No EasyApache 4 PHP installations found at ${EA_PHP_BASE}/ea-php*"
    exit 1
fi

# Step 2: Restart Web and PHP Services
echo -e "\n[+] Restarting PHP-FPM and HTTP services..."

if systemctl list-unit-files | grep -q "ea-php.*-php-fpm"; then
    echo "    -> Restarting ea-php*-php-fpm services..."
    systemctl restart ea-php*-php-fpm || echo "[!] Warning: Some PHP-FPM services failed to restart."
fi

if systemctl is-active --quiet httpd; then
    echo "    -> Restarting Apache (httpd)..."
    systemctl restart httpd
elif systemctl is-active --quiet lsws; then
    echo "    -> Restarting LiteSpeed (lsws)..."
    systemctl restart lsws
fi

# Step 3: Verification
echo -e "\n=========================================================="
echo " Verification Results"
echo "=========================================================="

ALL_DISABLED=true

for php_bin in "${EA_PHP_BASE}"/ea-php*/root/usr/bin/php; do
    if [[ -x "$php_bin" ]]; then
        version=$(basename "$(dirname "$(dirname "$(dirname "$php_bin")")")")
        status=$("$php_bin" -i 2>/dev/null | grep "session.upload_progress.enabled" || true)
        
        echo -n " [$version] "
        if echo "$status" | grep -q "Off => Off"; then
            echo "SUCCESS: Disabled ($status)"
        else
            echo "FAILED: $status"
            ALL_DISABLED=false
        fi
    fi
done

echo "=========================================================="
if [ "$ALL_DISABLED" = true ]; then
    echo "[SUCCESS] Mitigation successfully applied to all active PHP versions."
else
    echo "[WARNING] One or more PHP versions failed verification. Please inspect manually."
fi
