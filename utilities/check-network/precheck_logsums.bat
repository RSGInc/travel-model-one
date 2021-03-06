::~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
::
:: check_logsums
::
:: Utility to generate preliminary skims and logsum diff maps prior to full model run
:: Designed to be run on one of the old modeling machines (mainmodel or a satmodel machine)
:: in \\mainmodel\MainModelShare\Projects_precheck\[model_run_id]
::
::~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

:: add goto here if resuming

:: ------------------------------------------------------------------------------------------------------
::
:: Step 0: set file location and folder structure
::
:: ------------------------------------------------------------------------------------------------------

:: Location of BASE MODEL_DIR full run
set MODEL_BASE_DIR=\\MODEL2-A\Model2A-Share\Projects\2050_TM151_PPA_CG_01

:: The location of the project (hwy and trn) to be QA-ed
set PROJ_DIR=M:\Application\Model One\RTP2021\ProjectPerformanceAssessment\Projects\1_Crossings3\2050_TM151_PPA_CG_01_1_Crossings3_03

:: The location in which we're running the PRECHECK (shortmodel)
set MODEL_DIR=%CD%

:: Use this for COMMPATH
mkdir COMMPATH
set COMMPATH=%CD%\COMMPATH
start Cluster "%COMMPATH%\CTRAMP" 1-48 Starthide

:: this is where the results will be saved
set LOGSUMS_CHECK_DIR=%PROJ_DIR%\logsum_precheck

:: Path details
set PATH=c:\windows\system32;C:\Python27;C:\Python27\Scripts
set TPP_PATH=C:\Program Files\Citilabs\CubeVoyager;C:\Program Files (x86)\Citilabs\CubeVoyager
set PYTHONPATH=Z:\NetworkWrangler;Z:\NetworkWrangler\_static
set GAWK_PATH=M:\Software\Gawk\bin
SET PATH=%TPP_PATH%;%GAWK_PATH%;%PATH%


:: ------------------------------------------------------------------------------------------------------
::
:: Step 1: bring in the working transit network, highway network and other inputs
::
:: ------------------------------------------------------------------------------------------------------

mkdir logs

:: Stamp the feedback report with the date and time of the model start
echo STARTED LOGSUMS PRECHECK  %DATE% %TIME% >> logs\feedback.rpt 

robocopy /MIR "%PROJ_DIR%\trn"                    trn
robocopy /MIR "%PROJ_DIR%\hwy"                    hwy
robocopy /MIR "%MODEL_BASE_DIR%\INPUT\logsums"    logsums
robocopy /MIR "%MODEL_BASE_DIR%\INPUT\landuse"    landuse


:: Use the same CTRAMP as the BASE
robocopy /MIR "%MODEL_BASE_DIR%\CTRAMP"           CTRAMP

:: updated script that is in master but possibly not in the current run yet
copy /y "\\mainmodel\MainModelShare\travel-model-one-master\model-files\scripts\preprocess\RuntimeConfiguration.py"  "CTRAMP\scripts\preprocess\RuntimeConfiguration.py"


:: Figure out the model year
:: used by logsums.properties
set PROJECT_DIR=%CD%
set PROJECT_DIR2=%PROJECT_DIR:~0,-1%
:: get the base dir only
for %%f in (%PROJECT_DIR2%) do set myfolder=%%~nxf
:: the first four characters are model year
set MODEL_YEAR=%myfolder:~0,4%

:: MODEL YEAR ------------------------- make sure it's numeric --------------------------------
set /a MODEL_YEAR_NUM=%MODEL_YEAR% 2>nul
if %MODEL_YEAR_NUM%==%MODEL_YEAR% (
  echo Numeric model year [%MODEL_YEAR%]
) else (
  echo Couldn't determine numeric model year from project dir [%PROJECT_DIR%]
  echo Guessed [%MODEL_YEAR%]
  exit /b 2
)
:: MODEL YEAR ------------------------- make sure it's in [2000,3000] -------------------------
if %MODEL_YEAR% LSS 2000 (
  echo Model year [%MODEL_YEAR%] is less than 2000
  exit /b 2
)
if %MODEL_YEAR% GTR 3000 (
  echo Model year [%MODEL_YEAR%] is greater than 3000
  exit /b 2
)



:: ------------------------------------------------------------------------------------------------------
::
:: Step 2: Pre-process steps
::
:: ------------------------------------------------------------------------------------------------------
:preprocess

:: Set the prices in the roadway network (convert csv to dbf first)
python "CTRAMP\scripts\preprocess\csvToDbf.py" hwy\tolls.csv hwy\tolls.dbf
IF ERRORLEVEL 1 goto done

