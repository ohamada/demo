#!/bin/bash

###############################################################################
#############
####		VARIABLE DEFINITION
#############
###############################################################################

# working directory
WORKINGDIR=`pwd`
DATADIR=$WORKINGDIR/data
# directory to store images
IMGDIR=/var/lib/libvirt/images

# filename of ssh keys that will be generated by script
SSHKEY_NAME=sshipademo
SSHKEY_FOLDER=$WORKINGDIR/cert
SSHKEY_FILENAME=""

# base image file
BASEIMAGE=""

# configuration data necessary for installation
BASEMACHINE_NAME=ipademo-base

# kickstart file
KSFILE=$DATADIR/f15-freeipa-base.ks

# file containg VM names and ip addresses
HOSTFILE=hosts.txt

# ssh settings for override asking for confirmation when adding ssh key
# THIS OPTION IS VERY INSECURE AND SHOULDN'T BE USED FOR NONDEMONSTRATIVE PURPOSES
SSHOPT="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

#server installation script
SERVERSH=freeipa-server-install.sh
LOCALSERVERSH=$DATADIR/$SERVERSH
#clinet installation script 
CLIENTSH=freeipa-client-install.sh
LOCALCLIENTSH=$DATADIR/$CLIENTSH

# file name format: ipademo-base.date.qcow2
# file with new image
IMGNAME="ipa-demo-base-image"
TEMPIMAGE_PATTERN="ipa-working-image"
INSTALLIMAGE="ipa-ready-image.qcow2"

# configuration data necessary for installation
USERNAME=ipademo
SERVERNAME=ipademo-server
SERVERHOSTNAME=master
PASSWORD=secret123
REALM=EXAMPLE.COM
DOMAIN=example.com
CLIENTNR=2
CLIENTBASENAME=ipademo-client

# number of cpu's used by virtual machine
VCPU=1
# availible ram in MiB
VRAM=1024
# ARCHitecture
ARCH=x86_64
# fedora os version
OSVERSION=22
# fedora flavour
FLAVOR=Workstation
# disk size
DISKSIZE=10

# fedora repository
OSREPOSITORY=http://download.fedoraproject.org/pub/fedora/linux/releases/$OSVERSION/$FLAVOR/$ARCH/os

# make all commands visible
CREATEBASE=0
UPDATEBASE=0
VMONLY=0
ALL=1

###############################################################################
#############
####		FUNCTIONS DEFINITION
#############
###############################################################################

# function to get ip address of VM
# $1 - name of VM
function getVmIp ()
{
    local LANG=en_US
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
	echo " ATTENTION: You must have libvirt, qemu, qemu-kvm, qemu-img, qemu-system, python-virtinst, openssh-clients installed to run the script correctly."
	echo -e "usage: ipa-demo.sh [--base BASEIMAGE][--imgdir IMGDIR][--sshkey KEYFILE][--clients CLIENTNR][--repo REPOSITORY][--createbase]\n\t[--updatebase][--vmsonly][-h|--help]"
	echo "-h,--help - print help"
	echo "--imgdir - set directory to store images. By default \"$2\"."
	echo "--sshkey - specify sshkey for connecting to the VMs. (Must be the same that was used during creation of base image."
	echo "--base - specify the base image. By default script assumes existence of base image called \"$1\" in current directory."
	echo "--clients - number of client VMs to be created. By default $3."
	echo "--repo - URL address of Fedora installation repository, see README for more information."
	echo "--createbase - prepare only base image."
	echo "--updatebase - update base image. ATTENTION: all virtual machine images that derived from the base image will get corrupt and unusable."
	echo "--vmsonly - install only virtual machines (base image and ssh keys must already exist)."
}

