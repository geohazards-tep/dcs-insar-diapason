#!/bin/bash


#source the ciop functions
source ${ciop_job_include}

# define the exit codes
SUCCESS=0
ERRGENERIC=1
ERRPERM=2
ERRSTGIN=3
ERRMISSING=255

# cleanup function
function procCleanup()
{
    if [ -n "${serverdir}"  ] && [ -d "$serverdir" ]; then
	ciop-log "INFO" "Cleaning up processing directory ${serverdir}"
	rm -rf "${serverdir}"
    fi
    
}

#trap signals
function trapFunction()
{
    procCleanup
    ciop-log "ERROR" "Signal was trapped"
    exit 
}

#data download
get_data() {
  local ref=$1
  local target=$2
  local local_file
  local enclosure
  local res
  ciop-log "INFO" "Downloading ${ref}"
  #enclosure="$( opensearch-client  "${ref}" enclosure | tail -1 )"
  enclosure="$( opensearch-client  "${ref}" enclosure)"
  res=$?
  enclosure="$(echo $enclosure | tail -1)"
  [ $res -eq 0 ] && [ -z "${enclosure}" ] && return ${ERR_GETDATA}
  # opensearh client doesn't deal with local paths
  [ $res -ne 0 ] && enclosure=${ref}
  
  local_file="$( echo ${enclosure} | ciop-copy -f -U -O ${target} - 2> /dev/null )"
  res=$?

  [ ${res} -ne 0 ] && return ${res}
  echo ${local_file}
}

