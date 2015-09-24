#!/bin/bash

#function to get a network interface
function getif()
{
    local LANG=en_US
	/sbin/ifconfig | awk -F: '/^[ \t]/ || /^lo:/ {next} {print $1; exit}'
}

#function to get IP address of local computer
function getlocalip()
{
    local LANG=en_US
	/sbin/ifconfig $1 | awk '/inet.*netmask.*broadcast/ {print $2}'
}

#function to get bcast address for local computer
function getbcast()
{
    local LANG=en_US
	/sbin/ifconfig $1 | awk '/inet.*netmask.*broadcast/ {print $6}'
}

#function to get network mask for local computer
function getnetmask()
{
    local LANG=en_US
	/sbin/ifconfig $1 | awk '/inet.*netmask.*broadcast/ {print $4}'
}

# function to prepare config file for setting static ip address
# $1 - network interface
# $2 - hostname
# $3 - domain
# $4 - [optional] address of dns server
function confignet {
	ifcfg=/etc/sysconfig/network-scripts/ifcfg-$1
	localip=`getlocalip $1`
	echo "DEVICE=$1" > $ifcfg
	echo "BOOTPROTO=static" >> $ifcfg
	echo "ONBOOT=yes" >> $ifcfg
	echo "IPADDR=$localip" >> $ifcfg
	echo "BROADCAST=`getbcast $1`" >> $ifcfg
	echo "NETMASK=`getnetmask $1`" >> $ifcfg
	if [ ! -z $4 ]
	then
		echo "DNS1=$4" >> $1
        # set new dns server
        echo "nameserver $4" > /etc/resolv.conf
	fi

	mv /etc/sysconfig/network /etc/sysconfig/network.bak
	cat /etc/sysconfig/network.bak | grep -v HOSTNAME > /etc/sysconfig/network
	echo "HOSTNAME=$2.$3" >> /etc/sysconfig/network
	
	echo "$localip $2.$3 $2" >> /etc/hosts
	hostname "$2.$3"
}

function printhelp()
{
	echo "Script for configuring machine for installation and usage of freeipa-client."
	echo "Usage: ./freeipa-server-install.sh -c hostname -d domain [-n ip-addr-of-dns][-p passwd][-s serverhostname]"

	echo "Required arguments:"
	echo "-c hostname -- specifiy hostname of freeipaserver"
	echo "-d domain -- specify domain of freeipaserver"
	echo "-p passwd -- specify password for enrolling machine into freeipa"
	echo "-n ip-addr-of-dns -- specify ip address of dns server"
	echo "-s serverhostname -- specify server hostname"
}


clientip=`getlocalip $(getif)`
dns=""
serverhostname=""
domain=""
clienthostname=""
password=""

while getopts "n:d:s:c:p:h" opt; do
	case $opt in
		n) dns=$OPTARG
			;;
		s) serverhostname=$OPTARG
			;;
		d) domain=$OPTARG
			;;
		c) clienthostname=$OPTARG
			;;
		p) password=$OPTARG
			;;
		h) printhelp
		   exit 0
			;;
		\?) echo "Unknown parameter used!"
		    exit 1
			;;
	esac
done

if [ -z $serverhostname ]
then
	echo "You must specify server hostname."
	exit 1
fi

if [ -z $domain ]
then
	echo "You must specify domain."
	exit 1
fi

if [ -z $password ]
then
	echo "You must specify password for enrollment."
	exit 1
fi

if [ -z $clienthostname ]
then
	echo "You must specify client hostname."
	exit 1
fi

service NetworkManager stop
chkconfig NetworkManager off
chkconfig network on

find /etc/sysconfig/network-scripts -name ifcfg-\* -not -name ifcfg-lo -delete
confignet $(getif) $clienthostname $domain $dns

service network restart

# run the install
ipa-client-install --server=$serverhostname.$domain --domain=$domain --hostname=$clienthostname.$domain --password=$password --enable-dns-updates --mkhomedir -U
# need to reboot in order to allow ipademo user using graphical desktop environmnet
reboot