# function to prepare xml file for virt-image to rerun
# $1 - vm name
# $2 - relative path to disk image
# $3 - virtual cpu's number
# $4 - memory
# $5 - architecture
function virtImageXml ()
{
	#diskformat=`qemu-img info $2 | grep "file format" | awk '{print $3}'`
	diskformat=qcow2
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

# function for cleaning up messy files
function cleanUp ()
{
	while [ ! -z $1 ]; do
		rm -f $1 &>> $LOGFILE
		shift
	done
	return 0	
}

# function for cleaning up VM's and their images
function cleanVMs ()
{
	if [ ! -z "`virsh list | grep $SERVERNAME`" ]
	then
		if [ ! -z "`virsh list --all | grep $SERVERNAME`" ]
		then
			virsh destroy $SERVERNAME &>> $LOGFILE
		fi
		virsh undefine $SERVERNAME &>> $LOGFILE
		rm -f $IMGDIR/$SERVERNAME.qcow2 &>> $LOGFILE
	fi
	
	for i in `virsh list | grep $CLIENTBASENAME`; do
		tmp=`echo $i | awk '{print $2}'`
		if [ "running" == "`echo $i | awk '{print $3}'`" ]
		then
			virsh destroy $tmp &>> $LOGFILE
		fi
		virsh undefine $tmp &>> $LOGFILE
		rm -f $IMGDIR/$tmp.qcow2 &>> $LOGFILE
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
function checkForWebAddress ()
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

# function for checking/creating name of new virtual machine
# $1 - name template of the machine
function createMachineName ()
{
    CDN_CNT=2
    if [ ! -z "`virsh list --all | grep $1`" ]
    then
        while [ ! -z "`virsh list --all | grep $CDN_CNT-$1`" ]; do
            CDN_CNT=$(($CDN_CNT+1))
        done
        echo $CDN_CNT-$1
    else
        echo $1
    fi
}

# function for checking/creating disk images names
# $1 - disk name
function createDiskName ()
{
    CDN_CNT=2
    if [ -f $IMGDIR/$1.qcow2 ]
    then
        while [ -f $IMGDIR/$1-$CDN_CNT.qcow2 ]; do
            CDN_CNT=$(($CDN_CNT+1))
        done
        echo $IMGDIR/$1-$CDN_CNT.qcow2
    else
        echo $IMGDIR/$1.qcow2
    fi    
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

	if [ ! -d $SSHKEY_FOLDER ]
	then
		mkdir $SSHKEY_FOLDER
	fi

	ssh-keygen -t rsa -f $1 -N '' -C "ipademo" &>> $2
	if [ ! $? -eq 0 ]
	then
		echo "Unable to generate SSH key!" &>> $2
		exit 1
	fi
}

#function for preparing image and installing virtual machine
# $1 - directory to store images
# $2 - name of machine
# $3 - kickstart file
# $4 - os repository
# $5 - disk size
# $6 - ssh key
# $7 - log file

function virtInstall {
	
	#prepare image for ipa-server
	qemu-img create -f qcow2 -o preallocation=metadata "$1" "$5"G &>> $7
	
	if [ ! $? -eq 0 ]
	then
		echo "Can not create virtual image!"
		exit 1
	fi
	
	#install ipa-server vm
	virt-install --connect=qemu:///system \
	    --initrd-inject="$3" \
	    --name="$2" \
	    --extra-args="ks=file:/$(basename $3) \
	      console=tty0 console=ttyS0,115200 ssh_key='$(cat "$6".pub)'" \
	    --location="$4" \
	    --disk path="$1",format=qcow2 \
	    --ram 1024 \
	    --vcpus=2 \
	    --check-cpu \
	    --accelerate \
	    --hvm \
	    --os-type=linux \
	    --graphics none \
	    --noreboot &>> $LOGFILE


# with this option the program won't work on rhel
# 	    --os-variant=fedora15 \

	if [ ! $? -eq 0 ]
	then
		echo "Unable to create virtual machine!"
		virsh undefine $2
		rm -f $1
		exit 1
	fi
}


#function for cloning an image and preparing a virtual machine
# $1 - original image file
# $2 - resulting snapshot image
# $3 - name of machine
# $4 - number of cpus
# $5 - MiBs of memory
# $6 - architecture
# $7 - log file
function virtCreate ()
{
	if [ -f "$2" ]
	then
		echo "Image file $2 already exists!" >&2
		exit 1
	fi
	qemu-img create -b $1 -f qcow2 "$2" &>> $7

	if [ ! $? -eq 0 ]
	then
		echo "Unable to create VM's disk image! Check log file: $7"
		exit 1
	fi

	#install ipa-server vm
	virt-install --connect=qemu:///system \
	    --name="$3" \
	    --disk path="$2" \
	    --ram $5 \
	    --vcpus=$4 \
	    --arch $6 \
	    --check-cpu \
	    --accelerate \
	    --hvm \
	    --os-type=linux \
	    --graphics vnc \
	    --boot hd \
	    --noautoconsole &>> $7 \

	if [ ! $? -eq 0 ]
	then
		echo "Unable to create VM! Check log file: $7" >&2
		cleanVMs $3
		cleanUp $2
		exit 1
	fi
}

function createBaseImage ()
{
    printf "Creating base image\n"

    VMNAME=`createMachineName $BASEMACHINE_NAME`

	printf "\t[1/2] Creating virtual machine. This action can take several minutes!\n"
	virtInstall $TEMPORARYIMAGE $VMNAME $KSFILE $OSREPOSITORY $DISKSIZE $SSHKEY_FILENAME $LOGFILE

	printf "\t[2/2] Saving image into $IMGFILE\n"
	mv $TEMPORARYIMAGE $IMGFILE
	
    virsh undefine $VMNAME

	echo "Finished! New base image is saved in $IMGFILE !"
}

# function for copying installation scripts to the base image
function updateBaseImage ()
{
    printf "Updating base image\n"

    VMNAME=`createMachineName $BASEMACHINE_NAME`

	printf "\t[1/7] Creating and starting server VM\n"
	virtCreate $IMGFILE $TEMPORARYIMAGE $VMNAME $VCPU $VRAM $ARCH $LOGFILE
	
	# get the machine ip
	printf "\t[2/7] Starting virtual machine\n"
	MACHINEIP=`getVmIp $VMNAME`
	
	waitForStart $MACHINEIP $SSHKEY_FILENAME $LOGFILE
	
	if [ ! $? -eq 0 ]
	then
		echo "Unable to create working copy of base image!" >&2
		rm -f $TEMPORARYIMAGE
		exit 1
	fi

    printf "\t[3/7] Updating VM's system\n"
    ssh $SSHOPT -i $SSHKEY_FILENAME root@$MACHINEIP 'dnf update -y --enablerepo=updates-testing' &>> $LOGFILE
	if [ ! $? -eq 0 ]
	then
		echo "Can not connect to VM." >&2
		cleanVMs $VMNAME
		exit 1
	fi

    printf "\t[4/7] Copying installation scripts to the VM\n"
    # copy server install script to server
    cat $LOCALSERVERSH | ssh $SSHOPT -i $SSHKEY_FILENAME root@"$MACHINEIP" "cat >~/$SERVERSH" &>> $LOGFILE
    if [ ! $? -eq 0 ]
    then
        echo "Unable to connect to VM." >&2
        cleanVMs $VMNAME
        cleanUp $TEMPORARYIMAGE
        exit 1
    fi

    # copy client install script to client and execute it
    cat $LOCALCLIENTSH | ssh $SSHOPT -i $SSHKEY_FILENAME root@"$MACHINEIP" "cat >~/$CLIENTSH" &>> $LOGFILE
    if [ ! $? -eq 0 ]
    then
        echo "Unable to connect to the client VM." >&2
        cleanVMs $VMNAME
        cleanUp $TEMPORARYIMAGE
        exit 1
    fi

    printf "\t[5/7] Shuting down the VM\n"
	ssh $SSHOPT -i $SSHKEY_FILENAME root@$MACHINEIP 'shutdown' &>> $LOGFILE

	waitForEnd $VMNAME

    TEMPORARYIMAGE_2=`createDiskName $TEMPIMAGE_PATTERN`

	printf "\t[6/7] Saving new base image\n"
	qemu-img convert $TEMPORARYIMAGE -O qcow2 $TEMPORARYIMAGE_2 &>> $LOGFILE

	if [ ! $? -eq 0 ]
	then
		echo "Unable to save base image!" >&2
		cleanVMs $VMNAME
		cleanUp $TEMPORARYIMAGE_2 $TEMPORARYIMAGE
		exit 1
	fi

	printf "\t[7/7] Cleaning up\n"
	# clean VM used for preparing the machine and also temporary image
	virsh undefine $VMNAME &>> $LOGFILE
	cleanUp $TEMPORARYIMAGE $IMGFILE
    # save the newly updated base image under the name of base image
    mv $TEMPORARYIMAGE_2 $IMGFILE
    cleanUp $TEMPORARYIMAGE_
	
    echo "Finished: Base image for installation is ready in $IMGFILE"
}

function createEnvironment ()
{
    printf "Creating VM environment\n"

    printf "Creating FreeIPA server machine\n"

    printf "\t[1/3] Creating and starting server VM\n"
    virtCreate $IMGFILE "$IMGDIR/$SERVERNAME.qcow2" $SERVERNAME $VCPU $VRAM $ARCH $LOGFILE

    # get server ip
    SERVERIP=`getVmIp $SERVERNAME`

    waitForStart $SERVERIP $SSHKEY_FILENAME $LOGFILE

    printf "\t[2/3] Installing freeipa-server on server VM. This could take few minutes\n"
    # install freeipa-server
    ssh $SSHOPT root@$SERVERIP -i $SSHKEY_FILENAME "sh ~/$SERVERSH -d $DOMAIN -c $SERVERHOSTNAME -r $REALM -p $PASSWORD -e $PASSWORD" &>> $LOGFILE

    if [ ! $? -eq 0 ]
    then
        echo "Installation of freeipa-server failed." >&2
        printf "\n\nipaserver-install.log output:\n\n" >> $LOGFILE
        ssh $SSHOPT root@$SERVERIP -i $SSHKEY_FILENAME "cat /var/log/ipaserver-install.log" &>> $LOGFILE
        printf "\n\n/var/log/messages output:\n\n" >> $LOGFILE
        ssh $SSHOPT root@$SERVERIP -i $SSHKEY_FILENAME "cat /var/log/messages" &>> $LOGFILE
        cleanVMs
        exit 1
    fi

    printf "\t[3/3] Adding '$USERNAME' user \n"
    # add user ipademo to freeipa
    ssh $SSHOPT root@$SERVERIP -i $SSHKEY_FILENAME "printf \"$USERNAME\n$USERNAME\" | sudo ipa user-add $USERNAME --first=ipa --last=demo --password" &>> $LOGFILE

    if [ ! $? -eq 0 ]
    then
        echo "User $USERNAME can't be added. Installation will skip this step." >&2
    fi


    printf "Server installation done\n"

    # CLIENTS INSTALLATION

    CLIENTCNT=0

    while [ $CLIENTCNT -lt $CLIENTNR ]; do
        echo "Installing client $(($CLIENTCNT+1)) of $CLIENTNR"
        CLIENTNAME=`createMachineName $CLIENTBASENAME-$CLIENTCNT`
        CLIENTHOSTNAME="client-$CLIENTCNT"

        printf "\t[1/3] Creating and starting client VM\n"
        virtCreate $IMGFILE "$IMGDIR/$CLIENTNAME.qcow2" $CLIENTNAME $VCPU $VRAM $ARCH $LOGFILE
        
        # get server ip
        CLIENTIP=`getVmIp $CLIENTNAME`

        waitForStart $CLIENTIP $SSHKEY_FILENAME $LOGFILE

        echo "VM name: $CLIENTNAME" >> $HOSTFILE
        echo "IP address: $CLIENTIP" >> $HOSTFILE
        echo "Username: $USERNAME" >> $HOSTFILE
        echo "User password: $PASSWORD" >> $HOSTFILE
        echo "Connection via virt-viewer: virt-viewer $CLIENTNAME" >> $HOSTFILE
        echo "Connection via ssh: ssh $SSHOPT $USERNAME@$CLIENTIP" >> $HOSTFILE
        echo "" >> $HOSTFILE

        printf "\t[2/3] Adding machine to IPA DOMAIN\n"
        # add host to IPA
        ssh $SSHOPT -i $SSHKEY_FILENAME root@"$SERVERIP" "ipa host-add $CLIENTHOSTNAME.$DOMAIN --ip-address=$CLIENTIP --password=$PASSWORD" &>> $LOGFILE
        
        if [ ! $? -eq 0 ]
        then
            echo "Unable to connect to the server VM." >&2
            cleanVMs
            exit 1
        fi

        printf "\t[3/3] Installing freeipa-client on client's VM\n"
        
        ssh $SSHOPT -i $SSHKEY_FILENAME root@"$CLIENTIP" "sh ~/$CLIENTSH -d $DOMAIN -c $CLIENTHOSTNAME -s $SERVERHOSTNAME -p $PASSWORD -n $SERVERIP" &>> $LOGFILE

        if [ ! $? -eq 0 ]
        then
            echo "Unable to install freeipa-client on the client VM." >&2
            printf "\n\n/var/log/ipaclient-install.log\n\n" &>> $LOGFILE
            ssh $SSHOPT -i $SSHKEY_FILENAME root@"$CLIENTIP" "cat /var/log/ipaclient-install.log" &>> $LOGFILE
            printf "\n\n/var/log/messages\n\n" &>> $LOGFILE
            ssh $SSHOPT -i $SSHKEY_FILENAME root@"$CLIENTIP" "cat /var/log/messages" &>> $LOGFILE
            cleanVMs
            exit 1
        fi
        
        # set PASSWORD for user 'ipademo'
        if [ $CLIENTCNT -eq 0 ]
        then
            printf "\t\tSetting password for user 'ipademo'\n"
            # give the machine time to reboot
            sleep 10
            # wait until it's ready
            waitForStart $CLIENTIP $SSHKEY_FILENAME $LOGFILE
            # change the user PASSWORD
            ssh $SSHOPT -i $SSHKEY_FILENAME root@"$CLIENTIP" "printf \"$USERNAME\n$PASSWORD\n$PASSWORD\n\" | kinit $USERNAME" &>> $LOGFILE
            if [ ! $? -eq 0 ]
            then
                echo "Unable to set password for user $USERNAME. You'll have to set it manually by connecting to any client via ssh under user name $USERNAME. Initial PASSWORD is $USERNAME." >&2
            fi
        fi
        
        # need to reboot in order to allow ipademo user using graphical desktop environmnet
        ssh $SSHOPT -i $SSHKEY_FILENAME root@"$CLIENTIP" "reboot"

        echo "Client-$CLIENTCNT installation done."
        CLIENTCNT=$(($CLIENTCNT + 1))
    # end while
    done

    echo ""
    echo "DONE!"

    echo "Following machines should be running now with freeipa installed:"
    echo "Server:"
    echo "VM name:$SERVERNAME"
    echo "IP address: $SERVERIP"
    echo "root password: rootroot"
    echo "Connection via virt-viewer: virt-viewer $SERVERNAME"
    echo "Connection via ssh: ssh $SSHOPT -i $SSHKEY_FILENAME root@$SERVERIP"
    echo ""
    echo "Clients:"
    echo "Root PASSWORD for all clients: rootroot"
    echo "Ipademo user password to be used in kinit: $PASSWORD"
    echo ""
    cat $HOSTFILE
}

#################################################################################
####################
########		END OF FUNCTIONS DEFINITION
####################
#################################################################################


#################################################################################
#############################################
## START OF PROGRAM
#############################################

# make all commands visible
#set -x

# check whether user is root
checkRoot

# file for storing logs
LOGFILE=ipa-demo-`getDate`.log

# Add header to log file for current task
echo "" &>> $LOGFILE
echo "NEW RECORD, date:`getDate`" &>> $LOGFILE
echo "" &>> $LOGFILE

## WELCOME MESSAGE
echo "Welcome to IPA-DEMO script for automatic setting up of VM's enviroment and installation of freeipa-server and -clients."

#############################################
########## DEALING WITH PARAMETERS
#############################################

# parse arguments
while [ ! -z $1 ]; do
	case $1 in
	--base)
                if [ -z $2 ]
                then
                    echo "You must specify the base image file!"
                    exit 1
                fi
                BASEIMAGE=$2
                shift
                ;;
	--sshkey) 
				if [ -z $2 ]
				then
					echo "You must specify the ssh key!"
					exit 1
				fi
				SSHKEY_FILENAME=$2
				shift
				;;
	--imgdir) 
				if [ -z $2 ]
				then
					echo "You must specify the directory for saving images!"
					exit 1
				fi
				IMGDIR=$2
				shift
				;;
	
	--clients) 
				if [ -z $2 ]
				then
					echo "You must specify the number of clients!"
					exit 1
				fi
				CLIENTNR=$2
				shift
				;;
	--repo)
                if [ -z $2 ]
                then
                    echo "You must specify the repository!"
                    exit 1
                fi
                OSREPOSITORY=$2
                shift
                ;;
    --createbase)
                CREATEBASE=1
                ALL=0
                ;;
    --updatebase)
                UPDATEBASE=1
                ALL=0
                ;;
    --vmsonly)
                VMONLY=1
                ALL=0
                ;;
	-h) printHelp $INSTALLIMAGE $IMGDIR $CLIENTNR
		exit 0
		;;
	--help) printHelp $INSTALLIMAGE $IMGDIR $CLIENTNR
			exit 0
		;;
	*) echo "Unknown parameter $1"
	    exit 1
		;;
	esac
	shift
