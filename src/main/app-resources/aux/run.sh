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
  local rdf=$1
  local ods=$2
  ciop-log "INFO" "rdf is $rdf"
  ciop-log "INFO" "ods is $ods"
  ciop-log "INFO" "opensearch-client $rdf startdate | tr -d Z"
  startdate=`opensearch-client $rdf startdate | tr -d "Z"`
  [ -z "$startdate" ] && exit $ERR_NOSTARTDATE
  stopdate=`opensearch-client $rdf enddate | tr -d "Z"`
  [ -z "$stopdate" ] && exit $ERR_NOSTOPDATE
  aufRef=$(opensearch-client -f Rdf -p "time:start=$startdate" -p "time:end=$stopdate" $ods)
  res=$?
  [ ${res} -ne 0 ] && return ${res}
  aufRef=$( echo "$aufRef"  | tail -1)
  ciop-log "INFO" "AUFREF IS $aufRef"
  ciop-log "INFO" "opensearch-client -f Rdf -p time:start=$startdate -p time:end=$stopdate $ods"
  echo $aufRef
}

function runAux() {
	input=$1
	
	# DOR_VOR_AX
	ciop-log "INFO" "Getting a reference to DOR_VOR_AX"
	ref=`getAUXref $input $cat_osd_root/DOR_VOR_AX/description`        	
	#pass the aux reference to the next node
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
	masterOrb=$( echo `runAux $master` )
	resMaster=$?
	[ "$resMaster" -ne 0 ] && exit $resMaster
	slaveOrb=$( echo `runAux $slave` )
	resSlave=$?
        echo "$master@$masterOrb@$slave@$slaveOrb" | ciop-publish -s
	exit $resSlave
done

