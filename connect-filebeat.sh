#!/bin/bash

#trapping Control + C
#these statements must be the first statements in the script to trap the CTRL C event

trap ctrl_c INT

function ctrl_c() {
  log "INFO" "INFO: Aborting the script."
  exit 1
}

##########  Variable Declarations - Start  ##########

#filebeat service name
FILEBEAT_SERVICE=filebeat
#directory location for filebeat logs
FILEBEAT_ETCDIR_CONF=/etc/filebeat
#name and location of logsight filebeat file
FILEBEAT_CONFFILE=$FILEBEAT_ETCDIR_CONF/filebeat.yml
#name and location of logsight filebeat backup file
FILEBEAT_CONFFILE_BACKUP=$FILEBEAT_CONFFILE.logsight.bk
#variabel that will contain the config
FILEBEAT_CONFIG=
#filebeat module that should be enabled
FILEBEAT_MODULE=


#minimum version of filebeat to enable logging to logsight
MIN_FILEBEAT_VERSION=6.0.0
#this variable will hold the users filebeat version if its present
FILEBEAT_VERSION=
#if not filebeat is present, the following version should be installed
FILEBEAT_VERSION_TO_INSTALL=7.14.1

#this variable will hold the host name
HOST_NAME=
#this variable will hold the name of the linux distribution
LINUX_DIST=
# this variable will hold the package manager of the system (dpkg or rpm)
PKG_MGR=
#package type will hold the format of linux packages (deb or rpm are supported)
LINUX_PACKAGE_FILE_EXT=
#this variable will hold if the check env function for linux is invoked
LINUX_ENV_VALIDATED="false"

#host name for logsight.ai
#LOGS_HOST=logsight.ai
LOGS_HOST=localhost
LOGS_URL=https://$LOGS_HOST
#variables used in filebeat.yml file
LOGSIGHT_LOGSTASH_PORT=5044

######Inputs provided by user######
#this variable will hold the logsight authentication token provided by user.
#this is a mandatory input
LOGSIGHT_AUTH_TOKEN=
#this variable will contain the app name. it connects the collected logs to an logsight.ai app definition
APP_NAME=

##########  Variable Declarations - End  ##########

log() {
  echo $2
}

#checks if user has root privileges
checkIfUserHasRootPrivileges() {
  #This script needs to be run as root
  if [[ $EUID -ne 0 ]]; then
    log "ERROR" "ERROR: This script must be run as root."
    exit 1
  fi
}

getOs() {
  # Determine OS platform
  UNAME=$(uname | tr "[:upper:]" "[:lower:]")
  # If Linux, try to determine specific distribution
  if [ "$UNAME" == "linux" ]; then
    # If available, use LSB to identify distribution
    if [ -f /etc/lsb-release -o -d /etc/lsb-release.d ]; then
      LINUX_DIST=$(lsb_release -i | cut -d: -f2 | sed s/'^\t'//)
      # If system-release is available, then try to identify the name
    elif [ -f /etc/system-release ]; then
      LINUX_DIST=$(cat /etc/system-release | cut -f 1 -d " ")
      # Otherwise, use release info file
    else
      LINUX_DIST=$(ls -d /etc/[A-Za-z]*[_-][rv]e[lr]* | grep -v "lsb" | cut -d'/' -f3 | cut -d'-' -f1 | cut -d'_' -f1)
    fi
  fi

  # For everything else (or if above failed), just use generic identifier
  if [ "$LINUX_DIST" == "" ]; then
    LINUX_DIST=$(uname)
  fi
}

checkIfSupportedOS() {
  getOs

  LINUX_DIST_IN_LOWER_CASE=$(echo $LINUX_DIST | tr "[:upper:]" "[:lower:]")

  case "$LINUX_DIST_IN_LOWER_CASE" in
  *"ubuntu"*)
    log "INFO" "INFO: Operating system is Ubuntu."
    ;;
  *"red"*)
    log "INFO" "INFO: Operating system is Red Hat."
    ;;
  *"centos"*)
    log "INFO" "INFO: Operating system is CentOS."
    ;;
  *"debian"*)
    elog "INFO"cho "INFO: Operating system is Debian."
    ;;
  *"amazon"*)
    log "INFO" "INFO: Operating system is Amazon AMI."
    ;;
  *"darwin"*)
    #if the OS is mac then exit
    log "ERROR" "ERROR: This script is for Linux systems, and Darwin or Mac OSX are not currently supported. You can find alternative options here: https://www.logsight.ai/"
    exit 1
    ;;
  *)
    log "WARN" "WARN: The linux distribution '$LINUX_DIST' has not been previously tested with this script."
    while true; do
      read -p "Would you like to continue anyway? (yes/no)" promt
      case $promt in
      [Yy]*)
        break
        ;;
      [Nn]*)
        exit 1
        ;;
      *) echo "Please answer yes or no." ;;
      esac
    done
    ;;
  esac
}

