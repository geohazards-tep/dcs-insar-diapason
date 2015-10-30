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
    
    url="http://www.altamira-information.com/demdownload?lat="${latitudes[0]}"&lat="${latitudes[1]}"&lon="${longitudes[0]}"&lon="${longitudes[1]}
    
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
    
    sed -i -e 's@\(CENTER LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(CENTER LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(LL LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LR LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UL LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UR LATITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LR LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UL LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g;s@\(UR LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"
    sed -i -e 's@\(LL LONGITUDE\)\([[:space:]]*\)\(.*\)@\1\2---@g' "${tmpgeosar}"

    #set the lat/long from the aoi
    local cmdll="sed -i -e 's@\(LL LATITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${aoi[1]}"@g' \"${tmpgeosar}\""
    local cmdul="sed -i -e 's@\(UL LATITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${aoi[3]}"@g' \"${tmpgeosar}\""
    
    local cmdlll="sed -i -e 's@\(LL LONGITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${aoi[0]}"@g' \"${tmpgeosar}\""
    local cmdull="sed -i -e 's@\(UL LONGITUDE\)\([[:space:]]*\)\([^\n]*\)@\1\2"${aoi[2]}"@g' \"${tmpgeosar}\""
    
    
    
    eval "${cmdll}"
    eval "${cmdul}"
    eval "${cmdull}"
    eval "${cmdlll}"
    
    if [ -z "${EXE_DIR}" ]; then
	EXE_DIR=/mnt/DATA/DISK/TEMP/DIAP_TEMP/install/exe.dir/
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

# get the catalogue access point
inputaoi=(`ciop-getparam aoi`)


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
	ERS*) diaporb.pl --geosar="${geosar}" --type=delft  --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 ;;
	ENVISAT*) 
	    diaporb.pl --geosar="${geosar}" --type=doris --mode=1 --dir="${serverdir}/VOR" --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 
	    storb=$?
	   
	    #try with remote orbits if first attempt fails
	    if [ $storb -ne  0 ]; then
		msg=`cat "${serverdir}/log/precise_orbits.log"`
		ciop-log "INFO" "${msg}"
		diaporb.pl --geosar="${geosar}" --type=doris   --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1
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
coreg.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar"  --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --griddir="${serverdir}/GRID" --outdir="${serverdir}/GEO_CI2" --mltype=byt  --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}"/log/coregistration.log 2<&1


#interferogram generation

#ML Interf
ciop-log "INFO"  "Running ML  Interferogram Generation"
interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad  --demdesc="${DEM}" --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz="${MLAZ}" --mlran="${MLRAN}" --amp --coh --nobort --noran --noinc --ortho --psfilt --orthodir="${serverdir}/GEOCODE"   > "${serverdir}/log/interf.log" 2<&1
 
#11 Interf
ciop-log "INFO"  "Running Full resolution Interferogram Generation"
#interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz=1 --mlran=1 --amp --nocoh --nobort --noran --noinc > "${serverdir}/log/interf.log" 2<&1
 
 
#ortho
ciop-log "INFO"  "Running InSAR results ortho-projection"
#ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="${orbitmaster}_${orbitslave}" --cplx --amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml11.r4" --pha="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml11.pha"  > "${serverdir}"/log/ortho.log 2<&1
 
 #ortho ML
#ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --cplx --amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.r4" --pha="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.pha"  > "${serverdir}"/log/ortho_ml.log 2<&1

#ortho coh
#ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="coh_${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --in="${serverdir}/DIF_INT/coh_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.rad"   > "${serverdir}"/log/ortho_ml_coh.log 2<&1

#creating geotiff results
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}_ortho.rad" --demdesc="${DEM}" --outfile="${serverdir}/GEOCODE/coh_${orbitmaster}_${orbitslave}_ml_ortho.tif" >> "${serverdir}"/log/ortho_ml_coh.log 2<&1

#ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.rad" --demdesc="${DEM}"  --alpha="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ortho.rad" --mask   --outfile="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.tif" --colortbl=BLUE-RED  >> "${serverdir}"/log/ortho.log 2<&1
ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/psfilt_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}_ortho.rad" --demdesc="${DEM}"  --alpha="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}_ortho.rad" --mask   --outfile="${serverdir}/GEOCODE/pha_${orbitmaster}_${orbitslave}_ortho.tif" --colortbl=BLUE-RED  >> "${serverdir}"/log/ortho.log 2<&1

ortho2geotiff.pl --ortho="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}_ortho.rad" --demdesc="${DEM}" --outfile="${serverdir}/GEOCODE/amp_${orbitmaster}_${orbitslave}_ortho.tif" >> "${serverdir}"/log/ortho.log 2<&1


#publish results
ciop-log "INFO"  "Processing Ended. Publishing results"
#generated ortho files
ciop-publish -m "${serverdir}"/GEOCODE/*.tif

#convert all the tif files to png so that the results can be seen on the GeoBrowser

#first do the coherence and amplitude ,for which 0 is a no-data value
for tif in `find "${serverdir}/GEOCODE/"*.tif* -print`; do
    target=${tif%.*}.png
    gdal_translate -scale -oT Byte -of PNG -co worldfile=yes -a_nodata 0 "${tif}" "${target}" >> "${serverdir}"/log/ortho.log 2<&1
    #convert the world file to pngw extension
    wld=${target%.*}.wld
    pngw=${target%.*}.pngw
    [ -e "${wld}" ] && mv "${wld}"  "${pngw}"
done

#convert the phase with imageMagick , which can deal with the alpha channel
if [ -n "`type -p convert`" ]; then
    phase=`ls ${serverdir}/GEOCODE/*pha*.tif* | head -1`
    [ -n "$phase" ] && convert -alpha activate "${phase}" "${phase%.*}.png"
fi

#publish png and their pngw files
ciop-publish -m "${serverdir}"/GEOCODE/*.png
ciop-publish -m "${serverdir}"/GEOCODE/*.pngw


#processing log files
logzip="${serverdir}/TEMP/logs.zip"
cd "${serverdir}"
zip "${logzip}" log/*
ciop-publish -m "${logzip}"
cd -

#cleanup our processing directory
procCleanup

break

done


exit ${SUCCESS}
