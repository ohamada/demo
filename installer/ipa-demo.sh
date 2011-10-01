#!/bin/bash

###############################################################################
#############
####		FUNCTIONS DEFINITION
#############
###############################################################################

# function to get ip address of VM
# name of VM is the first argument of function
function getvmip {
	while [ -z `virt-cat "$1" /var/log/messages | grep 'dhclient.*bound to' | awk '{ print $8}' | tail -1` ]; do
		sleep 10
	done
	virt-cat "$1" /var/log/messages | grep 'dhclient.*bound to' | awk '{ print $8}' | tail -1
}

# function to check whether variable really contains number
# first parametr - variable to check
function isnumber {
	if [ -z `echo $1 | grep "^[0-9]*$"` ]
	then
		return 1;
	else
		return 0;
	fi
}

# function that prints help
function printhelp {
	echo "Ipa-demo installation script"
	echo "This script should help you through setting up freeipa server and client in order to be able to try it out."
	echo " ATTENTION: You must have kvm and libguestfs-tools-c installed to run the script correctly."
	echo "usage: ipa-demo.sh [-d dir][-r repoaddr][-c clientnr][-h]"
	echo "h - print help"
	echo "d - set directory to store images"
	echo "r - set fedora repository"
	echo "c - number of clients"

}

# function to get PID - get PID of process which handles virtual machine installation
# first argument - name of virtual machine
function getvirtinstpid {
	ps -eo pid,args | grep -v grep | grep "$1" | head -1 | awk '{ print $1}'
}

# function to wait for completion of installation of virtual machine
# first argument - name of virtual machine currently installed
function waitforinst {
	echo "Wait till the VM is installed."
	while [ ! -z `getvirtinstpid $1` ]; do
		sleep 30
	done
}

#function for preparing image and installing virtual machine
# $1 - directory to store images
# $2 - name of machine
# $3 - kickstart file
# $4 - repository

function virtinstall {
	#prepare image for ipa-server
	qemu-img create -f raw "$1"/"$2".img 4G

	#install ipa-server vm
	virt-install --connect=qemu:///system \
	    --initrd-inject="$3" \
	    --name="$2" \
	    --cdrom=Fedora-15-x86_64-DVD.iso \
	    --disk "$1"/"$2".img,size=4 \
	    --ram 1024 \
	    --vcpus=2 \
	    --check-cpu \
	    --accelerate \
	    --hvm \
	    --vnc \
	    --os-type=linux \
	    --os-variant=fedora15
#	    --noautoconsole


#	    --extra-args="ks=file:/$3 \
#	      console=tty0 console=ttyS0,115200" \
#	    --location="$4" \
	if [ ! $? -eq 0 ]
	then
		echo "Can not create virtual image!"
		exit 1
	fi
}

# function to generate ssh keys to allow file operations over scp
# 1st argument - name of key
# passphrase is empty
function createsshcert {
	if [ -f $1 ]
	then
		rm -f $1
		rm -f $1.pub
	fi
	echo $1
	ssh-keygen -t rsa -f $1 -N '' -C "ipademo"
}