#check if required dependencies to run the script are not installed, If yes then ask user to install them manually and run the script again
checkIfRequiredDependenciesAreNotInstalled() {
  if ! [ -x "$(command -v curl)" ]; then
    log "ERROR" "ERROR: 'curl' executable could not be found on your machine, since it "\
    "is a dependent package to run this script, please install it manually and then run the script again."
    exit 1
  fi
}

#check if the required package-manager is present on the machine
checkIfPackageManagerIsPresent() {
  if [ -x "$(command -v dpkg)" ]; then
    log "INFO" "INFO: Package manager dpkg is used."
    PKG_MGR="dpkg"
    LINUX_PACKAGE_FILE_EXT="deb"
  elif [ -x "$(command -v rpm)" ]; then
    log "INFO" "INFO: Package manager rpm is used."
    PKG_MGR="rpm"
    LINUX_PACKAGE_FILE_EXT="rpm"
  else
    log "ERROR" "ERROR: No package manager found to install filebeat. Either dpkg or rpm is required."
  fi
}

#sets linux variables which will be used across various functions
setLinuxVariables() {
  #set host name
  HOST_NAME=$(hostname)
  #set app name to hostname if its not defined
  if [ -z "$APP_NAME" ]; then
    APP_NAME=$HOST_NAME
  fi
}

#compare two semantic versions
verlte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

#check if filebeat is present in machine. if yes, check its version
checkFilebeat() {
  if [ -x "$(command -v filebeat)" ]; then
    a=( $(sudo filebeat version) )
    FILEBEAT_VERSION=${a[2]}
    log "INFO" "INFO: filebeat version $FILEBEAT_VERSION is already installed on the system."
    verlte MIN_FILEBEAT_VERSION FILEBEAT_VERSION && \
      log "ERROR" "ERROR: at least version $MIN_FILEBEAT_VERSION or higher of filebeat is required." && \
      exit 1
  fi
}

#check if the Linux environment is compatible with Logsight filebeat.
#Also set few variables after the check.
checkLinuxLogsightCompatibility() {
  #check if the user has root permission to run this script
  checkIfUserHasRootPrivileges

  #check if the OS is supported by the script and set relevant variables
  checkIfSupportedOS

  #check if required dependencies to run the script are not installed. If yes, ask user to install them manually and run the script again.
  checkIfRequiredDependenciesAreNotInstalled

  #check if package-manager is present on the machine
  checkIfPackageManagerIsPresent

  #set the basic variables needed by this script
  setLinuxVariables

  #check if filebeat is present in machine. if yes, check its version
  checkFilebeat

  LINUX_ENV_VALIDATED="true"
}

#install filebeat on this machine
installFilebeat() {
  # install filebeat if its not yet installed on the system
  if [ -z "$FILEBEAT_VERSION" ]; then
    FILEBEAT_PACKAGE=filebeat-$FILEBEAT_VERSION_TO_INSTALL-amd64.$LINUX_PACKAGE_FILE_EXT
    FILEBEAT_ENDPOINT=https://artifacts.elastic.co/downloads/beats/filebeat/$FILEBEAT_PACKAGE
    log "INFO" "INFO: Trying to download filebeat package from $FILEBEAT_ENDPOINT"
    if ! curl -L -O $FILEBEAT_ENDPOINT; then
      log "ERROR" "ERROR: filebeat package download failed from $FILEBEAT_PACKAGE"
      exit 1
    fi
    log "INFO" "INFO: Trying to install filebeat package $FILEBEAT_PACKAGE with $PKG_MGR"
    if ! $PKG_MGR -i $FILEBEAT_PACKAGE; then
      log "ERROR" "ERROR: failed to install filebeat package $FILEBEAT_PACKAGE with $PKG_MGR"
      exit 1
    fi
    log "INFO" "INFO: Installation of $FILEBEAT_PACKAGE successfull"
  fi
}


