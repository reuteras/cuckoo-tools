#!/bin/bash

MOUNTP=$(vmware-hgfsclient)
LOG=/tmp/cuckoo-tools.log
touch "$LOG"

CUCKOO=~/src/cuckoo/.conf
export CUCKOO

# shellcheck disable=SC1090
. ~/cuckoo-tools/bin/common.sh
# shellcheck disable=SC1091
. /usr/share/virtualenvwrapper/virtualenvwrapper.sh

if [  -n "$MOUNTP" ]; then
    if [ ! -d ~/shared ]; then
        mkdir ~/shared
    fi
    sudo mount -t vmhgfs ".host:/$MOUNTP $HOME/shared" > /dev/null 2>&1
fi 

STATE=$(sudo virsh net-list | grep default | awk '{print $2}')
AUTO=$(sudo virsh net-list | grep default | awk '{print $3}')

if [ "$STATE" != "active" ]; then
    info-message "Start default network."
    sudo virsh net-start default
fi

if [ "$AUTO" == "no" ]; then
    info-message "Start default network."
    sudo virsh net-autostart default
fi

if [ ! -e /etc/suricata/rules/tor.rules ]; then
    info-message "Download rules for the first time."
    update_rules
fi

LAST_UPDATE_RULES=$(find /etc/suricata/rules/tor.rules -mtime +1)

if [ -n "$LAST_UPDATE_RULES" ]; then
    info-message "Rules to old, updating."
    update_rules
fi

info-message "Starting Suricata for Cuckoo."
if ! systemctl status suricata.service | grep "Active: inactive" > /dev/null ; then
    sudo systemctl stop suricata.service
    sleep 1
fi
# Stop previous versions of suricata started by this script
sudo pkill -f "suricata --unix-socket"

# Remove old socket and pid file
rm -f /var/run/suricata-command.socket > /dev/null 2>&1
rm -f /var/run/suricata.pid > /dev/null 2>&1

# shellcheck disable=SC2024
sudo suricata --unix-socket -D > ~/src/cuckoo/log/suricata.log 2>&1
info-message "Started suricata."

info-message "Waiting for Suricata socket. "
while [ ! -e /var/run/suricata-command.socket ]; do
    sleep 1
done

cd ~/src/cuckoo || exit 1
workon cuckoo

info-message "Starting rooter script as root. "
# shellcheck disable=SC2024
cuckoo rooter --sudo -g cuckoo >> ~/src/cuckoo/log/rooter.log 2>&1 &
sleep 10
info-message "Rooter running"

info-message "Setting access rights on suricata socket."
# shellcheck disable=SC2024
sudo chown cuckoo:cuckoo /var/run/suricata* >> ~/src/cuckoo/log/rooter.log 2>&1

info-message "Starting Cuckoo server."
INTERFACE=$(ip addr s | grep UP | grep -v lo: | grep -v virbr | cut -d: -f2 | sed -e "s/ //g")
HOSTIP=$(ip a s dev "$INTERFACE" | grep "inet " | awk '{print $2}' | sed -e "s:/.*::")
sed -i -e "s/ip = .*/ip = $HOSTIP/" ~/src/cuckoo/.conf/conf/cuckoo.conf
cuckoo -d >> ~/src/cuckoo/log/cuckoo-cmd.log 2>&1 &
sleep 3
info-message "Cuckoo started."

cd .conf/web || exit 1

info-message "Starting Cuckoo web."
cuckoo web runserver >> ~/src/cuckoo/log/web.log 2>&1 &
info-message "Cuckoo web server running."
cd ..

info-message "Waiting five seconds before starting Firefox."
sleep 5

# Make sure no process has changed the rights.
# shellcheck disable=SC2024
sudo chown cuckoo:cuckoo /var/run/suricata* >> ~/src/cuckoo/log/rooter.log 2>&1

info-message "Starting Firefox."
firefox http://127.0.0.1:8000 >> ~/src/cuckoo/log/firefox.log 2>&1 &

info-message "Cuckoo startup done."

