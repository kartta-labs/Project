#! /bin/bash
#
# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This file contains bash functions used by various scripts in this direcotry.
# Don't run this file directly -- it gets loaded by other files.

reservoir_script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

. ${reservoir_script_dir}/functions.sh

# Name of cloud-sql instance.
RESERVOIR_DB_INSTANCE="reservoir-sql"
RESERVOIR_DB_NAME="reservoir"

LOG_INFO() {
    echo "[kbootstrap reservoir INFO $(date +"%Y-%m-%d %T %Z")] $1"
}

if [ -z "${secrets_env_file}" ] 
then
  LOG_INFO "secrets_env_file unset, setting to ./container/secrets/secrets.env"
  secrets_env_file="./container/secrets/secrets.env"

  if [ \! -f "${secrets_env_file}" ] ; then
    echo "Before running kbootstrap.sh, you should run ./makesecrets to generate a secrets file,"
    echo "and edit it to set the required values for a k8s deployment."
    exit -1
  fi
fi

function clone_reservoir {
  if [ ! -d "./reservoir" ]
  then
    LOG_INFO "Cloning Reservoir repository."
    git clone ${RESERVOIR_REPO} reservoir
  else
    LOG_INFO "Pulling latest Reservoir repository."
    git -C ./reservoir pull origin master
  fi
}

function reservoir_cloud_build {
  export RESERVOIR_SHORT_SHA=`(cd reservoir ; git rev-parse --short HEAD)`
  
  gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/reservoir" "--substitutions=SHORT_SHA=${RESERVOIR_SHORT_SHA}" --config k8s/cloudbuild-reservoir.yaml ./reservoir

  if [ $? -ne 0 ]
  then
    LOG_INFO "Failed to submit gcloud build"
    return 1
  fi
  
  gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/reservoir:${RESERVOIR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/reservoir:latest"
}

function get_reservoir_nfs_server_ip {
  RESERVOIR_NFS_SERVER=$(gcloud filestore instances describe reservoir-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])")
  LOG_INFO "RESERVOIR_NFS_SERVER IP: ${RESERVOIR_NFS_SERVER}"
  LOG_INFO "Adding RESERVOIR_NFS_SERVER to secrets file."
  
  set -x
  add_secret ${secrets_env_file} RESERVOIR_NFS_SERVER ${RESERVOIR_NFS_SERVER}
  set +x  
}

function reservoir_create_nas {
  gcloud filestore instances create reservoir-fs --project=${GCP_PROJECT_ID} --zone=${GCP_ZONE} --tier=STANDARD --file-share=name=reservoirfs,capacity=1TB --network=name=default

  get_reservoir_nfs_server_ip
}



function reservoir_create_pvc {
  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

  if [ -z "${RESERVOIR_NFS_SERVER}" ]
  then
    LOG_INFO "RESERVOIR_NFS_SERVER not set."
    return 1
  fi
  
  # create PersistentVolume (nfs mount) called reservoir-fileserver
  ${script_dir}/kapply k8s/reservoir-filestore-storage.yaml.in
}


function reservoir_get_db_host {
  RESERVOIR_DB_HOST=$(gcloud beta sql instances describe "${RESERVOIR_DB_INSTANCE}" --format="value(ipAddresses.ipAddress)")
  
  if [ -z "${RESERVOIR_DB_HOST}" ]
  then
    LOG_INFO "Failed to retrieve reservoir db host ip."
    return 1
  fi
  
  LOG_INFO "RESERVOIR_DB_HOST: ${RESERVOIR_DB_HOST}"
}

function reservoir_activate_hstore_db {
  if [ -z RESERVOIR_DB_USER ]
  then
    LOG_INFO "RESERVOIR_DB_USER is not set, please initialize the database first."
    return 1
  fi

  gcloud sql connect "${RESERVOIR_DB_INSTANCE}" --user="${RESERVOIR_DB_USER}" --password="${RESERVOIR_DB_PASSWORD}"
}

function reservoir_create_db {

  gcloud sql databases list --instance="${RESERVOIR_DB_INSTANCE}"

  if [ $? -ne 0 ]
  then
    LOG_INFO "Creating new reservoir database instance: ${RESERVOIR_DB_INSTANCE}"
      gcloud beta sql instances create "${RESERVOIR_DB_INSTANCE}" --cpu=1 --memory=7680MiB --cpu=2 \
    --database-version=POSTGRES_12 --zone=${GCP_ZONE} --storage-type=SSD \
    --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip
  fi

  if [ $? -ne 0 ]
  then
    LOG_INFO "Failed to create Reservoir sql database."
    return 1
  fi
  
  reservoir_get_db_host

  add_secret ${secrets_env_file} RESERVOIR_DB_INSTANCE "${RESERVOIR_DB_INSTANCE}"
  add_secret ${secrets_env_file} RESERVOIR_DB_NAME "${RESERVOIR_DB_NAME}"
  add_secret ${secrets_env_file} RESERVOIR_DB_HOST "${RESERVOIR_DB_HOST}"
  add_secret ${secrets_env_file} RESERVOIR_DB_USER "reservoir"
  add_secret ${secrets_env_file} RESERVOIR_DB_PASSWORD "$(generate_password)"

  gcloud beta sql databases create "${RESERVOIR_DB_NAME}" --instance="${RESERVOIR_DB_INSTANCE}"
  
  gcloud beta sql users create "${RESERVOIR_DB_USER}" --instance="${RESERVOIR_DB_INSTANCE}" "--password=${RESERVOIR_DB_PASSWORD}" 
}
