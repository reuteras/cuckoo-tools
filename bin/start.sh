#!/bin/bash

MOUNTP=$(vmware-hgfsclient)

if [ !  -z "$MOUNTP" ]; then
    if [ ! -d ~/shared ]; then
        mkdir ~/shared
    fi
    sudo mount -t vmhgfs .host:/$MOUNTP $HOME/shared
fi 

STATE=$(sudo virsh net-list | grep default | awk '{print $2}')
AUTO=$(sudo virsh net-list | grep default | awk '{print $3}')

if [ "$STATE" != "active" ]; then
    virsh net-start default
fi

if [ "$AUTO" == "no" ]; then
    virsh net-autostart default
fi

if [ -e /var/run/suricata/suricata-command.socket ]; then
    sudo rm -f /var/run/suricata/suricata-command.socket
fi

suricata --unix-socket -D

while [ ! -e /var/run/suricata/suricata-command.socket ]; do
    sleep 1
done

sudo chown reuteras:reuteras /var/run/suricata/
sudo chown reuteras:reuteras /var/run/suricata/suricata-command.socket

cd ~/src/cuckoo
./cuckoo.py -d >> log/cuckoo-cmd.log 2>&1 &
cd web
python manage.py runserver >> ../log/web.log 2>&1 &
cd ..
sleep 2

iceweasel http://127.0.0.1:8000 >> log/iceweasel 2>&1 &
