#!/usr/bin/env bash
#
# zfs_snap.sh version v 0.2 2012-04-16
# Copyright 2012 Nils Bausch
# License GNU AGPL 3 or later
#
# take ZFS snapshots with a time stamp
# -h help page
# -d choose default options: hourly, daily, weekly, monthly, yearly
# -l the common label to be used if requested
# -v verbose output 
# -p pretend - don't take snapshots
# -u <property>=<value> for user chosen ZFS properties

# Path to binaries used 
ZPOOL="/sbin/zpool"
ZFS="/sbin/zfs"
EGREP="/usr/bin/egrep"
GREP="/usr/bin/grep"
TAIL="/usr/bin/tail"
SORT="/usr/bin/sort"
XARGS="/usr/bin/xargs"
DATE="/bin/date"
CUT="/usr/bin/cut"
TAIL="/usr/bin/tail"
TR="/usr/bin/tr"

# property used to check if auto updates should be made or not
SNAPSHOT_PROPERTY_NAME="com.sun:auto-snapshot"
SNAPSHOT_PROPERTY_VALUE="true"

# test for number of supplied arguments if zero, complain
if [ $# -eq 0 ]; then
	printf 'usage: %s [-h] [-d presetName] [-l label] [-v] [-p] \n' $(basename $0) >&2
        exit 2
fi

# set default values 
DEFAULTOPT=
LABELPREFIX="Automatic"
LABEL=`${DATE} +"%FT%H:%M"`
vflag=
pflag=
retention=10
userproperty=
exclude=

# go through passed options and assign to variables
while getopts 'hd:l:vpu:e:' OPTION
do
	case $OPTION in
	h) 	# help goes here ... somehow 
		;;
	d) 	DEFAULTOPT="$OPTARG"
		;;
	l)	LABELPREFIX="$OPTARG"
		;;
	v) 	vflag=1
		;;
	p) 	pflag=1
		;;
	u)	userproperty="$OPTARG"
		;;
	r)	retention="$OPTARG"
		;;	
	e)      exclude="$OPTARG"
		;;
	?)    	printf "Usage: %s: [-h] [-d <default-preset>] [-v] [-p] [-u <property>=<value>] [-r <num>]\n" $(basename $0) >&2
		exit 2
		;; 
	esac
done

# go through possible presets if available
if [ -n "$DEFAULTOPT" ]; then
	case $DEFAULTOPT in
	hourly)	LABELPREFIX="AutoH"
		LABEL=`${DATE} +"%FT%H:%M"`
		retention=24
		;;
	daily) 	LABELPREFIX="AutoD" 
		LABEL=`${DATE} +"%F"`
		retention=7
		;;
	weekly)	LABELPREFIX="AutoW"
		LABEL=`${DATE} +"%Y-%U"`	
		retention=4	
		;;
	monthly)LABELPREFIX="AutoM"
		LABEL=`${DATE} +"%Y-%m"`
		retention=12
		;;
	yearly)	LABELPREFIX="AutoY"
		LABEL=`${DATE} +"%Y"`	
		retention=10
		;;
	*)	printf 'Default option not specified\n'
		exit 2
		;; 
	esac
fi

# set user property if given
if [ -n "$userproperty" ]; then
	set -- `echo "$userproperty" | tr '=' ' '`
	SNAPSHOT_PROPERTY_NAME="$1"
	SNAPSHOT_PROPERTY_VALUE="$2"
fi

# available pools for backup: zpool list - excludes 
ALLPOOLS=`${ZPOOL} list | ${TAIL} -n +2 | ${CUT} -d' ' -f1 | tr '\n' ' '` 
for item in ${exclude//,/ }; do
	ALLPOOLS=`echo $ALLPOOLS | sed -e s/^"${item}"[^:alnum:.:-]//g -e s/[^:alnum:.:-]"${item}"[^:alnum:.:-]/\ /g -e s/[^:alnum:.:-]"${item}"$//g`
done
# now create a pattern for egrep to match with 
ALLPOOLS=`echo ${ALLPOOLS} |sed 's/[a-zA-Z0-9._:-]*/\^&\$|\^&\//g' | sed 's/ /|/g'`

# determine if any of the pools are busy, if yes abort and print error
POOLS_OK=`${ZPOOL} status | ${EGREP} -c "scrub completed|none requested|No known data errors"`
if [ $POOLS_OK -eq 0 ]; then
	printf 'Pool(s) busy, no snapshots taken.\n'
        exit 2
fi  

#TAKE SNAPSHOTS

# get a list of all available zfs filesystems by listing them and then look for property and take snapshots
for i in $(${ZFS} list | ${TAIL} -n +2 | ${TR} -s " " | ${CUT} -f 1 -d ' '| ${EGREP} -i "${ALLPOOLS}") ; do
        # get state of auto-snapshot property, either true or false
	if [ "$vflag" ]; then
		echo  "${ZFS} get ${SNAPSHOT_PROPERTY_NAME} $i | ${TAIL} -n 1 | ${TR} -s ' ' | ${CUT} -f 3 -d ' '"
	 	VALUE=`${ZFS} get ${SNAPSHOT_PROPERTY_NAME} $i | ${TAIL} -n 1 | ${TR} -s ' ' | ${CUT} -f 3 -d ' '`	
	else
	        VALUE=`${ZFS} get ${SNAPSHOT_PROPERTY_NAME} $i | ${TAIL} -n 1 | ${TR} -s ' ' | ${CUT} -f 3 -d ' '`
	fi
       	# do the snapshot dance
       	if [ $VALUE = $SNAPSHOT_PROPERTY_VALUE ]; then
		if [ "$pflag" ]; then
			echo ${ZFS} snapshot $i@$LABELPREFIX-$LABEL
		else
               		$(${ZFS} snapshot $i@$LABELPREFIX-$LABEL)
		fi
       	fi
done


#DELETE SNAPSHOTS
# adjust retention to work with tail i.e. increase by one
let retention+=1
for pool in $(${ZPOOL} list | ${TAIL} -n +2 | ${CUT} -d' ' -f1 | ${EGREP} -i "${ALLPOOLS}"); do
	if [ "$vflag" ]; then
		echo "${ZFS} list -t snapshot -o name | ${GREP} $pool@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention}"
		list=`${ZFS} list -t snapshot -o name | ${GREP} $pool@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention}`	
	else
		list=`${ZFS} list -t snapshot -o name | ${GREP} $pool@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention}`
	fi
	
	if [ "$pflag" ]; then
		if [ -n "$list" ]; then
			echo "Delete recursively:" 
			echo "$list"
		else
			echo "No snapshots to delete for pool ${pool}"
		fi
	else
		$(${ZFS} list -t snapshot -o name | ${GREP} $pool@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention} | ${XARGS} -n 1 ${ZFS} destroy -r)
	fi
done
