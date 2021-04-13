#!/bin/bash
#
#  snapshot-resync-target-lvm.sh
#  This file is part of DRBD by Philipp Reisner and Lars Ellenberg.
#
# The caller (drbdadm) sets for us:
# DRBD_RESOURCE, DRBD_VOLUME, DRBD_MINOR, DRBD_LL_DISK etc.
#
###########
#
# There will be no resync if this script terminates with an
# exit code != 0. So be carefull with the exit code!
#

export LC_ALL=C LANG=C

if [[ -z "$DRBD_RESOURCE" || -z "$DRBD_LL_DISK" ]]; then
	echo "DRBD_RESOURCE/DRBD_LL_DISK is not set. This script is supposed to"
	echo "get called by drbdadm as a handler script"
	exit 0
fi

PROG=$(basename $0)

redirect_to_logger()
{
	local lf=${1:-local5}
	case $lf in
	# do we want to exclude some?
	auth|authpriv|cron|daemon|ftp|kern|lpr|mail|news|syslog|user|uucp|local[0-7])
		: OK ;;
	*)
		echo >&2 "invalid logfacility: $lf"
		return
		;;
	esac

	exec > >( exec 1>&- 2>&- logger -t "$PROG[$$]" -p $lf.info ) 2>&1
}

if [[ $- != *x* ]]; then
	# you may override with --logfacility below
	redirect_to_logger local5
fi

echo "invoked for $DRBD_RESOURCE/$DRBD_VOLUME (drbd$DRBD_MINOR)"

TEMP=$(getopt -o p:a:l:nv --long percent:,additional:,logfacility:,disconnect-on-error,verbose -- "$@")

if [ $? != 0 ]; then
	echo "getopt failed"
	exit 0
fi

SNAP_PERC=10
SNAP_ADDITIONAL=10240
DISCONNECT_ON_ERROR=0
LVC_OPTIONS=""
BE_VERBOSE=0
DEFAULTFILE="/etc/default/drbd-snapshot"

if [ -f $DEFAULTFILE ]; then
	. $DEFAULTFILE
fi

## command line parameters override default file

eval set -- "$TEMP"
while true; do
	case $1 in
	-p|--percent)
		SNAP_PERC="$2"
		shift
		;;
	-a|--additional)
		SNAP_ADDITIONAL="$2"
		shift
		;;
	-n|--disconnect-on-error)
		DISCONNECT_ON_ERROR=1
		;;
	-v|--verbose)
		BE_VERBOSE=1
		;;
	-l|--logfacility)
		redirect_to_logger $2
		shift
		;;
	--)
		break
		;;
	esac
	shift
done
shift # the --

LVC_OPTIONS="$@"

set_backing_bdev()
{
	if BACKING_BDEV=$(drbdadm sh-ll-dev "$DRBD_RESOURCE/$DRBD_VOLUME"); then
		is_stacked=false
	elif BACKING_BDEV=$(drbdadm sh-ll-dev "$(drbdadm -S sh-lr-of "$DRBD_RESOURCE")/$DRBD_VOLUME"); then
		is_stacked=true
	else
		echo "Cannot determine lower level device of resource $DRBD_RESOURCE/$DRBD_VOLUME, sorry."
		return 1
	fi
	return 0
}

set_vg_lv_size()
{
	local X
	if ! X=$(lvs --noheadings --nosuffix --units s -o vg_name,lv_name,lv_size "$BACKING_BDEV") ; then
		# if lvs cannot tell me the info I need,
		# this is:
		echo "Cannot create snapshot of $BACKING_BDEV, apparently no LVM LV."
		return 1
	fi
	set -- $X
	VG_NAME=$1 LV_NAME=$2 LV_SIZE_K=$[$3 / 2]
	return 0
}

remove_snapshot()
{
	lvremove -f $VG_NAME/$SNAP_NAME
}

create_snapshot()
{
	if lvs $VG_NAME/$SNAP_NAME >/dev/null 2>&1; then
		echo "snapshot already exists for $DRBD_RESOURCE/$DRBD_VOLUME, skipping"
		return 0
	fi

	OUT_OF_SYNC=$(drbdsetup events2 --statistics --now $DRBD_RESOURCE | \
		grep "^exists peer-device name:$DRBD_RESOURCE" | \
		grep "volume:$DRBD_VOLUME" | \
		grep -oP 'out-of-sync:\K[0-9]+')

	SNAP_SIZE=$((OUT_OF_SYNC + SNAP_ADDITIONAL + LV_SIZE_K * SNAP_PERC / 100))
	lvcreate -s -n $SNAP_NAME -L ${SNAP_SIZE}k $LVC_OPTIONS $VG_NAME/$LV_NAME
}

VOLUMES=( $DRBD_VOLUME )
MINORS=( $DRBD_MINOR )

FINAL_RV=0

for n in "${!VOLUMES[@]}"; do

	DRBD_VOLUME="${VOLUMES[$n]}"
	DRBD_MINOR="${MINORS[$n]}"

	set_backing_bdev || exit 0 # clean exit if unable to determine lower level device
	set_vg_lv_size || exit 0 # clean exit if not an lvm lv

	# set snapshot LV name
	SNAP_NAME=$LV_NAME-before-resync
	$is_stacked && SNAP_NAME=$SNAP_NAME-stacked

	[ $BE_VERBOSE = 1 ] && set -x

	if [[ $0 == *unsnapshot* ]]; then
		remove_snapshot
	else
		create_snapshot
		RV=$?
		[ $RV -eq 0 ] || FINAL_RV=$RV
	fi

	set +x

done

[ $DISCONNECT_ON_ERROR = 0 ] && exit 0

exit $FINAL_RV
