#!/bin/bash

set -e

LOG=/tmp/cuckoo-tools.log
touch "$LOG"

export PATH=$PATH:$HOME/.local/bin

# Make a fake sudo to get password before output
sudo touch "$LOG"

# shellcheck source=/dev/null
if [[ -e ~/cuckoo-tools/bin/common.sh ]]; then
    . ~/cuckoo-tools/bin/common.sh
else
    echo "Cant find common.sh."
    exit 1
fi

info-message "Update apt packages for Debian"
# shellcheck disable=SC2024
sudo apt-get update >> $LOG 2>&1 && sudo apt-get -y dist-upgrade >> $LOG 2>&1

info-message "Install general tools from apt."
# shellcheck disable=SC2024
sudo apt-get -y -qq install \
    crudini \
    ctags \
    curl \
    exfat-fuse \
    exfat-utils \
    git \
    vim \
    vim-doc \
    vim-scripts \
    zip >> $LOG 2>&1

info-message "Install apt tools for Vmware."
# shellcheck disable=SC2024
sudo apt-get -y -qq install open-vm-tools-desktop fuse >> $LOG 2>&1

info-message "Install apt packages for Cuckoo and Volatility."
# shellcheck disable=SC2024
sudo apt-get -y -qq install python python-dev libffi-dev libssl-dev \
    qemu-kvm bridge-utils yara python-yara libyara3 \
    libyara-dev tcpdump libcap2-bin virt-manager swig \
    suricata tesseract-ocr libjpeg-dev linux-headers-"$(uname -r)" ssdeep \
    libfuzzy-dev libxml2-dev libxslt-dev libyaml-dev zlib1g-dev \
    python-virtualenv python-setuptools postgresql libpq-dev \
    virtualenvwrapper libvirt-daemon-system libvirt-dev net-tools \
    libvirt-clients build-essential python-m2crypto mitmproxy >> $LOG 2>&1

if ! grep cuckoo-tools /etc/suricata/suricata.yaml > /dev/null ; then
    info-message "Configure suricata"
    sudo cp ~/cuckoo-tools/files/suricata.yaml /etc/suricata/suricata.yaml
    sudo chown root:root /etc/suricata/suricata.yaml
    sudo chmod 644 /etc/suricata/suricata.yaml
fi

info-message "Install MongoDB."
wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
if [[ ! -e /etc/apt/sources.list.d/mongodb-org-4.4.list ]]; then
    echo "deb http://repo.mongodb.org/apt/debian buster/mongodb-org/4.4 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
    sudo apt-get update
fi
# shellcheck disable=SC2024
sudo apt-get install -y -qq mongodb-org >> $LOG 2>&1

if [ ! -d ~/src ]; then
    mkdir ~/src
fi

info-message "Setup virtualenvwrapper."
# shellcheck source=/dev/null
source /usr/share/virtualenvwrapper/virtualenvwrapper.sh

if [ ! -d ~/.virtualenvs/cuckoo ]; then
    info-message "Create virtualenv for Cuckoo."
    # Use python-m2crypto from Debian. Doesn't compile from pip
    mkvirtualenv --system-site-packages cuckoo >> "$LOG" 2>&1 || true
    {
        mkdir -p ~/src/cuckoo
        ln -s ~/src/cuckoo/.conf/log ~/src/cuckoo/log
        cd ~/src/cuckoo || exit 1
        setvirtualenvproject
        pip install -U pip setuptools
    } >> "$LOG" 2>&1
    deactivate
fi

# Install volatility
if [ ! -d ~/src/volatility ]; then
    info-message "Install Volatility"
    {
        workon cuckoo || true
        cd ~/src
        git clone https://github.com/volatilityfoundation/volatility.git
        cd volatility
        sudo python setup.py install
        deactivate
        cd
    } >> "$LOG" 2>&1
    info-message "Installed Volatility"
fi

