#!/bin/bash

###############################################################################
#############
####		FUNCTIONS DEFINITION
#############
###############################################################################

# function to get ip address of VM
# $1 - name of VM
function getVmIp ()
{
	macaddr=`virsh dumpxml $1 | grep "mac address" | awk -F\' '{print $2}'`
	
	ipaddr=`arp -an | grep $macaddr`

	while [ -z "$ipaddr" ]; do
		sleep 10
		ipaddr=`arp -an | grep $macaddr | awk '{print $2}'`
	done
	
	ipaddr=`echo ${ipaddr%?}`
	ipaddr=`echo $ipaddr | cut -c2-`
	
	echo $ipaddr
}

# function to check whether variable really contains number
# first parametr - variable to check
function isNumber {
	if [ -z `echo $1 | grep "^[0-9]*$"` ]
	then
		return 1;
	else
		return 0;
	fi
}

# function that prints help
# $1 - default name of base image
# $2 - default directory to store images
# $3 - default clients count
function printHelp {
	echo "Ipa-demo installation script"
	echo "This script should help you through setting up freeipa server and client in order to be able to try it out."
	echo " ATTENTION: You must have libvirt, qemu, qemu-kvm, qemu-img, qemu-system, python-virtinst, openssh-clients, libguestfs-tools-c installed to run the script correctly."
	echo "usage: ipa-demo.sh [--imgdir dir][--sshkey keyfile][-clients clientnr][--base baseimg][-h|--help]"
	echo "-h,--help - print help"
	echo "--imgdir - set directory to store images. By default \"$2\"."
	echo "--sshkey - specify sshkey for connecting to the VMs. (Must be the same that was used during creation of base image."
	echo "--base - specify the base image. By default script assumes existence of base image called \"$1\" in current directory."
	echo "--clients - number of client VMs to be created. By default $3."

}

# function to prepare xml file for virt-image to rerun
# $1 - vm name
# $2 - relative path to disk image
# $3 - vcpu's number
# $4 - memory
# $5 - architecture
function virtImageXml ()
{
	diskformat=`qemu-img info $2 | grep "file format" | awk '{print $3}'`
	output=$1.xml
	
	(
	printf "<image>\n"
	printf "\t<name>$1</name>\n"
	
	printf "\t<domain>\n"
	
	printf "\t  <boot type=\"hvm\">\n"
	
	printf "\t    <guest>\n"
	printf "\t\t<arch>$5</arch>\n"
	printf "\t    </guest>\n"
	
	printf "\t    <os>\n"
	printf "\t\t<loader dev=\"hd\"/>\n"
	printf "\t    </os>\n"
	
	printf "\t    <drive disk=\"$2\" target=\"hda\"/>\n"
	printf "\t  </boot>\n"
	
	printf "\t  <devices>\n"
	
	printf "\t\t <vcpu>$3</vcpu>\n"
    printf "\t\t <memory>$4</memory>\n"
    printf "\t\t <interface/>\n"
    printf "\t\t <graphics/>\n"
    
	printf "\t </devices>\n"
	
	printf "\t</domain>\n"
	
	# storage setting
	printf "\t<storage>\n"
	printf "\t\t<disk file=\"$2\" format=\"$diskformat\"/>\n"
	printf "\t</storage>\n"
	printf "</image>\n"
	) > $output
	
}

# function to check wheter neccessary packages are installed and install them if they're missing
function checkDependencies ()
{
	if [ -z `rpm -qa | grep libguestfs-tools-c` ]
	then
		yum -y install "libguestfs-tools-c"
	fi
}

# function for cleaning up messy files
function cleanUp ()
{
	while [ ! -z $1 ]; do
		rm -f $1
		shift
	done
	return 0	
}

# function to check whether the user is root
function checkRoot ()
{
	if [ `id -u` -ne 0 ] ; then
                echo "Please run as 'root' to execute '$0'!"
                exit 1
        fi
}

# cuts off last backslach in directory address - just to make it compatible
# $1 - address to be checked
function lastCharInPath()
{
	if [ "${1: -1}" == "/" ]
	then
		echo ${1%?}
	else
		echo $1
	fi
}