# dem download 
function demDownload()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    #check for required programs 
    if [ -z "`type -p curl`" ] ; then
	ciop-log "ERROR" "System missing curl utility" 
	return ${ERRMISSING} 
    fi
	
    if [ -z "`type -p gdalinfo`" ] ; then
	ciop-log "ERROR"  "System missing gdalinfo utility" 
	return ${ERRMISSING} 
    fi


    procdir="$1"
    
    
    latitudes=(`grep -h LATI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n |  sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    longitudes=(`grep -h LONGI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n | sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    
    if [ ${#latitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    if [ ${#longitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    url="http://dedibox.altamira-information.com/demdownload?lat="${latitudes[0]}"&lat="${latitudes[1]}"&lon="${longitudes[0]}"&lon="${longitudes[1]}
    
    ciop-log "INFO"  "Downloading DEM from ${url}"
    
    demtif=${procdir}/DAT/dem.tif
    
    downloadcmd="curl -o \"${demtif}\" \"${url}\" "

    eval "${downloadcmd}" > "${procdir}"/log/demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR" "Unable to download DEM data"
	return ${ERRGENERIC}
    fi
    
    #check it is a tiff
    gdalinfo "${demtif}" >> "${procdir}"/log/demdownload.log 2<&1 || {
	ciop-log "ERROR"  "No DEM data over selected area"
	return ${ERRGENERIC}
    }
    
    #generate DEM descriptor in diapason format
    tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DAT" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" > "${procdir}/log/deminport.log" 2<&1

export DEM="${procdir}/DAT/dem.dat"


if [ ! -e "${DEM}" ]; then
    ciop-log "ERROR"  "Failed to convert downloaded DEM data"
    msg=`cat "${procdir}/log/deminport.log"`
    ciop-log "INFO" "${msg}"
    
    return ${ERRGENERIC}
fi

ciop-log "INFO"  "DEM descriptor creation done "

return ${SUCCESS}

}


function check_local_sar_file
{
    
    if [ $# -lt 1 ]; then
	return ${ERRGENERIC}
    fi

    file=$1

    if [ -d "${file}" ]; then
	return ${SUCCESS}
    fi

    fsize=$(stat -c "%s" "$file")
    
    if [ $fsize -gt 1048576 ]; then	
	return ${SUCCESS}
    fi
    
    #files with size < 1MB means download probably failed
    #look for an html tag at the beginning of the file
    tag=`dd if=${file} bs=10 count=1 | grep -o html`
    
    if [ -n "${tag}" ] && [ "${tag}" == "html" ]; then
	ciop-log "INFO" "html tag detected in local file. You likely are not allowed to access the remote resource"
	return ${ERRPERM}
    fi 
    
    ciop-log "INFO" "local file size is < 1MB. Either the download failed , or access to the remote resource is denied"
    
    return ${ERRGENERIC}
}

#function computing the area of slc scene within aoi
#aoi specified as minlon,minlat,maxlon,maxlat
function geosar_get_aoi_coords()
{
    if [ $# -lt 2 ]; then
	return 1
    fi


    local geosar="$1"
    local aoi="$2"

    local tmpdir_="/tmp"
    
    if [ $# -ge 3 ]; then
	tmpdir_=$3
    fi

    
    #aoi is of the form
    #minlon,minlat,maxlon,maxlat
    aoi=(`echo "$aoi" | sed 's@,@ @g'`)
    
    if [ ${#aoi[@]} -lt 4 ]; then
	return 1
    fi

    tmpgeosar=${tmpdir_}/tmp.geosar
    
    cp "${geosar}" "${tmpgeosar}" || {
return 1
    }
    
    #increase the aoi extent
    local extentfactor=0.2
    local diffx=`echo "(${aoi[2]} - ${aoi[0]})*${extentfactor}" | bc -l`
    local minlon=`echo "${aoi[0]} - ${diffx}" | bc -l`
    local maxlon=`echo "${aoi[2]} + ${diffx}" | bc -l`
    local diffy=`echo "(${aoi[3]} - ${aoi[1]})*${extentfactor}" | bc -l`
    local minlat=`echo "${aoi[1]} - ${diffy}" | bc -l`
    local maxlat=`echo "${aoi[3]} + ${diffy}" | bc -l`

    sed -i -e 's@\(CENTER LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(CENTER LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(LL LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LR LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UL LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UR LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LR LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UL LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UR LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LL LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"

    #set the lat/long from the aoi
    local cmdll="sed -i -e 's@\(LL LATITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${minlat}"@g' \"${tmpgeosar}\""
    local cmdul="sed -i -e 's@\(UL LATITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${maxlat}"@g' \"${tmpgeosar}\""
    
    local cmdlll="sed -i -e 's@\(LL LONGITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${minlon}"@g' \"${tmpgeosar}\""
    local cmdull="sed -i -e 's@\(UL LONGITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${maxlon}"@g' \"${tmpgeosar}\""
    
    
    
    eval "${cmdll}"
    eval "${cmdul}"
    eval "${cmdull}"
    eval "${cmdlll}"
    
    if [ -z "${EXE_DIR}" ]; then
	EXE_DIR=/opt/diapason/exe.dir/
    fi
    
    roi=$(sarovlp.pl --geosarm="$geosar" --geosars="${tmpgeosar}" --exedir="${EXE_DIR}")
    
    status=$?

    #no overlapping between image and aoi
    if [ $status -eq 255 ]; then
	return 255
    fi
    
    if [ -z "$roi" ]; then
	return 1
    fi

    echo $roi

    return 0
    
}


# create a shapefile from a bounding box string
# arguments:
# bounding box string of the form "minlon,minlat,maxlon,maxlat"
# output diretory where shapefile shall be created
# tag used to name the shapefile
function aoi2shp()
{
    if [ $# -lt 3 ]; then
	ciop-log "ERROR" "Usage:$FUNCTION minlon,minlat,maxlon,maxlat directory tag"
	return ${ERRMISSING}
    fi

    local aoi="$1"

    local directory="$2"

    local tag="$3"

    if [ ! -d "`readlink -f $directory`" ]; then
	ciop-log "ERROR" "$FUNCTION:$directory is not a directory"
	return ${ERRINVALID}
    fi

    #check for aoi validity
    local aoiarr=(`echo ${aoi} | sed 's@,@ @g' `)

    local nvalues=${#aoiarr[@]}

    if [ $nvalues -lt 4 ]; then
	ciop-log "ERROR" "$FUNCTION:Invalid aoi :$aoi"
	ciop-log "ERROR" "$FUNCTION:Should be of the form: minlon,minlat,maxlon,maxlat"
	return ${ERRINVALID}
    fi

    #use a variable for each
    local maxlon=${aoiarr[2]}
    local maxlat=${aoiarr[3]}
    local minlon=${aoiarr[0]}
    local minlat=${aoiarr[1]}

    #check for shapelib utilities
    if [ -z "`type -p shpcreate`" ]; then
	ciop-log "ERROR" "Missing shpcreate utility"
	return ${ERRMISSING}
    fi

    if [ -z "`type -p shpadd`" ]; then
	ciop-log "ERROR" "Missing shpadd utility"
	return ${ERRMISSING}
    fi

    #enter the output shapefile directory
    cd "${directory}" || {
	ciop-log "ERROR" "$FUNCTION:No permissions to access ${directory}"
	cd -
	return ${ERRPERM}
}
    

    #create empty shapefile
    shpcreate "${tag}" polygon
    local statuscreat=$?

    if [ ${statuscreat}  -ne 0 ]; then
	cd -
	ciop-log "ERROR" "$FUNCTION:Shapefile creation failed"
	return ${ERRGENERIC}
    fi 

    shpadd "${tag}" "${minlon}" "${minlat}" "${maxlon}" "${minlat}" "${maxlon}" "${maxlat}"  "${minlon}" "${maxlat}" "${minlon}" "${minlat}"
    
    local statusadd=$?

    if [ ${statusadd} -ne 0 ]; then
	ciop-log "ERROR" "$FUNCTION:Failed to add polygon to shapefile"
	return ${ERRGENERIC}
    fi
    
  local shp=${directory}/${tag}.shp

  if [ ! -e "${shp}" ]; then
      cd -
      ciop-log "ERROR" "$FUNCTION:Failed to create shapefile"
      return ${ERRGENERIC}
  fi

  echo "${shp}"

  return ${SUCCESS}

 }

#inputs : aoi_string and processing root dir
function crop_geotiff2_to_aoi()
{
    if [ $# -lt 2 ]; then
	return 1
    fi

    local rootdir="`readlink -f $1`"
    local aoistr="$2"
    local aoi=(`echo "$aoistr" | sed 's@,@ @g'`)
    
    if [ ${#aoi[@]} -lt 4 ]; then
	return 1
    fi

    local tempo=${rootdir}/TEMP
    
    local geotiff=""
    
    local shape=""
    local gdalcropbin="/opt/gdalcrop/bin/gdalcrop"

    if [  -f "${gdalcropbin}" ]; then
	shape=$(aoi2shp "$aoistr" "${tempo}" "AOI")
	ciop-log "INFO" "Using shapefile ${shape}"
    fi

    for geotiff in `find "${rootdir}/GEOCODE"  -iname "*.tiff" -print -o -iname "*.tif" -print`; do
	target=${tempo}/`basename $geotiff`
	if [ -z "${shape}" ]; then
	    gdalwarp -te ${aoi[0]} ${aoi[1]} ${aoi[2]} ${aoi[3]} -r bilinear "${geotiff}" "${target}" >> ${rootdir}/log/tiffcrop.log 2<&1
	else
	    ${gdalcropbin} "${geotiff}" "$shape" "${target}" >> ${rootdir}/log/tiffcrop.log 2<&1
	fi
	mv "${target}" "${geotiff}"
     done
    
    if [ -n "$shape" ]; then
	rm "${shape}"
    fi
    
    ciop-log "INFO" "`cat ${rootdir}/log/tiffcrop.log`"

    return 0
}


function check_resampling()
{
    if [ $# -lt 5 ]; then
	return 1
    fi

    local srvdir="$1"
    local ms=$2
    local sl=$3
    local mlaz=$4
    local mlran=$5
    
    #check if prf and sampling frequency are the same for master and slave
    nprf=`grep -ih "PRF" ${srvdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | awk '{printf("%.5f\n",$1)}' | sort -n --unique | wc -l`
    nfreq=`grep -ih "SAMPLING FREQUENCY" ${srvdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | awk '{printf("%.8f\n",$1)}' | sort -n --unique | wc -l`
    
   
    #run resampling if required
    if [ $nprf -ne 1 ] || [  $nfreq -ne 1 ]; then

	ciop-log "INFO" "Resampling slave image"
    
	resamp.pl --gi="${srvdir}/DAT/GEOSAR/${sl}.geosar" --gt="${srvdir}/DAT/GEOSAR/${ms}.geosar" --slcout="${srvdir}/SLC_CI2/${sl}_SLC.ci2" --go="${srvdir}/DAT/GEOSAR/${sl}.geosar" --exedir="${exedir}"  --tmpdir="${srvdir}/TEMP/"  > "${srvdir}/log/resamp_${sl}.log" 2<&1
	status=$?
	[ $status -ne 0 ] && return $status
	
	#re-create the slave multilook 
	echo "${srvdir}/DAT/GEOSAR/${sl}.geosar" | ml_all.pl --type=byt --mlaz=${mlaz} --mlran=${mlran} --dir="${serverdir}/SLC_CI2/" >> "${serverdir}/log/ml.log" 2<&1
    fi
    
    return 0
}


function create_interf_properties()
{
    if [ $# -lt 4 ]; then
	echo "$FUNCNAME : usage:$FUNCNAME file description serverdir geosar"
	return 1
    fi

    local inputfile=$1
    local fbase=`basename ${inputfile}`
    local description=$2
    local serverdir=$3
    local geosarm=$4
    local geosars=""
    if [ $# -ge 5 ]; then
    geosars=$5
    fi
    
    local datestart=$(geosar_time "${geosarm}")
    
    local dateend=""
    if [ -n "$geosars" ]; then
	dateend=$(geosar_time "${geosars}")
    fi

    local propfile="${inputfile}.properties"
    echo "title = DIAPASON InSAR Stripmap (SM) - ${description} - ${datestart} ${dateend}" > "${propfile}"
    echo "Description = ${description}" >> "${propfile}"
    local sensor=`grep -h "SENSOR NAME" "${geosarm}" | cut -b 40-1024 | awk '{print $1}'`
    echo "Sensor\ Name = ${sensor}" >> "${propfile}"
    local masterid=`head -1 ${serverdir}/masterid.txt`
    if [ -n "${masterid}" ]; then
	echo "Master\ SLC\ Product = ${masterid}" >> "${propfile}"
    fi 
    local slaveid=`head -1 ${serverdir}/slaveid.txt`
    if [ -n "${slaveid}" ]; then
	echo "Slave\ SLC\ Product = ${slaveid}" >> "${propfile}"
    fi 

    #look for 2jd utility to convert julian dates
    if [ -n "`type -p j2d`"  ] && [ -n "${geosars}" ]; then
	local jul1=`grep -h JULIAN "${geosarm}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	local jul2=`grep -h JULIAN "${geosars}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	if [ -n "${jul1}"  ] && [ -n "${jul2}" ]; then 
	
	    local dates=""
	    for jul in `echo -e "${jul1}\n${jul2}" | sort -n`; do
		local julday=`echo "2433283+${jul}" | bc -l`
		local dt=`j2d ${julday} | awk '{print $1}'`
		
		dates="${dates} ${dt}"
	    done
	   
	fi
	echo "Observation\ Dates = $dates" >> "${propfile}"
	
	local timeseparation=`echo "$jul1 - $jul2" | bc -l`
	if [ $timeseparation -lt 0 ]; then
	    timeseparation=`echo "$timeseparation*-1" | bc -l`
	fi
	
	if [ -n "$timeseparation" ]; then
	    echo "Time\ Separation\ \(days\) = ${timeseparation}" >> "${propfile}"
	fi
    fi

    local altambig="${serverdir}/DAT/AMBIG.dat"
    if [ -e "${altambig}" ] ; then
	local info=($(grep -E "^[0-9]+" "${altambig}" | head -1))
	if [  ${#info[@]} -ge 6 ]; then
	    #write incidence angle
	    echo "Incidence\ angle\ \(degrees\) = "${info[2]} >> "${propfile}"
	    #write baseline
	    local bas=`echo ${info[4]} | awk '{ if($1>=0) {print $1} else { print $1*-1} }'`
	    echo "Baseline\ \(meters\) = ${bas}" >> "${propfile}"
	else
	    ciop-log "INFO" "Invalid format for AMBIG.DAT file "
	fi
    else
	ciop-log "INFO" "Missing AMBIG.DAT file in ${serverdir}/DAT"
    fi 
    
    local satpass=`grep -h "SATELLITE PASS" "${geosarm}"  | cut -b 40-1024 | awk '{print $1}'`
    
    if [ -n "${satpass}" ]; then
	echo "Orbit\ Direction = ${satpass}" >> "${propfile}"
    fi

    local publishdate=`date +'%B %d %Y' `
    echo "Processing\ Date  = ${publishdate}" >> "${propfile}"
    
    local logfile=`ls ${serverdir}/ortho_amp.log`
    if [ -e "${logfile}" ]; then
	local resolution=`grep "du mnt" "${logfile}" | cut -b 15-1024 | sed 's@[^0-9\.]@\n@g' | grep [0-9] | sort -n | tail -1`
	if [ -n "${resolution}" ]; then
	    echo "Resolution\ \(meters\) = ${resolution}" >> "${propfile}"
	fi
    fi

    local wktfile="${serverdir}/wkt.txt"
    
    if [ -e "${wktfile}" ]; then
	local wkt=`head -1 "${wktfile}"`
	echo "geometry = ${wkt}" >> "${propfile}"
    fi
}


# get suitable minimum and maximum image
# values for histogram stretching
# arguments:
# input image
# variable used to store minimum value
# variable used to store maximum value
# return 0 if successful , non-zero otherwise
function image_equalize_range()
{
    if [ $# -lt 1 ]; then
	return 255
    fi 

    #check gdalinfo is available
    if [ -z "`type -p gdalinfo`" ]; then
	return 1
    fi

    local image="$1"

    
    declare -A Stats
    
    #load the statistics information from gdalinfo into an associative array
    while read data ; do
	string=$(echo ${data} | awk '{print "Stats[\""$1"\"]=\""$2"\""}')
	eval "$string"
    done < <(gdalinfo -hist "${image}"   | grep STATISTICS | sed 's@STATISTICS_@@g;s@=@ @g')

    #check that we have mean and standard deviation
    local mean=${Stats["MEAN"]}
    local stddev=${Stats["STDDEV"]}
    local datamin=${Stats["MINIMUM"]}

    if [ -z "$mean"   ] || [ -z "${stddev}" ] || [ -z "${datamin}" ]; then
	return 1
    fi 
    
   
    local min=`echo $mean - 3*${stddev} | bc -l`
    local max=`echo $mean + 3*${stddev} | bc -l`
    
    local below_zero=`echo "$min < $datamin" | bc -l`
    
    [ ${below_zero} -gt 0 ] && {
	min=$datamin
    }
    
    if [ $# -ge 2 ]; then
	eval "$2=${min}"
    fi

    if [ $# -ge 3 ]; then
	eval "$3=${max}"
    fi

   
    return 0
}

function geosar_time()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    local geosar="$1"
    
    local date=$(/usr/bin/perl <<EOF
use POSIX;
use strict;
use esaTime;
use geosar;

my \$geosar=geosar->new(FILE=>'$geosar');
my \$time=\$geosar->startTime();
print \$time->xgr;
EOF
)

    [ -z "$date" ] && {
	return $ERRMISSING
    }

    echo $date
    return 0
}


function tiff2wkt(){
    
    if [ $# -lt 1 ]; then
	echo "Usage $0 geotiff"
	return $ERRMISSING
    fi
    
    tiff="$1"
    
    declare -a upper_left
    upper_left=(`gdalinfo $tiff | grep "Upper Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a lower_left
    lower_left=(`gdalinfo $tiff | grep "Lower Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)

    declare -a lower_right
    lower_right=(`gdalinfo $tiff | grep "Lower Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a upper_right
    upper_right=(`gdalinfo $tiff | grep "Upper Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    echo "POLYGON((${upper_left[0]} ${upper_left[1]} , ${lower_left[0]} ${lower_left[1]},  ${lower_right[0]} ${lower_right[1]} , ${upper_right[0]} ${upper_right[1]}, ${upper_left[0]} ${upper_left[1]}))"
   
    return 0
}


#setup the Diapason environment
export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}


#inputs

MASTER="" 
SLAVE=""  
DEM="" 

#PARAMS
MLAZ=10
MLRAN=2

#S1 SM flag
S1FLAG=""

#
rootdir=${TMPDIR}

# get the service parameters
inputaoi=(`ciop-getparam aoi`)
naoival=`echo "${inputaoi}" | sed 's@[^0-9\.\-\,]@@g;s@,@ @g'  | wc -w`
[ ${naoival}  -lt 4 ] && inputaoi="" 
#polarization
inputpol=(`ciop-getparam polarization`)
export POL=${inputpol}
#correlation parameters
winazi=(`ciop-getparam winazi`)
winran=(`ciop-getparam winran`)
expwinazi=(`ciop-getparam expwinazi`)
expwinran=(`ciop-getparam expwinran`)
corrthr=(`ciop-getparam corrthr`)
#psfilt option
psfiltx=(`ciop-getparam psfiltx`)
#unwrap option
unwrap=(`ciop-getparam unwrap`)
# read inputs from stdin
# the input is  a colon-separated line, first record is master image
#second record is slave image
while read inputs
do

#make sure some data was read
if [ -z "$inputs" ]; then
    break
fi  

ciop-log "DEBUG" "inputs $inputs"

inputarr=($(echo $inputs | tr "@" "\n"))


ninputs=${#inputarr[@]}

#flag telling whether the orbits are inputs to the process
flag_orbit_in=0

# in ERS case the input list will be :
# master@slave
if [ $ninputs -eq 2 ]; then
    MASTER=${inputarr[0]}
    SLAVE=${inputarr[1]}
    ciop-log "DEBUG" "Master ${inputarr[0]}"
    ciop-log "DEBUG" "Slave ${inputarr[1]}"
fi 

#in ASAR case the input list will be :
# master@orbmaster@slave@orbslave
if [ $ninputs -eq 4  ]; then
    MASTER=${inputarr[0]}
    SLAVE=${inputarr[2]}
    MASTERVORURL=${inputarr[1]}
    SLAVEVORURL=${inputarr[3]}
    ciop-log "DEBUG" "Master ${inputarr[0]}"
    ciop-log "DEBUG" "MasterOrb ${inputarr[1]}"
    ciop-log "DEBUG" "Slave ${inputarr[2]}"
    ciop-log "DEBUG" "SlaveOrd ${inputarr[3]}"
    flag_orbit_in=1
fi



#DEM=${inputlist[2]}
ciop-log "DEBUG" "Master $master and Slave $SLAVE"

if [ -z "$MASTER" ] || [ -z "${SLAVE}" ] ; then
    ciop-log "ERROR"  "Missing Input file . MASTER->$MASTER , SLAVE->$SLAVE "
    exit ${ERRMISSING}
fi 



#create processing directory
unset serverdir
export serverdir=`mktemp -d ${rootdir}/DIAPASON_XXXXXX` || {
ciop-log "ERROR " "Cannot create processing directory"
exit ${ERRPERM}
}

ciop-log "INFO"  "processing in directory ${serverdir}"

#trap signals
trap trapFunction SIGHUP SIGINT SIGTERM


#create directory tree
mkdir -p ${serverdir}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD,GEO_CI2,VOR,GEO_CI2_EXT_LIN,GRID_LIN} || {
ciop-log "ERROR"  "Cannot create processing directory structure"
 exit ${ERRPERM}
}




#stage-in the data
localms=$( get_data ${MASTER} ${serverdir}/CD )
#localms=`ciop-copy -o "${serverdir}/CD" "${MASTER}" `

[  "$?" == "0"  -a -e "${localms}" ] || {
    ciop-log "ERROR"  "Failed to download file ${MASTER}"
    procCleanup
    exit ${ERRSTGIN}
}

check_local_sar_file "${localms}" || {
    ciop-log "ERROR"  "Unable to download file ${MASTER}"
    procCleanup
    exit ${ERRSTGIN}
}

localsl=$( get_data ${SLAVE} ${serverdir}/CD )
#localsl=`ciop-copy -o "${serverdir}/CD" "${SLAVE}" `


[  "$?" == "0"  -a -e "${localsl}" ] || {
    ciop-log "ERROR"  "Failed to download file ${SLAVE}"
    procCleanup
    exit ${ERRSTGIN}
}

check_local_sar_file "${localsl}" || {
    ciop-log "ERROR" "Unable to download file ${SLAVE}"
    procCleanup
    exit ${ERRSTGIN}
}

if [ ${flag_orbit_in} -gt 0 ]; then 


    localmasterVOR=$( get_data ${MASTERVORURL} ${serverdir}/VOR )
    
    [  "$?" == "0"  -a -e "${localmasterVOR}" ] || {
	ciop-log "ERROR"  "Failed to download file ${MASTERVORURL}"
	procCleanup
	exit ${ERRSTGIN}
    }
    
    localslaveVOR=$( get_data ${SLAVEVORURL} ${serverdir}/VOR )
    
    [  "$?" == "0"  -a -e "${localslaveVOR}" ] || {
	ciop-log "ERROR"  "Failed to download file ${SLAVEVORURL}"
	procCleanup
	exit ${ERRSTGIN}
    }
    
fi

#unpack the files in ${serverdir}/VOR if any
cd "${serverdir}/VOR"
find . -iname "*.gz"  -exec gunzip '{}' \;
find . -iname "*.tar" -exec tar -xvf '{}' \;
cd -

#
opensearch-client -f atom "${MASTER}" identifier > ${serverdir}/masterid.txt
opensearch-client -f atom "${SLAVE}" identifier > ${serverdir}/slaveid.txt


vorcontents=$(ls -l ${serverdir}/VOR)

#extract inputs

#extract master
handle_tars.pl --in="${localms}"  --serverdir="${serverdir}" --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > "${serverdir}"/log/extract_master.log 2<&1

orbitmaster=`grep -ih "ORBIT NUMBER" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

if [ -z "${orbitmaster}" ]; then
	ciop-log "ERROR"  "Master image extraction failure"
	msg=`cat "${serverdir}"/log/extract_master.log`
	ciop-log "ERROR"  "${msg}"
	procCleanup
	exit ${ERRGENERIC}
fi

ciop-log "INFO"  "Master orbit ${orbitmaster} extracted"

#extract slave

#set polarization in case the inputs are Sentinel-1 SM mode
pol=`grep -ih "POLARIS"  "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
export POL="${pol}"

handle_tars.pl --in="${localsl}"  --serverdir="${serverdir}" --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > "${serverdir}"/log/extract_slave.log 2<&1

norbits=`ls "${serverdir}"/ORB/*.orb | wc -l`

if [ $norbits -lt 2 ]; then
    ciop-log "ERROR"  "Slave image extraction failure"
    msg=`cat "${serverdir}"/log/extract_slave.log`
    ciop-log "ERROR"  "${msg}"
    procCleanup
    exit ${ERRGENERIC}
fi

orbitslave=`ls -tra "${serverdir}"/DAT/GEOSAR/*.geosar | tail -1 | xargs grep -ih "ORBIT NUMBER" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

ciop-log "INFO"  "Slave orbit ${orbitslave} extracted"

#a few checks
npass=`grep -ih "SATELLITE PASS" "${serverdir}"/DAT/GEOSAR/*.geosar | cut -b 40-1024 | sort --unique | wc -l`

if [ "$npass" != "1" ]; then
    ciop-log "ERROR" "images are of different satellite pass"
    procCleanup
    exit ${ERRGENERIC}
fi

#download precise orbits
for geosar in  `find "${serverdir}"/DAT/GEOSAR/ -iname "*.geosar" -print`; do
    sensor=`grep -i "SENSOR NAME" "${geosar}" | cut -b '40-1024' | sed 's@[[:space:]]@@g'`
    orbit=`grep -ih "ORBIT NUMBER" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    ciop-log "INFO"  "Downloading precise orbit data for orbit ${orbit}"
    case "$sensor" in
	ERS*) 
	    diaporb.pl --geosar="${geosar}" --type=delft  --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1
	    storb=$?
	
	    #try with prc orbits if first attempt fails
	    if [ $storb -ne  0 ]; then
		diaporb.pl --geosar="${geosar}" --type=prc  --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1
	    fi
	    
	    ;;
	ENVISAT*) 
	    diaporb.pl --geosar="${geosar}" --type=doris --mode=1 --dir="${serverdir}/VOR" --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 
	    storb=$?
	   
	    #try with remote orbits if first attempt fails
	    if [ $storb -ne  0 ]; then
		msg=`cat "${serverdir}/log/precise_orbits.log"`
		ciop-log "INFO" "${msg}"
		diaporb.pl --geosar="${geosar}" --type=doris   --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1
		storb=$?
		if [ $storb -ne 0 ]; then
		    diaporb.pl --geosar="${geosar}" --type=delft   --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1
		fi
	    fi
	    ;;
	S1*) diaporb.pl --geosar="${geosar}" --type=s1prc  --dir="${serverdir}/TEMP" --mode=1 --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 
	    #adjust the multilook parameters for S1 SM data
	    MLAZ=8
	    MLRAN=4
	    S1FLAG="YES"
	    ;;
    esac
    setlatlongeosar.pl --geosar="${geosar}" --exedir="${EXE_DIR}"
    
done


msroiopt=""
slroiopt="";

if [ -z "$inputaoi" ]; then

    #get the master & slave  overlapping region 
    msovlp=`sarovlp.pl --geosarm="${serverdir}"/DAT/GEOSAR/${orbitmaster}.geosar --geosars="${serverdir}"/DAT/GEOSAR/${orbitslave}.geosar  --exedir="${EXE_DIR}" --nocols  | grep ^l1`
    ovlpstatus=$?

    if [ $ovlpstatus -eq 255 ]; then
	ciop-log "ERROR " "Master and Slave image don't overlap "
	procCleanup
	exit ${ERRGENERIC}
    fi
    
    
    slovlp=`sarovlp.pl --geosars="${serverdir}"/DAT/GEOSAR/${orbitmaster}.geosar --geosarm="${serverdir}"/DAT/GEOSAR/${orbitslave}.geosar  --exedir="${EXE_DIR}" --nocols | grep ^l1`
    
    
else
    
    #user set an aoi
    msovlp=$(geosar_get_aoi_coords  "${serverdir}"/DAT/GEOSAR/${orbitmaster}.geosar "${inputaoi}"   "${serverdir}/TEMP")
    ovlpstatus=$?
    if [ $ovlpstatus -eq 255 ]; then
	ciop-log "ERROR " "Master image and input AOI  don't overlap "
	procCleanup
	exit ${ERRGENERIC}
    fi

    slovlp=$(geosar_get_aoi_coords  "${serverdir}"/DAT/GEOSAR/${orbitslave}.geosar "${inputaoi}"   "${serverdir}/TEMP")
    
    ovlpstatus=$?
    if [ $ovlpstatus -eq 255 ]; then
	ciop-log "ERROR " "Slave image and input AOI  don't overlap "
	procCleanup
	exit ${ERRGENERIC}
    fi
    
    echo "slave image aoi overlap : ${slovlp}" >> "${serverdir}/log/"/extract_slave.log 2<&1
    echo "master image aoi overlap : ${msovlp}" >> "${serverdir}/log/"/extract_master.log 2<&1
    
fi

[ -n "${msovlp}" ] && msroiopt="--procroi ${msovlp}"
    
[ -n "${slovlp}" ] && slroiopt="--procroi ${slovlp}"


for geosar in `find "${serverdir}"/DAT/GEOSAR/ -iname "*.geosar" -print`; do
	status=`grep -ih STATUS "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
	roiopt=""
	orbitnum=`grep -ih "ORBIT NUMBER" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
		
	#in case the image is level 0 , produce the slc
	if [ "$status" = "RAW" ];then
		if [ "$orbitnum" == "${orbitmaster}" ] && [ -n "${msovlp}" ]; then
		    roiopt="--procroi ${msovlp}"
		fi

		if [ "$orbitnum" == "${orbitslave}" ] && [ -n "${slovlp}" ]; then
		    roiopt="--procroi ${slovlp}"
		fi


		ciop-log "INFO" "Running L0 -> L1 processing for orbit ${orbitnum}"
		
		ciop-log "INFO" "Area cropping : ${roiopt}"
		prisme.pl --geosar="$geosar" --mltype=byt --tmpdir="${serverdir}/SLC_CI2" --outdir="${serverdir}/SLC_CI2" --rate --exedir="${EXE_DIR}" ${roiopt}  > ${serverdir}/log/prisme_${orbitnum}.log 2<&1
		
		[ "$?" == "0" ] || {
		   ciop-log "ERROR"  "L0 -> L1 processing failed for orbit ${orbitnum}"
		   msg=`cat ${serverdir}/log/prisme_${orbitnum}.log`
		   ciop-log "INFO"  "$msg"
		   exit ${ERRGENERIC}
		}
	else
	    #cut slc 
	    if [ "$orbitnum" == "${orbitmaster}" ] && [ -n "${msovlp}" ]; then
		roiopt="--roi=${msovlp}"
	    fi
	    
	    if [ "$orbitnum" == "${orbitslave}" ] && [ -n "${slovlp}" ]; then
		roiopt="--roi=${slovlp}"
	    fi
	    
	    [ -n "${roiopt}" ] && { 
		slcroi.pl --geosar="${geosar}" "${roiopt}" --exedir="${EXE_DIR}" >> ${serverdir}/log/slcroi.log 2<&1
		setlatlongeosar.pl --geosar="${geosar}" --exedir="${EXE_DIR}" >> ${serverdir}/log/slcroi.log 2<&1
	    }
	fi
done


demDownload "${serverdir}" || {
    #no DEM data , exit
    procCleanup
    exit ${ERRMISSING}
}

#alt_ambig
ls "${serverdir}"/ORB/*.orb | alt_ambig.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --exedir="${EXE_DIR}" -o "${serverdir}/DAT/AMBIG.dat" > "${serverdir}/log/alt_ambig.log" 2<&1

#create multilook


find "${serverdir}/DAT/GEOSAR/" -iname "*.geosar"  -print | ml_all.pl --type=byt --mlaz=${MLAZ} --mlran=${MLRAN} --dir="${serverdir}/SLC_CI2/" > "${serverdir}/log/ml.log" 2<&1

#resampling
check_resampling "${serverdir}" "${orbitmaster}" "${orbitslave}" "${MLAZ}" "${MLRAN}"

#precise sm
[ "$S1FLAG" != "YES" ] && precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --serverdir="${serverdir}" --rlcheck --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}/log/precise_${orbitmaster}.log" 2<&1 
    


[ "$S1FLAG" == "YES" ] && precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --serverdir="${serverdir}" --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" --noroughlock --shiftaz=0 --shiftran=0 > "${serverdir}/log/precise_${orbitmaster}.log" 2<&1


#precstatus=$?

#if [ ${precstatus} -ne 0  ]; then
#precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --serverdir="${serverdir}" --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" --noroughlock --shiftaz=0 --shiftran=0   >> "${serverdir}/log/precise_${orbitmaster}.log" 2<&1
#fi

#precise sm
#precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --serverdir="${serverdir}" --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}/log/precise_${orbitslave}.log" 2<&1

#coregistration
ciop-log "INFO"  "Running Image Coregistration"
coreg.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --prog=correl_window --expwinazi="${expwinazi}" --expwinran="${expwinran}" --winazi="${winazi}" --winran="${winran}" --thr="${corrthr}" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --griddir="${serverdir}/GRID" --outdir="${serverdir}/GEO_CI2" --mltype=byt  --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}"/log/coregistration.log 2<&1

corstatus=$?
 
[ $corstatus -ne 0 ] && {
    ciop-log "ERROR" "Image coregistration failed"
    procCleanup
    exit ${ERRGENERIC}
}

#fine coregistration
#lincor.pl --geosardir="${serverdir}/DAT/GEOSAR" --exedir="${EXE_DIR}" --smresamp="${serverdir}/SLC_CI2/${orbitmaster}_SLC.ci2" --ci2slave="${serverdir}/GEO_CI2/geo_${orbitslave}_${orbitmaster}.ci2" --outdir="${serverdir}/GEO_CI2_EXT_LIN" --griddir="${serverdir}/GRID_LIN" --interpx=1 --mlaz="${MLAZ}" --mlran="${MLRAN}" --gsm="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --gsl="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --azinterval=20 --rainterval=20 --expwinazi=5 --expwinran=5 --demdesc="${DEM}" >> "${serverdir}"/log/lincor.log 2<&1


#interferogram generation

#ML Interf
ciop-log "INFO"  "Running ML  Interferogram Generation"
interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad  --demdesc="${DEM}" --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz=1 --mlran=1 --winazi="${MLAZ}" --winran="${MLRAN}" --amp --coh --nobort --noran --noinc --ortho --psfilt --orthodir="${serverdir}/GEOCODE" --psfiltx="${psfiltx}"  > "${serverdir}/log/interf.log" 2<&1

interfstatus=$?
 
[ $interfstatus -ne 0 ] && {
    ciop-log "ERROR" "Interferogram generation failed"
    procCleanup
    exit ${ERRGENERIC}
}

#11 Interf
ciop-log "INFO"  "Running Full resolution Interferogram Generation"
#interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz=1 --mlran=1 --amp --nocoh --nobort --noran --noinc > "${serverdir}/log/interf.log" 2<&1
 
 
#ortho
ciop-log "INFO"  "Running InSAR results ortho-projection"
ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="amp_${orbitmaster}_${orbitslave}_ml11" --in="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml11.r4"   > "${serverdir}"/log/ortho.log 2<&1
 
cp "${serverdir}"/log/ortho.log ${serverdir}/ortho_amp.log

 #ortho ML
#ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --cplx --amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.r4" --pha="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.pha"  > "${serverdir}"/log/ortho_ml.log 2<&1

#ortho coh
#ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="coh_${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --in="${serverdir}/DIF_INT/coh_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.rad"   > "${serverdir}"/log/ortho_ml_coh.log 2<&1

#output geotiff files
cohorthotif="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml_ortho.tif"
cohorthotifrgb="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml_ortho.rgb.tif"
amporthotif="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ortho.tif"
amporthotifrgb="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ortho.rgb.tif"
phaorthotif="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.tif"
phaorthotifrgb="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.rgb.tif"
unworthotif="${serverdir}/GEOCODE/unw_${orbitmaster}_${orbitslave}_ortho.tif"
unworthotifrgb="${serverdir}/GEOCODE/unw_${orbitmaster}_${orbitslave}_ortho.rgb.tif"

#creating geotiff results
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"  --mask --min=1 --max=255 --colortbl=BLACK-WHITE  --outfile="${cohorthotifrgb}" >> "${serverdir}"/log/ortho_ml_coh.log 2<&1

ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"   --outfile="${cohorthotif}" >> "${serverdir}"/log/ortho_ml_coh.log 2<&1

#ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.rad" --demdesc="${DEM}"  --alpha="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ortho.rad" --mask   --outfile="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.tif" --colortbl=BLUE-RED  >> "${serverdir}"/log/ortho.log 2<&1
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/psfilt_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"  --alpha="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --mask --min=1 --max=255   --outfile="${phaorthotifrgb}" --colortbl=BLUE-RED  >> "${serverdir}"/log/ortho.log 2<&1

ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"    --outfile="${amporthotif}" >> "${serverdir}"/log/ortho.log 2<&1

ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"    --outfile="${amporthotifrgb}" --gep --mask --min=1 --max=255 --alpha="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml11_ortho.rad"   >> "${serverdir}"/log/ortho.log 2<&1



#unwrap
if [ "${unwrap}" == "true"  ]; then
    ciop-log "INFO"  "Configuring phase unwrapping"
    
    

    unwmlaz=`echo "${MLAZ}*2" | bc -l`
    unwmlran=`echo "${MLRAN}*2" | bc -l`
    
    interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad  --demdesc="${DEM}" --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}"  --mlaz="${unwmlaz}" --mlran="${unwmlran}" --amp --coh --bort --ran --inc  > "${serverdir}/log/interf_mlunw.log" 2<&1
    
    

    snaphucfg="/${serverdir}/TEMP/snaphu_template.txt"
    cp /opt/diapason/gep.dir/snaphu_template.txt "${snaphucfg}"
    chmod 775 "${snaphucfg}"
    
#compute additionnal parameters passed to snaphu                                                                     
    
#BPERP                                                                                                               
    bortfile=${serverdir}/DIF_INT/bort_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}.r4

    bperp=`view_raster.pl --file="${bortfile}" --type=r4 --count=1000 | awk '{v = $1 ; avg += v ;} END { print avg/NR }'`
    echo "BPERP ${bperp}" >> "${snaphucfg}"
    
    lnspc=`grep "LINE SPACING" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    colspc=`grep "PIXEL SPACING RANGE" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    mlslres=`echo "${colspc}*${unwmlran}"  | bc -l`
    mlazres=`echo "${lnspc}*${unwmlaz}"  | bc -l`
    
    echo "RANGERES ${mlslres}" >> "${snaphucfg}"
    echo "AZRES ${mlazres}" >> "${snaphucfg}"
    
    snaphutemp="${serverdir}/TEMP/saphu_parm"
    
#now write the geosar inferred parameters                                                             
    ${EXE_DIR}/dump_snaphu_params  >  "${snaphutemp}"   <<EOF  
${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar
EOF
    
    grep [0-9] "${snaphutemp}" | grep -iv diapason >> "${snaphucfg}"
    
#unwrapped phase
    unwpha="${serverdir}/DIF_INT/unw_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}.r4"
#amplitude
    amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}.r4"
#coherence     
    coh="${serverdir}/DIF_INT/coh_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}.byt"
    
    echo "OUTFILE ${unwpha}" >> "${snaphucfg}"
    echo "AMPFILE ${amp}" >> "${snaphucfg}"
    echo "CORRFILE ${coh}" >> "${snaphucfg}"
    
    export WDIR="${serverdir}/DIF_INT"

#make a copy of the snaphu configuration as ad_unwrap.sh deletes the file
    
    cfgtemp="${serverdir}/TEMP/snaphu_configuration.txt"
    
    cp "${snaphucfg}" "${cfgtemp}"
    
    
    unwrapinput="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}.pha"
    unwrapcmd="/opt/diapason/gep.dir/ad_unwrap.sh \"${cfgtemp}\" \"${unwrapinput}\""
    
    ciop-log "INFO"  "Running phase unwrapping"
    cd ${serverdir}/TEMP
    touch fcnts.sh
    chmod 775 fcnts.sh
    eval "${unwrapcmd}" > ${serverdir}/log/unwrap.log 2<&1
    cd -
    if [ -e "${unwpha}" ]; then
	#run ortho on unwrapped phase
	ciop-log "INFO"  "Running Unwrapping results ortho-projection"
	ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --real  --mlaz="${unwmlaz}" --mlran="${unwmlran}"  --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="unw_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}" --in="${unwpha}"   > "${serverdir}"/log/ortho_unw.log 2<&1
	ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/unw_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}_ortho.rad" --alpha="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --mask --min=1 --max=255 --colortbl=BLUE-RED  --demdesc="${DEM}" --outfile="${unworthotifrgb}" >> "${serverdir}"/log/ortho_unw.log 2<&1
	unwtif="${serverdir}/GEOCODE/unw_${orbitmaster}_${orbitslave}_ortho.tif"
	
	if [ ! -e "${unwtif}" ]; then
	    ciop-log "ERROR" "Phase unwrapping failed"
	    #procCleanup
	    #exit ${ERRGENERIC}
	fi

    else
	ciop-log "ERROR" "Phase unwrapping failed"
	#procCleanup
	#exit ${ERRGENERIC}
    fi
    
fi


#publish results
ciop-log "INFO"  "Processing Ended. Publishing results"

#restrict the output extent so that it matches the aoi
[ -n "${inputaoi}" ] &&  crop_geotiff2_to_aoi "${serverdir}" "${inputaoi}"

#generate wkt info file
wkt=$(tiff2wkt "`ls ${serverdir}/GEOCODE/amp*.tif | head -1`")

echo "${wkt}" > ${serverdir}/wkt.txt




#grayscale phase tiff results
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/unw_${orbitmaster}_${orbitslave}_ml${unwmlaz}${unwmlran}_ortho.rad"   --demdesc="${DEM}" --outfile="${unworthotif}" >> "${serverdir}"/log/ortho_unw.log 2<&1
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/psfilt_${orbitmaster}_${orbitslave}_ml11_ortho.rad" --demdesc="${DEM}"  --outfile="${phaorthotif}"  >> "${serverdir}"/log/ortho.log 2<&1


create_interf_properties "${amporthotif}" "Interferometric Amplitude" "${serverdir}" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" "${serverdir}/DAT/GEOSAR/${orbitslave}.geosar"

create_interf_properties "${phaorthotif}" "Interferometric Phase" "${serverdir}" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" "${serverdir}/DAT/GEOSAR/${orbitslave}.geosar"

create_interf_properties "${cohorthotif}" "Interferometric Coherence" "${serverdir}" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" "${serverdir}/DAT/GEOSAR/${orbitslave}.geosar"

if [ "${unwrap}" == "true" ] && [ -e "${unworthotif}" ] ; then
    create_interf_properties "${unworthotif}" "Unwrapped Phase" "${serverdir}" "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" "${serverdir}/DAT/GEOSAR/${orbitslave}.geosar"
    gdaladdo -r average "${unworthotifrgb}" 2 4 8 
fi

gdaladdo -r average "${amporthotifrgb}" 2 4 8
gdaladdo -r average "${phaorthotifrgb}" 2 4 8
gdaladdo -r average "${cohorthotifrgb}" 2 4 8

ciop-publish -m "${serverdir}"/GEOCODE/*.properties
ciop-publish -m "${serverdir}"/GEOCODE/*.tif

#processing log files
logzip="${serverdir}/TEMP/logs.zip"
cd "${serverdir}"
zip "${logzip}" log/*
ciop-publish -m "${logzip}"
cd -

#publish geotiff files
mkdir -p ${serverdir}/GEOTIFF
find ${serverdir}/GEOCODE/ -iname "*.tif" -exec mv '{}' ${serverdir}/GEOTIFF \;
cd ${serverdir}/GEOTIFF
prodzip="${serverdir}/GEOTIFF/products.zip"

cd -




#cleanup our processing directory
procCleanup

break

done


exit ${SUCCESS}
