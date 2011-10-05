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
	
	ipaddr=`echo ${ipaddr%?} | cut -c2-`
	
	echo $ipaddr
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
# $1 - repository address
function printHelp {
	echo "Ipa-base-prepare script"
	echo "This script should help you prepare base images to allow you create virtual machines that are ready for FreeIPA installation."
	echo " ATTENTION: You must have libvirt, qemu, qemu-kvm, qemu-img, qemu-system, python-virtinst, openssh-clients, libguestfs-tools-c installed to run the script correctly."
	echo "usage: ipa-demo.sh [-d dir][-r repoaddr][-c clientnr][-h]"
	echo "-h - print help"
	echo "-b - specify one base image  - if you want to use base images that is older or located in different directory then the archive."
	echo "--archive - specify directory containing base images"
	echo "--sshkey - specify private ssh key to be used. It's supposed that public key has the same name with \'.pub\' suffix. The key will be used for connecting to VMs."
	echo "-r - set fedora repository, by default it's: $1"
	echo "ATTENTION: It's strongly recommended to use nearest repository, because the default one is overloaded. Mirrors list is here: http://mirrors.fedoraproject.org/publiclist/Fedora/15/x86_64/"
	echo "--createbase - create base image"
	echo "--updatebase - update base image"
	echo "--installipa - prepare installation image - take actual base image and install freeipa-server with all dependencies into it"
}

# function to get PID - get PID of process which handles virtual machine installation
# first argument - name of virtual machine
function getVirtInstPid {
	ps -eo pid,args | grep -v grep | grep "$1" | head -1 | awk '{ print $1}'
}

# function to wait for completion of installation of virtual machine
# first argument - name of virtual machine currently installed
function waitForInst {
	while [ ! -z `getVirtInstPid $1` ]; do
		sleep 30
	done
}

# function to generate ssh keys to allow file operations over scp
# $1 - name of key
# $2 - log file
# passphrase is empty
function createSshCert {
	if [ -f $1 ]
	then
		rm -f $1
		rm -f $1.pub
	fi

	ssh-keygen -t rsa -f $1 -N '' -C "ipademo" &>> $2
}

#function for preparing image and installing virtual machine
# $1 - directory to store images
# $2 - name of machine
# $3 - kickstart file
# $4 - repository
# $5 - disk size
# $6 - log file

function virtInstall {
	
	#prepare image for ipa-server
	qemu-img create -f qcow2 -o preallocation=metadata "$1" "$5"G &>> $6
	
	if [ ! $? -eq 0 ]
	then
		echo "Can not create virtual image!"
		exit 1
	fi
	
	#install ipa-server vm
	virt-install --connect=qemu:///system \
	    --initrd-inject="$3" \
	    --name="$2" \
	    --extra-args="ks=file:/$3 \
	      console=tty0 console=ttyS0,115200" \
	    --location="$4" \
	    --disk path="$1",format=qcow2 \
	    --ram 1024 \
	    --vcpus=2 \
	    --check-cpu \
	    --accelerate \
	    --hvm \
	    --vnc \
	    --os-type=linux \
	    --noautoconsole &>> $6

# with this option the program won't work on rhel
# 	    --os-variant=fedora15 \

	if [ ! $? -eq 0 ]
	then
		echo "Unable to create virtual machine!"
		exit 1
	fi
}

