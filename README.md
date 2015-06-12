## Developer Cloud Sandbox for InSAR interferogram generation with the Diapason processor 


This package contains wrapper scripts for InSAR processing of ERS or Envisat ASAR pairs with the Diapason software.
Diapason is a proprietary InSAR processing system maintained by Altamira-Information (wwww.altamira-information.com)

### Getting started

This application requires the diapason package to be installed , and runs on a Developer Cloud Sandbox , that can be either requested from:
* ESA [Geohazards Exploitation Platform](https://geohazards-tep.eo.esa.int) for GEP early adopters;
* ESA [Research & Service Support Portal](http://eogrid.esrin.esa.int/cloudtoolbox/) for ESA G-POD related projects and ESA registered user accounts
* From [Terradue's Portal](http://www.terradue.com/partners), provided user registration approval. 


### Installation

Log on your developer cloud sandbox and from a command line shell ,run the following commands :

```bash
git clone git@github.com:pordoqui/dcs-template-insar-diapason.git
cd dcs-template-insar-diapason
mvn install
```


### Processing overview

This service creates the interferometric phase,coherence and reflectivity from an InSAR pair .

The steps performed are :
* SLC generation (when the inputs are Level 0 )
* Image coregistration 
* InSAR generation
* Georeference the InSAR results
* Publish the results

The default master/slave couple is :
https://eo-virtual-archive4.esa.int/supersites/ASA_IM__0CNPDE20100215_152550_000001202086_00498_41634_8487.N1 (master)
https://eo-virtual-archive4.esa.int/supersites/ASA_IM__0CNPDE20100426_152543_000000302088_00498_42636_0225.N1 (slave)

Other master/slave pairs may be specified by editing the [application.xml] file 


### Launch the processing

The processing may be run in a shell :

```bash
ciop-run
```
Or it may be submitted with the WPS service available on the Sandbox dashboard , and specifying the inSAR pair to 
process by setting the master and slave image URL , separated by a colon eg :

https://eo-virtual-archive4.esa.int/supersites/ASA_IM__0CNPAM20090201_092428_000000162076_00079_36205_3967.N1:https://eo-virtual-archive4.esa.int/supersites/ASA_IM__0CNPDE20090412_092426_000000162078_00079_37207_1556.N