# Install Cuckoo
if [ ! -f ~/.virtualenvs/cuckoo/bin/cuckoo ]; then
    info-message "Install Cuckoo"
    workon cuckoo || true
    {
        pip install pyrsistent==0.16.1
        pip install -U cuckoo distorm3==3.4.2 libvirt-python==5.10.0 WeasyPrint==0.42.3
        # Create default configuration
        cuckoo --cwd ~/src/cuckoo/.conf init
        # Download community rules and more
        cuckoo --cwd ~/src/cuckoo/.conf community
    } >> "$LOG" 2>&1
    deactivate
    sudo setfacl -R -m user:cuckoo:7 ~/src/cuckoo/.conf/storage
    sudo setfacl -d -R -m user:cuckoo:7 ~/src/cuckoo/.conf/storage
    info-message "Installed Cuckoo"
fi

# Fix group rights
sudo usermod -a -G libvirt "$USER"
sudo usermod -a -G libvirt-qemu "$USER"

# Let regular users access tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump

# Mitmproxy
if [ ! -e ~/src/cuckoo/.conf/analyzer/windows/bin/cert.p12 ]; then
    info-message "Fix certificate for mitmproxy."
    mitmproxy >> ~/src/cuckoo/log/mitmproxy 2>&1 &
    MITM_PID=$!
    sleep 10
    kill -9 $MITM_PID > /dev/null 2>&1 || true
    cp ~/.mitmproxy/mitmproxy-ca-cert.p12 ~/src/cuckoo/.conf/analyzer/windows/bin/cert.p12
    sed -i -e 's/mitmdump, "-q",/mitmdump, "-q", "--no-http2",/' ~/.virtualenvs/cuckoo/lib/python2.7/site-packages/cuckoo/auxiliary/mitm.py
    #sed -i -e 's#/usr/local/bin/mitmdump#/usr/bin/mitmdump#' ~/.virtualenvs/cuckoo/lib/python2.7/site-packages/cuckoo/auxiliary/mitm.py
    info-message "Fixed mitmproxy."
fi

# Configure Cuckoo
ROOTDIR=~/src/cuckoo/.conf/conf
if [ ! -f $ROOTDIR/.configured ]; then
    info-message "Configure Cuckoo."
    INTERFACE=$(ip a s | grep UP | grep -E -v "lo:|virbr" | cut -f2 -d: | sed -e "s/ //g" | head -1)
    HOSTIP=$(ip a s dev "$INTERFACE" | grep "inet " | awk '{print $2}' | sed -e "s:/.*::")

    if ! grep 400 /etc/iproute2/rt_tables > /dev/null 2>&1 ; then
        echo "400   $INTERFACE" | sudo tee -a /etc/iproute2/rt_tables > /dev/null
    fi

    crudini --set $ROOTDIR/auxiliary.conf mitm enabled yes
    crudini --set $ROOTDIR/auxiliary.conf mitm mitmdump /usr/bin/mitmdump
    # TODO add filter
    sed -i -e "s/# bpf = /bpf = /" $ROOTDIR/auxiliary.conf

    crudini --set $ROOTDIR/cuckoo.conf cuckoo machinery kvm
    sed -i -e "s/ip = 192.168.56.1/ip = $HOSTIP/" $ROOTDIR/cuckoo.conf

    crudini --set $ROOTDIR/kvm.conf kvm machines win7_x64
    sed -i -e "s/\[cuckoo1\]/\[win7_x64\]/" $ROOTDIR/kvm.conf
    crudini --set $ROOTDIR/kvm.conf win7_x64 label win7_x64
    crudini --set $ROOTDIR/kvm.conf win7_x64 snapshot snapshot1

    crudini --set $ROOTDIR/memory.conf basic guest_profile Win7SP1x64

    crudini --set $ROOTDIR/processing.conf screenshots enabled yes
    crudini --set $ROOTDIR/processing.conf suricata enabled yes
    crudini --set $ROOTDIR/processing.conf suricata socket /var/run/suricata-command.socket

    crudini --set $ROOTDIR/routing.conf routing internet "$INTERFACE"

    crudini --set $ROOTDIR/reporting.conf singlefile enabled yes
    crudini --set $ROOTDIR/reporting.conf singlefile html yes
    crudini --set $ROOTDIR/reporting.conf singlefile pdf yes
    crudini --set $ROOTDIR/reporting.conf mongodb enabled yes

    touch $ROOTDIR/.configured
    info-message "Cuckoo configured."
fi

info-message "Done with setup.sh."