# function for getting freeipa dependencies withou ds, pki and freeipa pkgs
function getIpaDependency {
	yum deplist freeipa-server | grep -v pki | grep -v freeipa | grep -v dogtag | grep -v 389-ds | grep "dependency:" | awk '{print $2}' | awk -F\( '{print $1}' | tr '\n' ' '
}

# function for editing kickstartfile
# first param - template
# second param - output file
# third param - user name
function prepareKickstart {
	tempfile=tmp
	pkgs=`cat $1 | awk '{if($1=="%packages") print NR}'`
	lines=`cat $1 | wc -l`
	lines=$(($lines-$pkgs))
	head -$pkgs $1 > $tempfile
	echo "" >> $tempfile
	tail -$lines $1 >> $tempfile

	lines=`cat $tempfile | wc -l`
	lines=$(($lines-2))
	head -$lines $tempfile > $2
	
	# install all ipa dependencies except ds, pki a freeipa pkgs
	# bind must be added manually since it's not in ipa dependencies
	echo "yum -y install --enablerepo=updates-testing --nogpgcheck bind bind-dyndb-ldap `getIpaDependency`" >> $2
	
#	echo "useradd -K CREATE_HOME=yes $3 -u 1111" >> $2
#	echo "echo \"$3\" | passwd $3 --stdin" >> $2
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
	tail -2 $tempfile >> $2
	
	#cleanUp
	rm -f $tempfile
}

# function to prepare xml file for virt-image to rerun
# $1 - xml file name
# $2 - vm name
# $3 - relative path to disk image
# $4 - vcpu's number
# $5 - memory
# $6 - architecture
function virtImageXml ()
{
	diskformat=`qemu-img info $3 | grep "file format" | awk '{print $3}'`
	output=$2.xml
	
	(
	printf "<image>\n"
	printf "\t<name>$2</name>\n"
	
	printf "\t<domain>\n"
	
	printf "\t  <boot type=\"hvm\">\n"
	
	printf "\t    <guest>\n"
	printf "\t\t<arch>$6</arch>\n"
	printf "\t    </guest>\n"
	
	printf "\t    <os>\n"
	printf "\t\t<loader dev=\"hd\"/>\n"
	printf "\t    </os>\n"
	
	printf "\t    <drive disk=\"$3\" target=\"hda\"/>\n"
	printf "\t  </boot>\n"
	
	printf "\t  <devices>\n"
	
	printf "\t\t <vcpu>$4</vcpu>\n"
    printf "\t\t <memory>$5</memory>\n"
    printf "\t\t <interface/>\n"
    printf "\t\t <graphics/>\n"
    
	printf "\t </devices>\n"
	
	printf "\t</domain>\n"
	
	# storage setting
	printf "\t<storage>\n"
	printf "\t\t<disk file=\"$3\" format=\"$diskformat\"/>\n"
	printf "\t</storage>\n"
	printf "</image>\n"
	) > $output
	
}

# function to check whether the user is root
function checkRoot ()
{
	if [ `id -u` -ne 0 ]
	then
		echo "Please run as 'root' to execute '$0'!"
		exit 1
    fi
}

# function to check wheter neccessary packages are installed and install them if they're missing
function checkDependencies ()
{
	if [ -z `rpm -qa | grep libguestfs-tools-c` ]
	then
		echo "Package libguestfs-tools-c is missing. You must install it in order to run the script"
		exit 1
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

# function for getting current date
function getDate ()
{
	date +%y%m%d%H%M
}

# function to find last VM
# $1 - date of actual image
# $2 - folder with image archive
# $3 - first part of image name, examp. "f15-ipa-base-image"
function getLastImage()
{
	difference=$1
	for i in `ls $2 | grep $3`; do
		imgdate=`echo $i | awk -F\. '{print $2}'`
		tmp=$(($1 - $imgdate))
		if [ $tmp -lt $difference ]
		then
			difference=$tmp
			result=$imgdate
		fi
	done
	
	if [ $difference -eq $1 ]
	then
		echo ""
	else
		echo "$imgname.$result.qcow2"	
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

#################################################################################
####################
########		END OF FUNCTIONS DEFINITION
####################
#################################################################################

#get full path to working directory, kvm tends to have problem accessing
# disk images when they are defined by relative path
workingdir=`pwd`

# make all commands visible
updatebase=0
createbase=0
installipa=0

# log files
logfile=ipa-base-prepare.log

# file name format: f15-ipa-demo-base.date.qcow2
# file with new image
imgname="f15-ipa-demo-base"
workingimage="$workingdir/ipa-working-image.qcow2"
installimage="$workingdir/ipa-ready-image.qcow2"

# file with base image
baseimg=""

# kickstart files for server and clients
ksserver=f15-freeipa-base.ks

# kickstart template files
ksserver_temp=$ksserver.temp

# filename of ssh keys that will be generated by script
cert_name=sshipademo
cert_folder=cert
cert_filename=""
# name of user to be created on all of the VMs
user_name=ipademo

# ssh settings for override asking for confirmation when adding ssh key
# THIS OPTION IS VERY INSECURE AND SHOULDN'T BE USED FOR NONDEMONSTRATIVE PURPOSES
sshopt="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# configuration data necessary for installation
vmname=f15-ipa-base

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

# fedora repository
repo=http://download.fedoraproject.org/pub/fedora/linux/releases/$osver/Fedora/$arch/os
#repo=http://download.englab.brq.redhat.com/pub/fedora/linux/releases/$osver/Fedora/$arch/os

# name of directory containing archived base images
archive=archive

############

# check whether required packages are installed
checkDependencies
# Check whether user is root
checkRoot

#############################################
########## DEALING WITH PARAMETERS
#############################################

# parse arguments
while [ ! -z $1 ]; do
	case $1 in
	--createbase) createbase=1
			;;
	--updatebase) updatebase=1
			;;
	--installipa) installipa=1
			;;
	-b) if [ -z $2 ]
	    then
		echo "You must specify base image file!"
		exit 1
	    fi
	    baseimage=$2
		shift
		;;
		
	--archive) if [ -z $2 ]
				then
					echo "You must specify archive directory!"
					exit 1
				fi
				archive=$2
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

	-r) repo=$2
		if [ -z $2 ]
		then
			echo "You must specify the repository!"
			exit 1
		fi
		shift
		;;
		
	-h) printHelp $repo
		exit 0
		;;
		
	--help) printHelp $repo
			exit 0
		;;
		
	*) echo "Unknown parameter $1"
	    exit 1
		;;
	esac
	shift
done

# check arguments
if [ ! -f $ksserver_temp ]
then
	echo "Kickstart file for ipa-server missing!" >&2
	exit 1
fi

if [ -z $repo ]
then
	echo "You must specify address of Fedora repository!" >&2
	exit 1
fi

if [ ! $(($createbase + $updatebase + $installipa)) -eq 1 ]
then
		echo "You must select only one operation!"
		exit 1