::   Input: hwy\freeflow.net
::  Output: hwy\withTolls.net
:: Summary: Sets the prices in the roadway network
::          Based on columns TOLLCLASS, DISTANCE
::          Updates columns: TOLL[EA,AM,MD,PM,EV]_[DA,S2,S3,VSM,SML,MED,LRG]
runtpp "CTRAMP\scripts\preprocess\SetTolls.job"
if ERRORLEVEL 2 goto done

::   Input: hwy\withTolls.net
::  Output: hwy\withHovXferPenalties.net (copied back into withTolls.net)
:: Summary: Set a penalty to dummy links connecting HOV/HOT lanes and general purpose lanes
::          Based on columns FT, A, B, DISTANCE
::          Updates column: HovXPen
runtpp "CTRAMP\scripts\preprocess\SetHovXferPenalties.job"
if ERRORLEVEL 2 goto done

::   Input: hwy\withTolls.net
::  Output: hwy\avgload[EA,AM,MD,PM,EV].net
:: Summary: Creates time-of-day-specific networks
runtpp "CTRAMP\scripts\preprocess\CreateFiveHighwayNetworks.job"
if ERRORLEVEL 2 goto done

:: ------------------------------------------------------------------------------------------------------
::
:: Step 3:  Build non-motorized level-of-service matrices
::
:: ------------------------------------------------------------------------------------------------------

:nonmot

mkdir skims

:: Translate the roadway network into a non-motorized network
runtpp CTRAMP\scripts\skims\CreateNonMotorizedNetwork.job
if ERRORLEVEL 2 goto done

:: Build the skim tables
runtpp CTRAMP\scripts\skims\NonMotorizedSkims.job
if ERRORLEVEL 2 goto done

:: ------------------------------------------------------------------------------------------------------
::
:: Step 4: HwyAssign with trip tables from base
::
:: ------------------------------------------------------------------------------------------------------
:hwyassign

mkdir main
copy "%MODEL_BASE_DIR%\main\trips??.tpp"         main\
mkdir nonres
copy "%MODEL_BASE_DIR%\nonres\tripsIx??.tpp"     nonres\
copy "%MODEL_BASE_DIR%\nonres\tripsTrk??.tpp"    nonres\
copy "%MODEL_BASE_DIR%\nonres\tripsAirPax??.tpp" nonres\

:: Assign the demand matrices to the highway network
runtpp CTRAMP\scripts\assign\HwyAssign.job
if ERRORLEVEL 2 goto done

echo FINISHED HIGHWAY ASGN  %DATE% %TIME% >> logs\feedback.rpt 

:: ------------------------------------------------------------------------------------------------------
::
:: Step 5: HwyAssign with trip tables from base
::
:: ------------------------------------------------------------------------------------------------------
:trnAssignSkim

set ITER=0
set MAXITERATIONS=3
:: --------TrnAssignment Setup -- Fast Configuration
:: NOTE the blank ones should have a space
set TRNCONFIG=FAST
set COMPLEXMODES_DWELL= 
set COMPLEXMODES_ACCESS= 

:: Step 4.5: Build initial transit files
python CTRAMP\scripts\skims\transitDwellAccess.py NORMAL NoExtraDelay Simple complexDwell %COMPLEXMODES_DWELL% complexAccess %COMPLEXMODES_ACCESS%
if ERRORLEVEL 2 goto done

:: copy a local version for easier restarting
copy CTRAMP\scripts\skims\trnAssign.bat trnAssign_iter%ITER%.bat
call trnAssign_iter%ITER%.bat
if ERRORLEVEL 2 goto done

echo FINISHED TRN ASSIGN SKIMMING  %DATE% %TIME% >> logs\feedback.rpt 

:: ------------------------------------------------------------------------------------------------------
::
:: Step 5:  Build highway skims
::
:: ------------------------------------------------------------------------------------------------------

:hwyskims

:: Create the automobile level-of-service matrices
runtpp CTRAMP\scripts\skims\HwySkims.job
if ERRORLEVEL 2 goto done

:: Create accessibility measures for use by ...
runtpp CTRAMP\scripts\skims\Accessibility.job
if ERRORLEVEL 2 goto done

:: Add time step to the feedback report file
echo FINISHED HIGHWAY SKIMMING  %DATE% %TIME% >> logs\feedback.rpt 

:: ------------------------------------------------------------------------------------------------------
::
:: Step 6:  Run logsums
::
:: batch script adapted from RunLogsums.bat
::
:: ------------------------------------------------------------------------------------------------------

:logsums

:: ------------------------------------------------------------------------------------------------------
:: Step 6a: Set the path
:: ------------------------------------------------------------------------------------------------------
:: including the location of the 64-bit java development kit and R (but other paths could be useful)
:: set JAVA_PATH=C:\Program Files\Java\jdk1.8.0_181
call CTRAMP\runtime\SetPath.bat
:: just kidding
set COMMPATH=%CD%\COMMPATH

