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
	ciop-log "INFO : Cleaning up processing directory ${serverdir}"
	rm -rf "${serverdir}"
    fi
    
}

#trap signals
function trapFunction()
{
    procCleanup
    ciop-log "ERROR : Signal was trapped"
    exit 
}

# dem download 
function demDownload()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    #check for required programs 
    if [ -z "`type -p curl`" ] ; then
	ciop-log "ERROR : System missing curl utility" return
	${ERRMISSING} 
    fi
	
    if [ -z "`type -p tiffinfo`" ] ; then
	ciop-log "ERROR : System missing tiffinfo utility" return
	${ERRMISSING} 
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
    
    ciop-log "INFO : Downloading DEM from ${url}"
    
    demtif=${procdir}/DAT/dem.tif
    
    downloadcmd="curl -o \"${demtif}\" \"${url}\" "

    eval "${downloadcmd}" > "${procdir}"/log/demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR : Unable to download DEM data"
	return ${ERRGENERIC}
    fi
    
    #check it is a tiff
    tiffinfo "${demtif}" || {
	ciop-log "ERROR : No DEM data over selected area"
	return ${ERRGENERIC}
    }
    
    #generate DEM descriptor in diapason format
    tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DAT" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" > "${procdir}/log/deminport.log" 2<&1

export DEM="${procdir}/DAT/dem.dat"


if [ ! -e "${DEM}" ]; then
    ciop-log "ERROR : Failed to convert downloaded DEM data"
    msg=`cat "${procdir}/log/deminport.log"`
    ciop-log "INFO : ${msg}"
    
    return ${ERRGENERIC}
fi

ciop-log "INFO : DEM descriptor creation done "

return ${SUCCESS}

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

#
rootdir=${TMPDIR}



#cleanup old directories
rm -rf  "${rootdir}"/DIAPASON_* 


# read inputs from stdin
# the input is  a colon-separated line, first record is master image
#second record is slave image
while read master
do

#make sure some data was read
if [ -z "$master" ]; then
    break
fi  

inputlist=(`echo "$data" | sed 's@[,;]@ @g;s@\(:\)\([^/]\)@ \2@g'`)

MASTER=${master}
SLAVE=$(ciop-getparam slave)
#DEM=${inputlist[2]}
ciop-log "DEBUG" "Master $master and Slave $SLAVE"

if [ -z "$MASTER" ] || [ -z "${SLAVE}" ] ; then
    ciop-log "ERROR : Missing Input file . MASTER->$MASTER , SLAVE->$SLAVE "
    exit ${ERRMISSING}
fi 



#create processing directory
unset serverdir
export serverdir=`mktemp -d ${rootdir}/DIAPASON_XXXXXX` || {
ciop-log "ERROR : Cannot create processing directory"
exit ${ERRPERM}
}

ciop-log "INFO : processing in directory ${serverdir}"

#trap signals
trap trapFunction SIGHUP SIGINT SIGTERM


#create directory tree
mkdir -p ${serverdir}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD,GEO_CI2} || {
ciop-log "ERROR : Cannot create processing directory structure"
 exit ${ERRPERM}
}



#TO-DO check the input file type correctedness

#stage-in the data
localms=`ciop-copy -o "${serverdir}/CD" "${MASTER}" `

[  "$?" == "0"  -a -e "${localms}" ] || {
    ciop-log "ERROR : Failed to download file ${MASTER}"
    procCleanup
    exit ${ERRSTGIN}
}

localsl=`ciop-copy -o "${serverdir}/CD" "${SLAVE}" `

[  "$?" == "0"  -a -e "${localsl}" ] || {
    ciop-log "ERROR : Failed to download file ${SLAVE}"
    procCleanup
    exit ${ERRSTGIN}
}


#extract inputs

#extract master
handle_tars.pl --in="${localms}"  --serverdir="${serverdir}" --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > "${serverdir}"/log/extract_master.log 2<&1

