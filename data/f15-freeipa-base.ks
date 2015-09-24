# Kickstart file for Fedora 15 with freeipa-server
install
text
cmdline
poweroff
lang en_US.UTF-8
keyboard us
network --bootproto dhcp
#Root password
rootpw --plaintext rootroot
#test user - without it graphical desktop won't start
user --name=test --password=test --plaintext
firewall --enabled --ssh
selinux --permissive
timezone --utc America/New_York
firstboot --disable
bootloader --location=mbr --append="console=tty0 console=ttyS0,115200 rd_NO_PLYMOUTH"
zerombr
clearpart --all --initlabel
autopart
xconfig --startxonboot

repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch
repo --name=testing --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-testing-f$releasever&arch=$basearch

# packages to install
%packages
@core
@base-x
@fonts
@LXDE
@critical-path-lxde
yum-utils
sudo
audit
openssh-server
openssh-clients
iptables
mc
vim-enhanced
acpid
mc
bash
firefox
bind
bind-dyndb-ldap
freeipa-server

%end

%post --nochroot --log=/root/ks-post-install.log
mkdir --mode=700 /mnt/sysimage/root/.ssh
sed "s/.*ssh_key='\([^']*\)'.*/\1/" /proc/cmdline >/mnt/sysimage/root/.ssh/authorized_keys
chmod 600 /mnt/sysimage/root/.ssh/authorized_keys
%end

# post installation scripts
%post --log=/root/ks-post-install.log
set -x

restorecon -Rv /root/.ssh

mv /etc/sudoers /etc/sudoers_old
grep -v requiretty /etc/sudoers_old > /etc/sudoers
chmod 440 /etc/sudoers
echo "%ipausers       ALL = NOPASSWD: ALL" >> /etc/sudoers

%end