# function for getting current date
function getDate ()
{
	date +%y%m%d%H%M
}

# function for detecting when the VM is running and ready to execute commands
# $1 - VM's ip address
# $2 - certificate location
function waitForStart ()
{
	flag=255
	while [ ! $flag -eq 0 ]; do
		sleep 10
		ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $2 root@$1 'exit' &> /dev/null
		flag=$?
	done
}

# function for waiting untill the VM is shutdown correctly
# $1 - VM name
function waitForEnd ()
{
	while [ -z "`virsh list --inactive | grep $1`" ]; do
		sleep 10
	done
}

# function for checking whether the provided path is a web address
checkForWebAddress ()
{
	http=`echo $1 | grep "^http[s]\{0,1\}://[a-zA-Z0-9]\{1,\}"`
	ftp=`echo $1 | grep \"^ftp://[a-zA-Z0-9]\{1,\}\"`
	
	if [ -z "$http" -a -z "$ftp" ]
	then
		return 0
	else
		return 1
	fi
	return 0
}

# function for creating disk images based on base image
# $1 - base image location
# $2 - new image
# $3 - log file
function createDiskImage ()
{
	if [ -f "$2" ]
	then
		echo "Image file $2 already exists!" >&2
		exit 1
	fi
	qemu-img create -b $1 -f qcow2 "$2" &>> $3
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to create VM's disk image! Check log file: $3"
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

# working directory
workingdir=`pwd`
# file for storing logs
logfile=ipa-demo.log
# directory to store images
imgdir=/var/lib/libvirt/images

#server installation script
serversh=freeipa-server-install.sh
#clinet installation script 
clientsh=freeipa-client-install.sh

# filename of ssh keys that will be generated by script
cert_name=sshipademo
cert_folder=`pwd`/cert
cert_filename=""

# base image file
installimage="ipa-ready-image.qcow2"
baseimage=""

# file containg VM names and ip addresses
hostfile=hosts.txt

# ssh settings for override asking for confirmation when adding ssh key
# THIS OPTION IS VERY INSECURE AND SHOULDN'T BE USED FOR NONDEMONSTRATIVE PURPOSES
sshopt="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# configuration data necessary for installation
user_name=ipademo
servername=f15-ipa-server
serverhostname=master
password=secret123
realm=EXAMPLE.COM
domain=example.com
clientnr=2

# number of cpu's used by virtual machine
vcpu=1
# availible ram ( 1 gb = 1048576 )
vram=1048576
# architecture
arch=x86_64
# fedora os version
osver=15
# disk size
disksize=10

# remove file with host's ips and names
if [ -f $hostfile ]
then
	rm -f $hostfile
fi

# Add header to log file for current task
echo "" &>> $logfile
echo "NEW RECORD, date:`getDate`" &>> $logfile
echo "" &>> $logfile

#############################################
## WELCOME MESSAGE
#############################################
echo "Welcome to IPA-DEMO script for automatic setting up of VM's enviroment and installation of freeipa-server and -clients."


#############################################
########## DEALING WITH PARAMETERS
#############################################

# parse arguments
while [ ! -z $1 ]; do
	case $1 in
	--base) if [ -z $2 ]
			then
				echo "You must specify the base image file!"
				exit 1
			fi
			baseimage=$2
			shift
			;;

	--sshkey) 
				if [ -z $2 ]
				then
					echo "You must specify the ssh key!"
					exit 1
				fi
				cert_filename=$2
				shift
				;;
	--imgdir) 
				if [ -z $2 ]
				then
					echo "You must specify the directory for saving images!"
					exit 1
				fi
				imgdir=$2
				shift
				;;
	
	--clients) 
				if [ -z $2 ]
				then
					echo "You must specify the number of clients!"
					exit 1
				fi
				clientnr=$2
				shift
				;;

	-h) printHelp $installimage $imgdir $clientnr
		exit 0
		;;
		
	--help) printHelp $installimage $imgdir $clientnr
			exit 0
		;;
		
	*) echo "Unknown parameter $1"
	    exit 1
		;;
	esac
	shift