orbitmaster=`grep -ih "ORBIT NUMBER" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

if [ -z "${orbitmaster}" ]; then
	ciop-log "ERROR : Master image extraction failure"
	msg=`cat "${serverdir}"/log/extract_master.log`
	ciop-log "ERROR : ${msg}"
	procCleanup
	exit ${ERRGENERIC}
fi

ciop-log "INFO : Master orbit ${orbitmaster} extracted"

#extract slave
handle_tars.pl --in="${localsl}"  --serverdir="${serverdir}" --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > "${serverdir}"/log/extract_slave.log 2<&1

norbits=`ls "${serverdir}"/ORB/*.orb | wc -l`

if [ $norbits -lt 2 ]; then
    ciop-log "ERROR : Slave image extraction failure"
    msg=`cat "${serverdir}"/log/extract_slave.log`
    ciop-log "ERROR : ${msg}"
    procCleanup
    exit ${ERRGENERIC}
fi

orbitslave=`ls -tra "${serverdir}"/DAT/GEOSAR/*.geosar | tail -1 | xargs grep -ih "ORBIT NUMBER" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

ciop-log "INFO : Slave orbit ${orbitslave} extracted"


#download precise orbits
for geosar in  `find "${serverdir}"/DAT/GEOSAR/ -iname "*.geosar" -print`; do
    sensor=`grep -i "SENSOR NAME" "${geosar}" | cut -b '40-1024' | sed 's@[[:space:]]@@g'`
    orbit=`grep -ih "ORBIT NUMBER" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    ciop-log "INFO : Downloading precise orbit data for orbit ${orbit}"
    case "$sensor" in
	ERS*) diaporb.pl --geosar="${geosar}" --type=delft  --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 ;;
	ENVISAT*) diaporb.pl --geosar="${geosar}" --type=doris  --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/precise_orbits.log" 2<&1 ;;
    esac
   
done


for geosar in `find "${serverdir}"/DAT/GEOSAR/ -iname "*.geosar" -print`; do
	status=`grep -ih STATUS "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
	
	#in case the image is level 0 , produce the slc
	if [ "$status" = "RAW" ];then
		orbitnum=`grep -ih "ORBIT NUMBER" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
		ciop-log "INFO : Running L0 -> L1 processing for orbit ${orbitnum}"
		prisme.pl --geosar="$geosar" --mltype=byt --dir="${serverdir}/SLC_CI2" --outdir="${serverdir}/SLC_CI2" --rate --exedir="${EXE_DIR}" > ${serverdir}/log/prisme_${orbitnum}.log 2<&1
		
		[ "$?" == "0" ] || {
		   ciop-log "ERROR : L0 -> L1 processing failed for orbit ${orbitnum}"
		   msg=`cat ${serverdir}/log/prisme_${orbitnum}.log`
		   ciop-log "INFO : $msg"
		   exit ${ERRGENERIC}
		}
	fi
	
	setlatlongeosar.pl --geosar="$geosar" --exedir="${EXE_DIR}"
done


demDownload "${serverdir}" || {
    #no DEM data , exit
    procCleanup
    exit ${ERRMISSING}
}

#alt_ambig
ls "${serverdir}"/ORB/*.orb | alt_ambig.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --exedir="${EXE_DIR}" -o "${serverdir}/DAT/AMBIG.dat" > "${serverdir}/log/alt_ambig.log" 2<&1

#create multilook
find "${serverdir}/DAT/GEOSAR/" -iname "*.geosar"  -print | ml_all.pl --type=byt --mlaz=10 --mlran=2 --dir="${serverdir}/SLC_CI2/" > "${serverdir}/log/ml.log" 2<&1

#precise sm
precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --serverdir="${serverdir}" --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}/log/precise_${orbitmaster}.log" 2<&1

#precise sm
#precise_sm.pl --sm="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --serverdir="${serverdir}" --recor --demdesc="${DEM}" --exedir="${EXE_DIR}" > "${serverdir}/log/precise_${orbitslave}.log" 2<&1

#coregistration
ciop-log "INFO : Running Image Coregistration"
coreg.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar"  --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --griddir="${serverdir}/GRID" --outdir="${serverdir}/GEO_CI2" --mltype=byt --exedir="${EXE_DIR}" > "${serverdir}"/log/coregistration.log 2<&1


#interferogram generation

#ML Interf
ciop-log "INFO : Running ML  Interferogram Generation"
interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz="${MLAZ}" --mlran="${MLRAN}" --amp --coh --nobort --noran --noinc --ortho --psfilt --orthodir="${serverdir}/GEOCODE"   > "${serverdir}/log/interf.log" 2<&1
 
#11 Interf
ciop-log "INFO : Running Full resolution Interferogram Generation"
#interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz=1 --mlran=1 --amp --nocoh --nobort --noran --noinc > "${serverdir}/log/interf.log" 2<&1
 
 
#ortho
ciop-log "INFO : Running InSAR results ortho-projection"
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
ciop-log "INFO : Processing Ended. Publishing results"
#generated ortho files
ciop-publish "${serverdir}"/GEOCODE/*.tif

#processing log files
logzip="${serverdir}/TEMP/logs.zip"
cd "${serverdir}"
zip "${logzip}" log/*
ciop-publish "${logzip}"
cd -

#cleanup our processing directory
procCleanup

break

done


exit ${SUCCESS}