done

########################################################################
########################################################################
##### MAIN PART
########################################################################
########################################################################

    CREATEFLAG=$(($ALL + $CREATEBASE))
    UPDATEFLAG=$(($ALL + $UPDATEBASE))
    VMONLYFLAG=$(($ALL + $VMONLY))
    
    # Check existence of files necessary for creating new base image
    if [ ! $CREATEFLAG -eq 0 ] || [ ! $UPDATEFLAG -eq 0 ]
    then
        # check whether the directory with install scripts is present
        if [ ! -d $DATADIR ]
        then
            echo "Directory 'data' with necessary scripts is missing!" >&2
            exit 1
        else
            # check existence of server and client install scripts
            if [ ! -f $LOCALCLIENTSH ] || [ ! -f $LOCALSERVERSH ]
            then
                echo "Installation scripts missing!" >&2
                exit 1
            fi
        fi
    fi

    # only update or creation of environment was chosen -- base image must be specified then
    if [ $UPDATEBASE -eq 1 ] || [ $VMONLY -eq 1 ]
    then
        if [ -z "$BASEIMAGE" ]
        then
            echo "Base image was not specified!" >&2
            exit 1
        fi            
    fi

    if [ ! $CREATEFLAG -eq 0 ]
    then
        # check whether the repository address was specified
        if [ -z $OSREPOSITORY ]
        then
            echo "You must specify address of Fedora repository!" >&2
            exit 1
        fi

        # check whether the kickstart file exists
        if [ ! -f $KSFILE ]
        then
            echo "Kickstart file for ipa-server missing!" >&2
            exit 1
        fi

		if [ ! -z "$BASEIMAGE" ]
        then
            IMGFILE=$BASEIMAGE
        else
			IMGFILE=$IMGDIR/$IMGNAME.`getDate`.qcow2
		fi
    else
        if [ ! -z "$BASEIMAGE" ]
        then
            IMGFILE=$BASEIMAGE
        else
            echo "You haven't specified base image file!"
            exit 1
        fi
    fi

	printf "Creating/checking directory for saving base images\n"
	# create folder for achivation of base images and set it as readable for everyone
	if [ ! -d $IMGDIR ]
	then
		mkdir $IMGDIR
        if [ ! $? -eq 0 ]
        then
            echo "Image directory \"$IMGDIR\" can not be created!"
            exit 1
        fi
	fi

    TEMPORARYIMAGE=`createDiskName $TEMPIMAGE_PATTERN`

    printf "Creating/loading SSH key\n"
    if [ -z "$SSHKEY_FILENAME" ]
	then		
		SSHKEY_FILENAME=$SSHKEY_FOLDER/$SSHKEY_NAME
	else
		checkForWebAddress $SSHKEY_FILENAME
		if [ $? -eq 1 ]
		then
			wget $SSHKEY_FILENAME -O $WORKINGDIR/$SSHKEY_NAME
			if [ ! $? -eq 0 ]
			then
				echo "Certificate $SSHKEY_FILENAME can't be downloaded!" >&2
			fi
			SSHKEY_FILENAME=$WORKINGDIR/$SSHKEY_NAME
		fi
	fi
	# check existence of SSH key
	if [ ! -f $SSHKEY_FILENAME ]
	then
        if [ ! $CREATEFLAG -eq 0 ];
        then
            # create ssh cert in specified folder with specified name
            createSshCert $SSHKEY_FILENAME $LOGFILE
        else
            echo "Certificate $SSHKEY_FILENAME doesn't exist!" >&2
            exit 1
        fi
	fi

    # create base image
    if [ ! $CREATEFLAG -eq 0 ]
    then
        createBaseImage
        if [ $ALL -eq 0 ]
        then
            exit 0
        fi
    fi

    if [ ! $UPDATEFLAG -eq 0 ]
    then
        updateBaseImage
        if [ $ALL -eq 0 ]
        then
            exit 0
        fi
    fi
    
    createEnvironment