done

# check arguments
if [ ! -d $imgdir ]
then
	echo "Directory for storing images doesn't exist!" >&2
	exit 1
fi

# get full path to image dir
cd $imgdir
imgdir=`pwd`
cd $workingdir

isNumber $clientnr
if [ $? -eq 1 ]
then
	echo "Number of clients is in bad format! Try to use numbers only."
	exit 1
fi

if [ $clientnr -lt 1 ]
then
	echo "Number of clients should be at least 1!" >&2
	exit 1
fi
###############################################
########## END OF ARGUMENTS
###############################################

# check whether user is root
checkRoot
# check whether required packages are installed
checkDependencies

###############################################
######### FIND BASEIMAGE AND CERTIFICATE
###############################################

printf "Loading base image\n"
if [ -z "$baseimage" ]
then
	if [ -f $installimage ]
	then
		printf "\tMoving base image to the same directory that should contain VM's images: $imgdir\n"
		mv $installimage $imgdir/$installimage
		baseimage=$imgdir/$installimage
	elif [ -f "$imgdir/$installimage" ]
	then
		baseimage=$imgdir/$installimage
	else
		echo "Cannot find base image" >&2
		exit 1
	fi
else
	baseimage=`lastCharInPath $baseimage`
	checkForWebAddress $baseimage
	if [ $? -eq 1 ]
	then
		printf "\tDownloading base image:\n"
		wget $baseimage -O $imgdir/$installimage
		if [ ! $? -eq 0 ]
		then
			echo "Can not get base image!" >&2
			exit 1
		fi
		baseimage=$imgdir/$installimage
	else
		if [ ! -f $baseimage ]
		then
			echo "Can't find base image!" >&2
			exit 1
		else
			printf "\tMoving base image to the same directory that should contain VM's images: $imgdir\n"
			mv $baseimage $imgdir/$installimage
			baseimage=$imgdir/$installimage
		fi
	fi
fi

printf "Loading SSH key\n"
# find certificate
if [ -z "$cert_filename" ]
then
	if [ ! -f "$cert_folder/$cert_name" ]
	then
		echo "Cannot find SSH key!" >&2
		exit 1
	else
		cert_filename="$cert_folder/$cert_name"
	fi
else
	checkForWebAddress $cert_filename
	if [ $? -eq 1 ]
	then
		printf "\t\tDownloading ssh key:"
		wget $cert_filename -O $cert_name
		if [ ! $? -eq 0 ]
		then
			echo "Can not get SSH key!" >&2
			exit 1
		fi
		cert_filename=$cert_name
	else
		if [ ! -f $cert_filename ]
		then
			echo "Cannot find SSH key!" >&2
			exit 1
		fi
	fi
fi

###############################################
#########
####	Preparing VMs and install scripts
#########
###############################################

printf "Creating server virtual machine\n"
printf "\t[1/5] Creating disk image for server VM\n"
# create disk image for new VM
createDiskImage $baseimage "$imgdir/$servername.qcow2" $logfile
printf "\t[2/5] Creating definition file for server VM\n"
# prepare xml definition of VM that will be used to run system update
virtImageXml $servername "$imgdir/$servername.qcow2" $vcpu $vram $arch
printf "\t[3/5] Starting server VM\n"
# start VM defined by XML file
virt-image $servername.xml &>> $logfile

if [ ! $? -eq 0 ]
then
	echo "Unable to create VM! Check log file: $logfile"
	exit 1
fi

# get server ip
serverip=`getVmIp $servername`

waitForStart $serverip $cert_filename $logfile

printf "\t[4/5] Installing freeipa-server on server VM. This could take few minutes\n"
# copy server install script to server
cat freeipa-server-install.sh | ssh $sshopt -i $cert_filename root@"$serverip" "cat ->>~/freeipa-server-install.sh" &>> $logfile

if [ ! $? -eq 0 ]
then
	echo "Unable to connect to VM." >&2
	exit 1
fi

# install freeipa-server
ssh $sshopt root@$serverip -i $cert_filename "sudo sh ~/freeipa-server-install.sh -d $domain -c $serverhostname -r $realm -p $password -e $password" &>> $logfile

