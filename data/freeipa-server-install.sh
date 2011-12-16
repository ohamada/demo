#!/bin/bash

#function to get IP address of local computer
function getlocalip()
{
	/sbin/ifconfig ${1:-eth0} | awk '/inet addr/ {print $2}' | awk -F: '{print $2}';
}

#function to get bcast address for local computer
function getbcast()
{
	/sbin/ifconfig ${1:-eth0} | awk '/Bcast/ {print $3}' | awk -F: '{print $2}';
}

#function to get network mask for local computer
function getnetmask()
{
	/sbin/ifconfig ${1:-eth0} | awk '/Mask/ {print $4}' | awk -F: '{print $2}';
}

# function to prepare config file for setting static ip address
# $1 - full path to config file
# $2 - hostname
# $3 - domain
# $4 - [optional] address of dns server
function configeth0 {
	localip=`getlocalip`
	echo "DEVICE=eth0" > $1
	echo "BOOTPROTO=static" >> $1
	echo "ONBOOT=yes" >> $1
	echo "IPADDR=$localip" >> $1
	echo "BROADCAST=`getbcast`" >> $1
	echo "NETMASK=`getnetmask`" >> $1
	if [ ! -z $4 ]
	then
		echo "DNS1=$localip" >> $1
	fi

	mv /etc/sysconfig/network /etc/sysconfig/network.bak
	cat /etc/sysconfig/network.bak | grep -v HOSTNAME > /etc/sysconfig/network
	echo "HOSTNAME=$2.$3" >> /etc/sysconfig/network
	
	echo "$localip $2.$3 $2" >> /etc/hosts
	hostname "$2.$3"
}


function printhelp()
{
	echo "Script for configuring machine for installation and usage of freeipa-server."
	echo "Usage: ./freeipa-server-install.sh -c hostname -d domain [-f][-s][-n][-r realm][-p passwd][-e enrollment_passwd]"

	echo "Required arguments:"
	echo "-c hostname -- specifiy hostname of freeipaserver"
	echo "-d domain -- specify domain of freeipaserver"

	echo "These arguments are optional:"
	echo "-r realm -- specify name of realm"
	echo "-p passwd -- specify password for both freeipa Admin and Directory Manager"
	echo "-e enrollment_passwd -- specify password to be used for enrolling hosts into freeipa"
	echo "-f -- don't set firewall"
	echo "-n -- don't use freeipa-server machine as a DNS server"
	echo "-s -- use selfsigned certificates - don't use Dogtag as CA"
}

# server ip addr
IPADDR=`getlocalip`

# host name
HOST=""

# domain name
DOMAIN=""

# realm
REALM=EXAMPLE.COM

# set firewall
SETFWL=yes

# password for all admins, managers, etc.
PASSWD=baconbacon

# set dns
SETDNS="--setup-dns"

# password for host enrollment (same for each host)
ENROLL=baconbacon

# selfsigned certs or use dogtag as CA - dogtag is default
SELFSIGN=""

# eth0 configuration file
eth0conf=/etc/sysconfig/network-scripts/ifcfg-eth0

while getopts "fsnhc:p:r:d:e:" opt; do
	case $opt in
		f) SETFWL=no
			;;
		c) HOST="$OPTARG"
			;;

		n) SETDNS=""
			;;

		p) PASSWD="$OPTARG"
			;;

		e) ENROLL="$OPTARG"
			;;

		r) REALM="$OPTARG"
			;;

		d) DOMAIN="$OPTARG"
			;;

		s) SELFSIGN="--selfsign"
			;;

		h) printhelp
		   exit 0
			;;

		\?) echo "Wrong arguments!\n" >&2
		    exit 1
			;;
	esac
done

if [ "$HOST" == "" ]
then
	echo "You must specify this machine's hostname!\n" >&2
	exit 1
fi

if [ "$DOMAIN" == "" ]
then
	echo "You must specify this machine's domain!\n" >&2
	exit 1
fi


if [ "$SETDNS" != "" ]
then
	echo "nameserver 127.0.0.1" > /etc/resolv.conf
	echo "nameserver $IPADDR" >> /etc/resolv.conf
fi

service NetworkManager stop
chkconfig NetworkManager off
chkconfig network on

configeth0 $eth0conf $HOST $DOMAIN $dns

service network restart

# freeipa server installation with DNS
ipa-server-install --realm=$REALM --domain=$DOMAIN --ds-password=$PASSWD --master-password=$PASSWD --admin-password=$PASSWD --setup-dns --no-forwarders --hostname=$HOST.$DOMAIN --ip-address=$IPADDR -U

if [ ! $? -eq 0 ]
then
	echo "Server installation failed!" >&2
	exit 1
fi

if [ "$SETFWL" == "yes" ]
then
        # set firewall settings
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 88 -j ACCEPT
        iptables -I INPUT -p tcp --dport 53 -j ACCEPT
        iptables -I INPUT -p tcp --dport 389 -j ACCEPT
        iptables -I INPUT -p tcp --dport 636 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        iptables -I INPUT -p tcp --dport 464 -j ACCEPT
        iptables -I INPUT -p udp --dport 88 -j ACCEPT
        iptables -I INPUT -p udp --dport 464 -j ACCEPT
        iptables -I INPUT -p udp --dport 53 -j ACCEPT
        iptables -I INPUT -p udp --dport 123 -j ACCEPT
        # save iptables setting
        /etc/init.d/iptables save
fi

# Get Kerberos ticket
echo "$PASSWD" | kinit admin
