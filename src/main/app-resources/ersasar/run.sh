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
	ciop-log "ERROR : Signal was trapped . Cleaning up processing directory ${serverdir}"
	rm -rf "${serverdir}"
    fi
    exit 
}


#setup the Diapason environment
export LANGUE=en
export PERL5LIB=$_CIOP_APPLICATION_PATH/diapason/pldiap/lib
export PATH=$PATH:$_CIOP_APPLICATION_PATH/diapason/pldiap/bin
export EXE_DIR=$_CIOP_APPLICATION_PATH/diapason/exe.dir
export DAT_DIR=$_CIOP_APPLICATION_PATH/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}


#inputs
#MASTER=/mnt/DATA/DISK/GTEP_TEST/CD/ASA_IM__0CNPDE20040403_215242_000000162025_00373_10948_1023.N1
#SLAVE=/mnt/DATA/DISK/GTEP_TEST/CD/ASA_IM__0CNPDE20040508_215241_000000162026_00373_11449_0704.N1
#DEM=/mnt/DATA/DISK/GTEP_TEST/DAT/dem.dat

MASTER="" #/mnt/DATA/DISK/DIAPASON_V4.4_NO_DEM_RELEASE/BAM/9192/ASA_IM__0CNPDE20031203_061256_000000152022_00120_09192_0964.N1
SLAVE=""  #=/mnt/DATA/DISK/DIAPASON_V4.4_NO_DEM_RELEASE/BAM/10194/ASA_IM__0CNPDE20040211_061253_000000152024_00120_10194_3246.N1
DEM="" #/mnt/DATA/DISK/GTEP_TEST/DAT/dem_bam_srtm.dat

#PARAMS
MLAZ=10
MLRAN=2

#
#rootdir=${TMPDIR}
rootdir=${HOME}

#cleanup old directories
rm -rf  "${rootdir}"/DIAPASON_* 


# read inputs from stdin
# the input is  a comma-separated line, first record is master image
#second record is slave image
#third record is DEM
while read data
do

#make sure some data was read
if [ -z "$data" ]; then
    break
fi  

inputlist=(`echo "$data" | sed 's@,@ @g'`)

#check the number of records
ninputs=${#inputlist[@]}
if [ $ninputs -lt 3 ]; then
    ciop-log "ERROR : Expected 3 inputs , got ${ninputs}"
    exit ${ERRMISSING}
fi

MASTER=${inputlist[0]}
SLAVE=${inputlist[1]}
DEM=${inputlist[2]}


if [ -z "$MASTER" ] || [ -z "${SLAVE}" ] || [ -z "${DEM}" ]; then
    ciop-log "ERROR : Missing Input file . MASTER->$MASTER , SLAVE->$SLAVE ,DEM->$DEM"
    exit ${ERRMISSING}
fi 



#create processing directory
unset serverdir
export serverdir=`mktemp -d ${rootdir}/DIAPASON_XXXXXX` || {
ciop-log "ERROR : Cannot create processing directory"
exit ${ERRPERM}
}

#trap signals
trap procCleanup SIGHUP SIGINT SIGTERM


#create directory tree
mkdir -p ${serverdir}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD} || {
ciop-log "ERROR : Cannot create processing directory structure"
 exit ${ERRPERM}
}



#TO-DO check the input file type correctedness

#stage-in the data
localms=`ciop-copy -o "${serverdir}/CD" "${MASTER}" `

[  "$?" == "0"  -a -e "${localms}" ] || {
    ciop-log "ERROR : Failed to download file ${MASTER}"
    exit ${ERRSTGIN}
}

localsl=`ciop-copy -o "${serverdir}/CD" "${SLAVE}" `

[  "$?" == "0"  -a -e "${localsl}" ] || {
    ciop-log "ERROR : Failed to download file ${SLAVE}"
    exit ${ERRSTGIN}
}

#TO-DO handle DEM download and conversion

#extract inputs

#extract master
handle_tars.pl --in="${localms}"  --serverdir="${serverdir}" --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > "${serverdir}"/log/extract_master.log 2<&1

orbitmaster=`grep -ih "ORBIT NUMBER" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

if [ -z "${orbitmaster}" ]; then
	ciop-log "ERROR : Master image extraction failure"
	msg=`cat "${serverdir}"/log/extract_master.log`
	ciop-log "ERROR : ${msg}"
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
    exit ${ERRGENERIC}
fi

orbitslave=`ls -tra "${serverdir}"/DAT/GEOSAR/*.geosar | tail -1 | xargs grep -ih "ORBIT NUMBER" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`

ciop-log "INFO : Slave orbit ${orbitslave} extracted"


#download precise orbits
#TO-DO : handle ERS/ASAR , doris/delft
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
	fi
done

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
interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz="${MLAZ}" --mlran="${MLRAN}" --amp --coh --nobort --noran --noinc > "${serverdir}/log/interf.log" 2<&1
 
#11 Interf
ciop-log "INFO : Running Full resolution Interferogram Generation"
interf_sar.pl --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --ci2slave="${serverdir}"/GEO_CI2/geo_"${orbitslave}"_"${orbitmaster}".rad --outdir="${serverdir}/DIF_INT" --exedir="${EXE_DIR}" --mlaz=1 --mlran=1 --amp --nocoh --nobort --noran --noinc > "${serverdir}/log/interf.log" 2<&1
 
 
#ortho
ciop-log "INFO : Running InSAR results ortho-projection"
ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="${orbitmaster}_${orbitslave}" --cplx --amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml11.r4" --pha="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml11.pha"  > "${serverdir}"/log/ortho.log 2<&1
 
 #ortho ML
ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --cplx --amp="${serverdir}/DIF_INT/amp_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.r4" --pha="${serverdir}/DIF_INT/pha_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.pha"  > "${serverdir}"/log/ortho_ml.log 2<&1

#ortho coh
ortho.pl --geosar="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --odir="${serverdir}/GEOCODE" --exedir="${EXE_DIR}" --tag="coh_${orbitmaster}_${orbitslave}_ml"  --mlaz="${MLAZ}" --mlran="${MLRAN}" --in="${serverdir}/DIF_INT/coh_${orbitmaster}_${orbitslave}_ml${MLAZ}${MLRAN}.rad"   > "${serverdir}"/log/ortho_ml_coh.log 2<&1


#publish results
ciop-log "INFO : Processing Ended. Publishing results"
#generated ortho files
ciop-publish "${serverdir}"/GEOCODE/*

#processing log files
ciop-publish "${serverdir}"/log/*

#cleanup our processing directory
ciop-log "INFO : Cleaning up processing directory ${serverdir}"
rm -rf "${serverdir}"

break

done


exit ${SUCCESS}
