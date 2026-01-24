#!/bin/bash

# 1. Zakázání indexování Spotlight (zrychlení systému)
sudo mdutil -i off -a

# 2. Vytvoření administrátorského účtu
# Jméno: runneradmin | Heslo: P@ssw0rd!
sudo dscl . -create /Users/runneradmin
sudo dscl . -create /Users/runneradmin UserShell /bin/bash
sudo dscl . -create /Users/runneradmin RealName "Runner Admin"
sudo dscl . -create /Users/runneradmin UniqueID 1001
sudo dscl . -create /Users/runneradmin PrimaryGroupID 80
sudo dscl . -create /Users/runneradmin NFSHomeDirectory /Users/runneradmin
sudo dscl . -passwd /Users/runneradmin 'P@ssw0rd!'
sudo createhomedir -c -u runneradmin > /dev/null
sudo dscl . -append /Groups/admin GroupMembership runneradmin

# 3. Konfigurace VNC a Vzdálené plochy (Apple Remote Desktop)
# Heslo pro VNC je nastaveno na: runnerrdp
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart -activate -configure -access -on -privs -all -grant -all -clientopts -setvncpassword -vncpassword "runnerrdp" -restart -agent

# 4. Instalace zrok (přímé stažení binárky - nevyžaduje kartu ani přihlášení ke GitHubu)
echo "Instaluji zrok..."
curl -L https://github.com -o zrok.tar.gz
tar -xzf zrok.tar.gz
chmod +x zrok
sudo mv zrok /usr/local/bin/

# 5. Spuštění zrok tunelu
# $1 je váš ZROK_TOKEN předaný z workflow
if [ -z "$1" ]; then
  echo "Chyba: ZROK_TOKEN nebyl poskytnut!"
else
  zrok enable "$1"
  # Spuštění TCP tunelu pro VNC (port 5900) na pozadí
  nohup zrok share public localhost:5900 --backend-mode tcp > zrok.log 2>&1 &
  echo "Tunel se spouští..."
  sleep 10
  echo "--- ADRESA PRO PŘIPOJENÍ ---"
  grep -o "tcp://[a-zA-Z0-9.-]*:[0-9]*" zrok.log || echo "Hledejte adresu v zrok.log přes tmate."
  echo "---------------------------"
fi