# function for editing kickstartfile
# first param - template
# second param - output file
# third param - user name
# 4th param - cert name
function prepareks {
	lines=`cat $1 | wc -l`
	lines=$(($lines-2))
	head -$lines $1 > $2
	echo "useradd -K CREATE_HOME=yes $3 -u 1111" >> $2
	echo "echo \"$3\" | passwd $3 --stdin" >> $2
	echo "cd /root/" >> $2
	echo "mkdir --mode=700 .ssh" >> $2
	echo "echo \"`cat $4.pub`\">>.ssh/authorized_keys" >> $2
	echo "chmod 600 .ssh/authorized_keys" >> $2

	echo "cd /home/$3" >> $2
	echo "mkdir --mode=700 .ssh" >> $2
	echo "chown $3 .ssh" >> $2
	echo "echo \"`cat $4.pub`\">>.ssh/authorized_keys" >> $2
	echo "chown $3 .ssh/authorized_keys" >> $2
	echo "chmod 600 .ssh/authorized_keys" >> $2
	
	echo "" >> $2
	# delete requiretty from /etc/sudoers
	echo "mv /etc/sudoers /etc/sudoers_old" >> $2
	echo "cat /etc/sudoers_old | grep -v requiretty > /etc/sudoers" >> $2
	echo "chmod 440 /etc/sudoers" >> $2
	# add user to sudoer list so that he can use sudo without password
	echo "echo \"User_Alias	IPADEMOUSR=$3\" >> /etc/sudoers" >> $2
	echo "echo \"IPADEMOUSR       ALL = NOPASSWD: ALL\" >> /etc/sudoers" >> $2
	# Various authenticaion config changes
	# Fix SELinux context on the newly created authorized_keys file
	echo "restorecon /root/.ssh/authorized_keys" >> $2
	echo "restorecon /home/$3/.ssh/authorized_keys" >> $2
	# Disable root logging in with password
	echo "echo \"PermitRootLogin without-password\" >> /etc/ssh/sshd_config" >> $2
	# close the post section
	tail -2 $1 >> $2
}

# function to check wheter neccessary packages are installed and install them if they're missing
function installdependencies ()
{
	if [ -z `rpm -qa | grep libguestfs-tools-c` ]
	then
		yum -y install "libguestfs-tools-c"
	fi
}

# function for cleaning up messy files
function cleanup ()
{
	while [ ! -z $1 ]; do
		rm -f $1
		shift
	done
	return 0	
}

# function to check whether the user is root
function checkroot ()
{
	if [ `id -u` -ne 0 ] ; then
                echo "Please run as 'root' to execute '$0'!"
                exit 1
        fi
}

#################################################################################
####################
########		END OF FUNCTIONS DEFINITION
####################
#################################################################################

# make all commands visible
#set -x

logfile=ipa-demo.log

# fedora repository
repo=http://download.englab.brq.redhat.com/pub/fedora/linux/releases/15/Fedora/x86_64/os
# directory to store images
imgdir=/var/lib/libvirt/images
# kickstart files for server and clients
ksserver=f15-freeipa-server.ks
ksclient_wiki=f15-freeipa-client-mediawiki.ks
ksclient=f15-freeipa-client.ks

#clinet installation script 
clientsh=freeipa-client-install.sh

# kickstart template files
ksserver_temp=$ksserver.temp
ksclient_wiki_temp=$ksclient_wiki.temp
ksclient_temp=$ksclient.temp

# filename of ssh keys that will be generated by script
cert_filename=sshipademo
# name of user to be created on all of the VMs
user_name=ipademo

hostfile=hosts.txt

# ssh settings for override asking for confirmation when adding ssh key
# THIS OPTION IS VERY INSECURE AND SHOULDN'T BE USED FOR NONDEMONSTRATIVE PURPOSES
sshopt="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
#sshopt="-o StrictHostKeyChecking=no"

# configuration data necessary for installation
servername=f15-ipa-server
serverhostname=master
password=blablabla
realm=EXMPLE.COM
domain=example.com
clientnr=2

# remove file with host's ips and names
if [ -d $hostfile ]
then
	rm -f $hostfile
fi

#############################################
########## DEALING WITH PARAMETERS
#############################################

# parse arguments
while getopts "hd:r:c:" opt; do
	case $opt in
		h) printhelp
		   exit 0
			;;
		d) imgdir=$OPTARG
			;;
		r) repo=$OPTARG
			;;
		c) clientnr=$OPTARG
		   isnumber $clientnr
		   if [ $? -eq 1 ]
		   then
			echo "Number of clients is in bad format! Try to use numbers only."
			exit 1
		   fi
			;;
		\?) echo "This type of argument is not supported!"
		    exit 1
			;;
	esac
done