confString() {
  FILEBEAT_CONFIG="
# ============================== Filebeat modules ==============================

filebeat.config.modules:
  # Glob pattern for configuration loading
  path: \${path.config}/modules.d/*.yml

# ======================= Elasticsearch template setting =======================

#setup.template.settings:
#  index.number_of_shards: 1
  #index.codec: best_compression
  #_source.enabled: false


# ================================== General ===================================

fields:
  privateKey: $LOGSIGHT_AUTH_TOKEN
  appName: $APP_NAME

# ================================== Outputs ===================================

# Configure what output to use when sending the data collected by the beat.

# ------------------------------ Logstash Output -------------------------------
output.logstash:
  hosts: [\"$LOGS_HOST:$LOGSIGHT_LOGSTASH_PORT\"]

# ================================= Processors =================================
processors:
  - add_host_metadata:
      when.not.contains.tags: forwarded
  - add_cloud_metadata: ~
  - add_docker_metadata: ~
  - add_kubernetes_metadata: ~
"
}

writeFilebeatConfig() {
  confString
  if [ -f "$FILEBEAT_CONFFILE" ]; then
    log "INFO" "INFO: filebeats file $FILEBEAT_CONFFILE already exist."
    while true; do
      read -p "Do you wish to override $FILEBEAT_CONFFILE? A backup of the current conf will be created. (yes/no)" yn
      case $yn in
      [Yy]*)
        log "INFO" "INFO: Going to back up the conf file: $FILEBEAT_CONFFILE to $FILEBEAT_CONFFILE_BACKUP"
        mv -f $FILEBEAT_CONFFILE $FILEBEAT_CONFFILE_BACKUP
        WRITE_SCRIPT_CONTENTS="true"
        break
        ;;
      [Nn]*)
        log "INFO" "INFO: Abborting installation..."
        exit 1
        ;;
      *) echo "Please answer yes or no." ;;
      esac
    done
  else
    WRITE_SCRIPT_CONTENTS="true"
  fi

  if [ "$WRITE_SCRIPT_CONTENTS" == "true" ]; then
    log "INFO" "INFO: writing filebeat config into $FILEBEAT_CONFFILE."
    cat <<EOIPFW >> $FILEBEAT_CONFFILE
$FILEBEAT_CONFIG
EOIPFW
  fi
}

#restart filebeat
restartFilebeat() {
  log "INFO" "INFO: Restarting the $FILEBEAT_SERVICE service."
  service $FILEBEAT_SERVICE restart
  if [ $? -ne 0 ]; then
    log "WARNING" "WARNING: $FILEBEAT_SERVICE did not restart gracefully. Please restart $FILEBEAT_SERVICE manually."
  fi
}

#check if authentication token is passed and then write config
setupFilebeatConfig() {
  writeFilebeatConfig
}

#check if filebeat is configured as service
checkIfFilebeatConfiguredAsService() {
  if [ -f /etc/init.d/$FILEBEAT_SERVICE ]; then
    log "INFO" "INFO: $FILEBEAT_SERVICE is present as service."
  elif [ -f /usr/lib/systemd/system/$FILEBEAT_SERVICE.service ]; then
    log "INFO" "INFO: $FILEBEAT_SERVICE is present as service."
  else
    log "ERROR" "ERROR: $FILEBEAT_SERVICE is not present as service."
    exit 1
  fi
}

#enable the filebeat module to collect log data
enableFilebeatModule() {
  $FILEBEAT_SERVICE modules "enable" $FILEBEAT_MODULE
  if [ $? -ne 0 ]; then
    log "WARNING" "WARNING: failed to enable filebeat module $FILEBEAT_MODULE"
  fi
}

# executing the script for logsight to install and configure filebeat.
installFilebeatForLogsight() {
  #log message indicating starting of Logsight configuration
  log "INFO" "INFO: Initiating Configure Logsight Filebeats for Linux."

  if [ "$LINUX_ENV_VALIDATED" = "false" ]; then
    checkLinuxLogsightCompatibility
  fi

  #check if filebeat is present in machine. install if not
  installFilebeat
  #if all the above check passes, setup the filebeat configuration
  setupFilebeatConfig
  #enable filebeat module
  enableFilebeatModule
  #restart the filebeat service
  restartFilebeat

  if [ "$LINUX_DO_VERIFICATION" = "true" ]; then
    #check if the logs are going to logsight fro linux system now
    checkIfLogsMadeToLogsight
  fi

  if [ "$IS_INVOKED" = "" ]; then
    log "SUCCESS" "SUCCESS: filebeat successfully configured to send logs to logsight.ai"
  fi
}

#display usage syntax
usage() {
  cat <<EOF
usage: logsight-install-linux [-a app name] [-m filebeats module to enable] -t logsight auth token
usage: logsight-install-linux [-h for help]
EOF
}

##########  Get Inputs from User  ##########
while [ "$1" != "" ]; do
  case $1 in
  -t | --token)
    shift
    LOGSIGHT_AUTH_TOKEN=$1
    log "INFO" "INFO: auth token $LOGSIGHT_AUTH_TOKEN"
    ;;
  -a | --app)
    shift
    APP_NAME=$1
    log "INFO" "INFO: app name $APP_NAME"
    ;;
  -m | --module)
    shift
    FILEBEAT_MODULE=$1
    log "INFO" "INFO: filebeat module to enable $FILEBEAT_MODULE"
    ;;
  -h | --help)
    usage
    exit
    ;;
  *)
    usage
    exit
    ;;
  esac
  shift
done

if [ "$LOGSIGHT_AUTH_TOKEN" != "" ]; then
  installFilebeatForLogsight
else
  usage
fi