fi

###############################################
########## END OF ARGUMENTS
###############################################

###############################################
#########
####	Preparing images and install scripts
#########
###############################################

imgfile=$imgname.`getDate`.qcow2

if [ $createbase -eq 1 ]
then
	if [ -z $imgfile ]
	then
		echo "Image file wasn't specified" >&2
		exit 1
	fi

	# create folder for achivation of base images and set it as readable for everyone
	if [ -d $archive ]
	then
		echo "Folder $archive alerady exists! Please specify another folder for archiving base images." >&2
		exit 1
	else
		mkdir $archive
	fi

	chmod a+r $archive
	
	# create new SSH key or check existence of the specified one
	if [ -z "$cert_filename" ]
	then	
		# create folder for saving certificate
		cert_folder=`lastCharInPath $cert_folder`
		
		if [ -d $cert_folder ]
		then
			echo "Folder $cert_folder already exists! Please specify another folder for storing ssh keys!" >&2
			exit 1
		else 
			mkdir $cert_folder
		fi

		cert_filename=$cert_folder/$cert_name

		# create ssh cert in specified folder with specified name
		createSshCert $cert_filename $logfile
		
		# set folder with all containg certificates as readable
		chmod -R 600 $cert_folder
	else
		if [ ! -f $cert_filename ]
		then
			echo "Specified SSH key doesn't exist!" >&2
			exit 1
		fi
	fi

	prepareKickstart $ksserver_temp $ksserver $user_name $cert_filename

	echo "Creating VM and installing system. This action can take several minutes!"
	virtInstall $workingimage $vmname $ksserver $repo $disksize $logfile

	waitForInst $vmname
	
	echo "Saving image in archive!"
	mv $workingimage $archive/$imgfile
	echo "New base image is saved in $archive/$imgfile !"
	
	virsh undefine $vmname &>> $logfile
		
	cleanUp $ksserver
else
	#
	# Update of base image or installation of freeipa-server
	#
	
	currentdate=`getDate`
	
	newbaseimg=$imgname.$currentdate.qcow2
	
	# create folder for saving certificate
	cert_folder=`lastCharInPath $cert_folder`
	
	if [ -z "$cert_filename" ]
	then		
		cert_filename=$cert_folder/$cert_name
	fi
	
	# check existence of SSH key
	if [ ! -f $cert_filename ]
	then
		echo "Certificate $cert_filename doesn't exist!" >&2
		exit 1
	fi
	
	# prepare image for ipa-server
	if [ -z $baseimage ]
	then
		# check existence of archive folder
		if [ ! -d $archive ]
		then
			echo "Folder $archive doesn't exist!" >&2
			exit 1
		fi
		if [ -z "`getLastImage $currentdate $archive $imgname`" ]
		then
			echo "No base images found!" >&2
			exit 1
		fi
		
		qemu-img create -b $archive/`getLastImage $currentdate $archive $imgname` -f qcow2 "$workingimage" &>> $logfile
	else
		qemu-img create -b $baseimage -f qcow2 "$workingimage" &>> $logfile
	fi
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to create working copy of base image!" >&2
		exit 1
	fi
	
	# prepare xml definition of VM that will be used to run system update
	virtImageXml $vmname.xml $vmname $workingimage $vcpu $vram $arch
	
	# start VM defined by XML file
	virt-image $vmname.xml &>> $logfile
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to create VM! Check log file: $logfile" >&2
		exit 1
	fi
	
	# get the machine ip
	echo "Starting VM."
	machineip=`getVmIp $vmname`
	
	waitForStart $machineip $cert_filename $logfile
	
	# update system
	echo "Running system update"
	ssh $sshopt -i $cert_filename root@$machineip 'yum update -y --enablerepo=updates-testing' &>> $logfile
	if [ ! $? -eq 0 ]
	then
		echo "Can not connect to VM." >&2
		exit 1
	fi
	
	# if installation of freeipa-server was chosen
	if [ $installipa -eq 1 ]
	then
		newbaseimg=$workingdir/$installimage
		echo "Installing freeipa-server. This can take several minutes."
		ssh $sshopt -i $cert_filename root@$machineip 'yum install -y --enablerepo=updates-testing freeipa-server' &>> $logfile
	fi
	
	echo "Shuting down the VM"
	ssh $sshopt -i $cert_filename root@$machineip 'shutdown' &>> $logfile
	
	waitForEnd $vmname
	
	echo "Saving new base image!"
	qemu-img convert "$workingimage" -O qcow2 $newbaseimg &>> $logfile
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to save base image!" >&2
		exit 1
	fi
	
	# clean VM used for preparing the machine and also temporary image
	virsh undefine $vmname &>> $logfile
	rm -f $workingimage $vmname.xml
	
	if [ $updatebase -eq 1 ]
	then
		if [ -z $baseimage ]
		then
			mv $newbaseimg $archive/$newbaseimg
			echo "New base image is saved in $archive/$newbaseimg !"
		else
			echo "New base image is saved in `pwd`/$newbaseimg !"
		fi		
	else
		echo "Base image for installation is ready in $newbaseimg !"
	fi
fi

exit 0
