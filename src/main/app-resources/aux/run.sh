#!/bin/bash


# source the ciop functions (e.g. ciop-log)
source ${ciop_job_include}

# define the exit codes
SUCCESS=0
ERR_AUX=2
ERR_VOR=4
#export HOME=/tmp
# add a trap to exit gracefully
function cleanExit ()
{
local retval=$?
local msg=""
case "$retval" in
$SUCCESS) msg="Processing successfully concluded";;
$ERR_AUX) msg="Failed to retrieve reference to auxiliary data";;
$ERR_VOR) msg="Failed to retrieve reference to orbital data";;
*) msg="Unknown error";;
esac
[ "$retval" != "0" ] && ciop-log "ERROR" "Error $retval - $msg, processing aborted" || ciop-log "INFO" "$msg"
exit $retval
}
trap cleanExit EXIT

# get the catalogue access point
cat_osd_root="`ciop-getparam aux_catalogue`"


function getAUXref() {

  local atom=$1
  local osd=$2
  local series=$3 
 
  startdate=$( opensearch-client ${atom} startdate | tr -d "Z")
  [ -z "${startdate}" ] && return ${ERR_NOSTARTDATE}
  
  stopdate=$( opensearch-client ${atom} enddate | tr -d "Z")
  [ -z "${stopdate}" ] && return ${ERR_NOENDDATE}
  
  ref="$( opensearch-client -p "pi=${series}" -p "time:start=${startdate}" -p "time:end=${stopdate}" ${osd} )" 
  [ -z "${ref}" ] && return ${ERR_AUXREF}
  
  echo ${ref}

}

function runAux() {
  local sar=$1
  local osd=$2
  
  # DOR_VOR_AX
  ciop-log "INFO" "Getting a reference to DOR_VOR_AX"
  ref=$( getAUXref ${sar} ${osd} DOR_VOR_AX | awk '{print $1}')        	
	
  ciop-log "INFO" "VOR IS $ref"
  [ "$ref" != " " ] || exit $ERR_VOR        		

  # pass the SAR reference to the next node
  echo $ref
}

#main
while read master
do
	ciop-log "INFO" "Master: $master"
	slave="`ciop-getparam slave`"
	ciop-log "INFO" "Slave: $slave"
	masterOrb=$( echo `runAux $master ${cat_osd_root}` )
	resMaster=$?
	[ "$resMaster" -ne 0 ] && exit $resMaster
	slaveOrb=$( echo `runAux $slave ${cat_osd_root}` )
	resSlave=$?
        echo "$master@$masterOrb@$slave@$slaveOrb" | ciop-publish -s
	exit $resSlave
done

