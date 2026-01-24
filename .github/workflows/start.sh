# 1. Stažení nejnovějšího zroku pro macOS (ARM64) přímo z GitHub Releases
echo "Stahuji zrok z GitHub Releases..."
# Používáme oficiální repozitář openzrok/zrok a verzi 0.4.42 (aktuální stabilní)
ZROK_URL="https://github.com"

curl -fL "$ZROK_URL" -o zrok.tar.gz || { echo "Stažení selhalo"; exit 1; }

# 2. Kontrola typu souboru (prevence stahování HTML)
FILE_TYPE=$(file -b --mime-type zrok.tar.gz)
if [[ "$FILE_TYPE" != *"gzip"* ]]; then
  echo "CHYBA: Stažený soubor není platný archiv (typ: $FILE_TYPE). Pravděpodobně chybná URL."
  exit 1
fi

# 3. Rozbalení a instalace
tar -xzf zrok.tar.gz || { echo "Rozbalení selhalo"; exit 1; }

# Po rozbalení je binárka často v podadresáři, najdeme ji a přesuneme
chmod +x zrok
sudo mv zrok /usr/local/bin/zrok || sudo mv **/zrok /usr/local/bin/zrok

# 4. Ověření
zrok version