# check arguments
if [ ! -d $imgdir ]
then
	echo "Directory for storing images doesn't exist!" >&2
	exit 1
fi

if [ ! -f $ksserver_temp ]
then
	echo "Kickstart file for ipa-server missing!" >&2
	exit 1
fi

if [ ! -f $ksclient_wiki_temp ]
then
	echo "Kickstart file for ipa-client missing!" >&2
	exit 1
fi

if [ ! -f $ksclient_temp ]
then
	echo "Kickstart file for ipa-client missing!" >&2
	exit 1
fi

if [ -z $repo ]
then
	echo "You have to specify address of Fedora repository!" >&2
	exit 1
fi

if [ $clientnr -lt 1 ]
then
	echo "Number of clients should be at least 1!" >&2
fi
###############################################
########## END OF ARGUMENTS
###############################################

# check whether user is root
checkroot
# check whether required packages are installed
installdependencies

###############################################
#########
####	Preparing images and install scripts
#########
###############################################

# Prepare certificate for later ssh use
createsshcert $cert_filename > $logfile

prepareks $ksserver_temp $ksserver $user_name $cert_filename

cat $ksserver > $logfile

virtinstall $imgdir $servername $ksserver $repo

echo "Installing server VM"

waitforinst $servername

# start the server
virsh start $servername

# get server ip
echo "Starting the newly created VM."
serverip=`getvmip $servername`

echo "Running installation of freeipa-server on server VM"
# copy server install script to server
cat freeipa-server-install.sh | ssh $sshopt -i $cert_filename $user_name@"$serverip" "cat ->>~/freeipa-server-install.sh" > $logfile

ssh $sshopt $user_name@$serverip -i $cert_filename "sudo sh ~/freeipa-server-install.sh -d $domain -c $serverhostname -r $realm -p $password -e $password" > $logfile

# CLIENTS INSTALLATION

clientcnt=0

while [ $clientcnt -lt $clientnr ]; do
	echo "Installing client $(($clientcnt+1)) of $clientnr"
	clientname="f15-ipa-client-$clientcnt"
	clienthostname="client-$clientcnt"

	if [ $clientcnt -eq 0 ]
	then
		prepareks $ksclient_wiki_temp $ksclient_wiki $user_name $cert_filename
		virtinstall $imgdir $clientname $ksclient_wiki $repo
	else
		prepareks $ksclient_temp $ksclient $user_name $cert_filename
		virtinstall $imgdir $clientname $ksclient $repo
	fi

	# wait untill the installation of VM is done
	echo "Installing client's VM."
	waitforinst $clientname

	# start the client
	virsh start $clientname

	echo "Starting up client's VM."
	clientip=`getvmip $clientname`

	echo "$clientip $clientname" >> $hostfile

	echo "Adding host to IPA domain."
	# add host to IPA
	ssh $sshopt -i $cert_filename $user_name@"$serverip" "sudo ipa host-add $clienthostname.$domain --ip-address=$clientip --password=$password" > $logfile

	echo "Installing freeipa-client on client's VM"
	# copy client install script to client and execute it
	cat $clientsh | ssh $sshopt -i $cert_filename $user_name@"$clientip" "cat ->>~/$clientsh" > $logfile
	ssh $sshopt -i $cert_filename $user_name@"$clientip" "sudo sh ~/$clientsh -d $domain -c $clienthostname -s $serverhostname -p $password -n $serverip" > $logfile
	
	clientcnt=$(($clientcnt + 1))
# end while
done

cleanup $ksserver $ksclient_mediawiki $ksclient

echo ""
echo "DONE!"

echo "Following machines should be running now with freeipa installed:"
echo "Server:"
echo "VM name:$servername"
echo "IP address: $serverip"
echo "root password: rootroot"
echo "Connection via virt-viewer: virt-viewer $servername"
echo "Connection via ssh: ssh $sshopt -i $cert_filename root@$serverip"
echo "Clients:"
cat hosts.txt
