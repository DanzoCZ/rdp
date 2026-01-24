#!/bin/bash
echo ..........................................................
echo "PŘIHLAŠOVACÍ ÚDAJE PRO VZDÁLENOU PLOCHU (VNC):"
echo ..........................................................

# Získání veřejné adresy ze zrok logu
# Vyhledá řetězec začínající tcp://
ZROK_URL=$(grep -o "tcp://[a-zA-Z0-9.-]*:[0-9]*" zrok.log)

if [ -z "$ZROK_URL" ]; then
    echo "IP: Adresa se stále generuje... zadejte 'cat zrok.log' v tmate pro kontrolu."
else
    echo "IP: $ZROK_URL"
fi

echo "Username: runneradmin"
echo "Password: P@ssw0rd!"
echo "VNC Password: runnerrdp"
echo ..........................................................
echo "TIP: Pro připojení použijte VNC Viewer nebo Screen Sharing na Macu."