::  Set the IP address of the host machine which sends tasks to the client machines 
if %computername%==MODEL2-A set HOST_IP_ADDRESS=192.168.1.206
if %computername%==MODEL2-B set HOST_IP_ADDRESS=192.168.1.207
if %computername%==MODEL2-C set HOST_IP_ADDRESS=192.168.1.208
if %computername%==MODEL2-D set HOST_IP_ADDRESS=192.168.1.209
if %computername%==PORMDLPPW01 set HOST_IP_ADDRESS=172.24.0.101
if %computername%==PORMDLPPW02 set HOST_IP_ADDRESS=172.24.0.102
if %computername%==MAINMODEL set HOST_IP_ADDRESS=192.168.1.200
if %computername%==SATMODEL set HOST_IP_ADDRESS=192.168.1.201

:: copy in params.properties
:: used by runtimeconfiguration.py and then by logsums java processes
mkdir INPUT
copy "%MODEL_BASE_DIR%\INPUT\params.properties"  INPUT\params.properties

:: copy in shadow price from base - double check that this step is necessary
:: used by logsums java processes
copy "%MODEL_BASE_DIR%\main\ShadowPricing_7.csv"     main\ShadowPricing_7.csv

:: create logsums.properties
python CTRAMP\scripts\preprocess\RuntimeConfiguration.py --logsums
if ERRORLEVEL 1 goto done

:: ------------------------------------------------------------------------------------------------------
:: Step 6b:  Execute Java
:: ------------------------------------------------------------------------------------------------------

if not exist logsums\indivTripData_%ITER%.csv (

  echo STARTED LOGSUMS RUN  %DATE% %TIME% >> logs\feedback.rpt

  rem run matrix manager, household manager and jppf driver
  cd CTRAMP\runtime
  call javaOnly_runMain.cmd 

  rem run jppf node
  cd CTRAMP\runtime
  call javaOnly_runNode0.cmd

  rem Execute the accessibility calculations
  java -showversion -Xmx6000m -cp %CLASSPATH% -Dlog4j.configuration=log4j.xml -Djava.library.path=%RUNTIME% -Djppf.config=jppf-clientDistributed.properties -Djava.library.path=%RUNTIME% com.pb.mtc.ctramp.MTCCreateLogsums logsums

  rem shut down java
  C:\Windows\SysWOW64\taskkill /f /im "java.exe"
)


:: ------------------------------------------------------------------------------------------------------
:: Step 6c: Reformat logsums
:: ------------------------------------------------------------------------------------------------------
:logsum_reformat

:: pretend it is iter3
:: Set the iteration parameters
set ITER=3
set SAMPLESHARE=1.00
set TARGET_DIR=%CD%

if %computername%==SATMODEL set R_LIB=C:/Users/mtcpb.MTC/Documents/R/win-library/3.5

if not exist logsums\mandatoryAccessibilities.csv (
  call "%R_HOME%\bin\x64\Rscript.exe" --vanilla ".\CTRAMP\scripts\core_summaries\logsumJoiner.R"
  IF %ERRORLEVEL% GTR 0 goto done
)

:: Add time step to the feedback report file
echo FINISHED RUNNING LOGSUMS %ITER%  %DATE% %TIME% >> logs\feedback.rpt 


:: ------------------------------------------------------------------------------------------------------
:: Step 6d:  Accessibilities Markets
:: ------------------------------------------------------------------------------------------------------
:AccessibilityMarkets

mkdir popsyn
copy "%MODEL_BASE_DIR%\popsyn\hhFile.csv"         popsyn\hhFile.csv
copy "%MODEL_BASE_DIR%\popsyn\personFile.csv"     popsyn\personFile.csv

:: copy household and population files from base
:: used by AccessibilityMarkets.R
copy "%MODEL_BASE_DIR%\main\householdData_3.csv"  main\householdData_3.csv
copy "%MODEL_BASE_DIR%\main\personData_3.csv"     main\personData_3.csv

mkdir core_summaries
if not exist core_summaries\AccessibilityMarkets.csv (
  call "%R_HOME%\bin\x64\Rscript.exe" --vanilla ".\CTRAMP\scripts\core_summaries\AccessibilityMarkets.R"
  IF %ERRORLEVEL% GTR 0 goto done
)

:: Add time step to the feedback report file
echo FINISHED ACCESSIBILITY MARKETS %ITER%  %DATE% %TIME% >> logs\feedback.rpt 


:: Complete
goto victory

:done
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem Failure
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
goto end

:victory
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem Victory
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
rem ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

start Cluster "%COMMPATH%\CTRAMP" 1-48 Close

:end
:: Last Step:  Stamp the time of completion to the feedback report file
echo FINISHED LOGSUMS PRECHECK  %DATE% %TIME% >> logs\feedback.rpt 