# remove xml file
rm -f $servername.xml

printf "\t[5/5] Adding 'ipademo' user \n"
# add user ipademo to freeipa
ssh $sshopt root@$serverip -i $cert_filename "printf \"$user_name\n$user_name\" | sudo ipa user-add $user_name --first=ipa --last=demo --password" &>> $logfile

printf "\tServer installation done\n"

# CLIENTS INSTALLATION

clientcnt=0

while [ $clientcnt -lt $clientnr ]; do
	echo "Installing client $(($clientcnt+1)) of $clientnr"
	clientname="f15-ipa-client-$clientcnt"
	clienthostname="client-$clientcnt"
	
	printf "\t[1/5] Creating disk image for client VM\n"
	# create disk image for new VM
	createDiskImage $baseimage "$imgdir/$clientname.qcow2" $logfile
	printf "\t[2/5] Creating definition file for server VM\n"
	# prepare xml definition of VM that will be used to run system update
	virtImageXml $clientname "$imgdir/$clientname.qcow2" $vcpu $vram $arch
	printf "\t[3/5] Starting server VM\n"
	# start VM defined by XML file
	virt-image $clientname.xml &>> $logfile

	if [ ! $? -eq 0 ]
	then
		echo "Unable to create VM! Check log file: $logfile"
		exit 1
	fi

	# get server ip
	clientip=`getVmIp $clientname`

	waitForStart $clientip $cert_filename $logfile

	echo "VM name: $clientname" >> $hostfile
	echo "IP address: $clientip" >> $hostfile
	echo "Username: $user_name" >> $hostfile
	echo "User password: $password" >> $hostfile
	echo "Connection via virt-viewer: virt-viewer $clientname" >> $hostfile
	echo "Connection via ssh: ssh $sshopt $user_name@$clientip" >> $hostfile
	echo "" >> $hostfile

	printf "\t[4/5] Adding machine to IPA domain\n"
	# add host to IPA
	ssh $sshopt -i $cert_filename root@"$serverip" "ipa host-add $clienthostname.$domain --ip-address=$clientip --password=$password" &>> $logfile
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to connect to the server VM." >&2
		exit 1
	fi

	printf "\t[5/5] Installing freeipa-client on client's VM\n"
	# copy client install script to client and execute it
	cat $clientsh | ssh $sshopt -i $cert_filename root@"$clientip" "cat ->>~/$clientsh" &>> $logfile
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to connect to the client VM." >&2
		exit 1
	fi
	
	ssh $sshopt -i $cert_filename root@"$clientip" "sh ~/$clientsh -d $domain -c $clienthostname -s $serverhostname -p $password -n $serverip" &>> $logfile
	
	# set password for user 'ipademo'
	if [ $clientcnt -eq 0 ]
	then
		printf "\t\tSetting password for user 'ipademo'\n"
		# give the machine time to reboot
		sleep 10
		# wait until it's ready
		waitForStart $clientip $cert_filename $logfile
		# change the user password
		ssh $sshopt -i $cert_filename root@"$clientip" "printf \"$user_name\n$password\n$password\n\" | kinit $user_name" &>> $logfile
		if [ ! $? -eq 0 ]
		then
			echo "Unable to set password for user $user_name. You'll have to set it manually by connecting to any client via ssh under user name $user_name. Initial password is $user_name." >&2
		fi
	fi
	
	echo "Client-$clientcnt installation done."
	clientcnt=$(($clientcnt + 1))
	rm -f $clientname.xml
# end while
done

echo ""
echo "DONE!"

echo "Following machines should be running now with freeipa installed:"
echo "Server:"
echo "VM name:$servername"
echo "IP address: $serverip"
echo "root password: rootroot"
echo "Connection via virt-viewer: virt-viewer $servername"
echo "Connection via ssh: ssh $sshopt -i $cert_filename root@$serverip"
echo ""
echo "Clients:"
echo "Root password for all clients: rootroot"
echo "Ipademo user password to be used in kinit: ipademo"
echo ""
cat $hostfile
