#!/usr/bin/env bash
# Yerel geliştirme için kalıcı bir kod imzalama kimliği oluşturur ("OpenIsland Local Signing").
#
#   ./Scripts/create-dev-identity.sh
#
# Neden: ad-hoc imzada uygulamanın kimliği her derlemede değişen cdhash'tir; macOS (TCC) bu yüzden
# Erişilebilirlik ve Kamera iznini her derlemeden sonra unutur. Bu kimlikle imzalanan uygulamanın kimliği
# "paket kimliği + bu sertifika" olur ve yeniden derlemede değişmez: izin bir kez verilir, kalır.
#
# Ne yapar: kendinden imzalı, yalnızca kod imzalamaya yetkili bir sertifika ve anahtar üretir ve oturum
# anahtar zincirinize ekler. Sistem güven ayarlarına dokunmaz (sertifikayı "güvenilir" yapmaz; kod imzalama
# ve izinlerin korunması için gerekmez). build-app.sh bu kimliği kendiliğinden bulur.
# Apple Developer hesabınız varsa buna gerek yoktur: "Apple Development" kimliği zaten seçilir.
#
# Geri almak için: Anahtar Zinciri Erişimi › oturum › "OpenIsland Local Signing" sertifikasını ve anahtarını silin.
set -euo pipefail

NAME="OpenIsland Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL=/usr/bin/openssl # macOS'un LibreSSL'i: ürettiği PKCS#12 dosyasını `security` sorunsuz içe aktarır

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✅ \"$NAME\" zaten var. Uygulamayı yeniden derleyin: ./Scripts/build-app.sh"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# PKCS#12 yalnızca bu betik süresince geçici bir parolayla var olur (dosya hemen silinir).
PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

# Anahtarı yalnızca codesign kullanabilir; ilk imzada macOS bir kez izin sorabilir ("Her Zaman İzin Ver").
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

# Doğrulama: geçici bir kopya bu kimlikle imzalanabiliyor mu?
cp /usr/bin/true "$WORK/probe"
if codesign --force --sign "$NAME" --keychain "$KEYCHAIN" "$WORK/probe" 2>"$WORK/codesign.log" \
   && codesign --verify "$WORK/probe" 2>/dev/null; then
  echo "✅ \"$NAME\" oluşturuldu ve imzalama denendi."
  echo "   Şimdi: ./Scripts/build-app.sh  →  Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik'te OpenIsland'i bir kez açın."
  echo "   Eski (ad-hoc) OpenIsland girişi listede kalmışsa onu '−' ile kaldırıp yenisini ekleyin."
else
  echo "⚠️  Kimlik eklendi ama deneme imzası başarısız oldu:"
  cat "$WORK/codesign.log"
  echo "   Anahtar zinciri erişim penceresi çıktıysa 'Her Zaman İzin Ver' deyip betiği yeniden çalıştırın."
  exit 1
fi
