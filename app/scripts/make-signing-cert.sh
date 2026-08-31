#!/bin/bash
# Создаёт локальный self-signed сертификат "Sezish Dev" для стабильной подписи.
# TCC-гранты (Accessibility, микрофон) привязываются к подписи, а не к CDHash,
# поэтому доступ, выданный один раз, переживает пересборки.
# Запусти сам:  ! bash ~/dev/my/sezish/app/scripts/make-signing-cert.sh
# sudo НЕ нужен. Один раз спросит пароль login-keychain (или Touch ID) — это нормально.
set -euo pipefail

CN="Sezish Dev"
KC="$HOME/Library/Keychains/login.keychain-db"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-identity -v -p codesigning | grep -q "$CN"; then
    echo "Identity '$CN' уже есть — ничего не делаю."
    exit 0
fi

cat > "$DIR/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

# Ключ в PKCS#8 PEM и самоподписанный сертификат. p12 НЕ используем: openssl 3
# пакует p12 с MAC, который Apple security не понимает ("MAC verification failed").
openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -nodes -config "$DIR/cfg" >/dev/null 2>&1

# Импорт сертификата и приватного ключа по отдельности — security сам свяжет их
# в identity по совпадению открытого ключа. -T разрешает codesign брать ключ без промпта.
security import "$DIR/cert.pem" -k "$KC" -T /usr/bin/codesign -T /usr/bin/security
security import "$DIR/key.pem"  -k "$KC" -T /usr/bin/codesign -T /usr/bin/security

# Доверие для code signing (пользовательский домен). Здесь возможен запрос пароля/Touch ID.
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$DIR/cert.pem"

echo
echo "Готово. Проверка:"
security find-identity -v -p codesigning | grep "$CN" || {
    echo "Не появилась в списке — открой Keychain Access и убедись, что сертификат '$CN' доверен для Code Signing."
    exit 1
}
echo
echo "Дальше пересобери приложение подписанным этой identity:"
echo "    cd ~/dev/my/sezish/app && make bundle SIGN_ID=\"$CN\""
