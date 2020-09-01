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
export RESERVOIR_DB_INSTANCE="reservoir-db"
export RESERVOIR_DB_NAME="reservoir"
export RESERVOIR_SA="reservoir-sa"
export RESERVOIR_DB_SECRETS="reservoir-db"

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

  # copy the container config and secrets to the ./reservoir subdirectory to be packaged with the source
  if [ -d ./reservoir/container ]
  then
    echo "Cleaning ./reservoir/container"
    rm -rf ./reservoir/container
  fi
  
  cp -R ./container ./reservoir
  

  LOG_INFO "CLOUDBUILD_LOGS_BUCKET: ${CLOUDBUILD_LOGS_BUCKET}"

  set -x
  gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/reservoir" "--substitutions=SHORT_SHA=${RESERVOIR_SHORT_SHA}"  --config ${reservoir_script_dir}/cloudbuild-reservoir.yaml ./reservoir
  set +x

  if [ $? -ne 0 ]
  then
    LOG_INFO "Failed to submit gcloud build"
    return 1
  fi

  if ! gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/reservoir:${RESERVOIR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/reservoir:latest"; then
    LOG_INFO "Failed to label reservoir build ${RESERVOIR_SHORT_SHA} as latest."
    return 1
  fi
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


function reservoir_get_db_ip {
  RESERVOIR_DB_IP=$(gcloud beta sql instances describe "${RESERVOIR_DB_INSTANCE}" --format="value(ipAddresses.ipAddress)")
  
  if [ -z "${RESERVOIR_DB_IP}" ]
  then
    LOG_INFO "Failed to retrieve reservoir db host ip."
    return 1
  fi
  
  LOG_INFO "RESERVOIR_DB_IP: ${RESERVOIR_DB_IP}"
}

function reservoir_create_cloudsql_service_account {
  local TMP_DIR="/tmp/reservoir"
  RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT="reservoir-cloudsql-sa"
  RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED="${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  RESERVOIR_CLOUDSQL_KEY_SECRET="reservoir-sa-key"

  if [ -z "${GCP_PROJECT_ID}" ]
  then
    LOG_INFO "Please specify GCP_PROJECTID env variable."
  fi
    
  if [ ! -d "${TMP_DIR}" ]
  then
    LOG_INFO "Creating ${TMP_DIR}"
    mkdir "${TMP_DIR}"
  fi

  if ! gcloud iam service-accounts describe ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED}
  then
    LOG_INFO "Creating service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED}"
    if ! gcloud iam service-accounts create "${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}" \
      --description "Service Account for Reservoir CloudSQL Proxy."; then
      LOG_INFO "Failed to create service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}"
      return 1
    fi
  else
    LOG_INFO "${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED} already exists."
  fi

  gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
    --member=serviceAccount:${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED} \
    --role=roles/cloudsql.editor

  if [ $? -ne 0 ]
  then
    LOG_INFO "Failed to bind ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT} to cloudsql.admin role."
    return 1
  fi
  
  LOG_INFO "Creating new access key for reservoir service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}"
  
  if ! gcloud iam service-accounts keys create "${TMP_DIR}/key.json" \
    --iam-account ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}@${GCP_PROJECT_ID}.iam.gserviceaccount.com;
  then
    LOG_INFO "Failed to create ${RESERVOIR_CLOUD_SERVICE_ACCOUNT_NAME} service account key."
    return 1
  else
    LOG_INFO "Key: $(cat ${TMP_DIR}/key.json)"
  fi

  if kubectl get secrets "${RESERVOIR_CLOUDSQL_KEY_SECRET}"
  then
    LOG_INFO "Deleteing old ${RESERVOIR_CLOUDSQL_KEY_SECRET} key."
    kubectl delete secrets "${RESERVOIR_CLOUDSQL_KEY_SECRET}"
  fi
  
  kubectl create secret generic "${RESERVOIR_CLOUDSQL_KEY_SECRET}" \
    --from-file=service_account.json="${TMP_DIR}/key.json"  
}

function reservoir_create_db_instance {

  gcloud sql databases list --instance="${RESERVOIR_DB_INSTANCE}"

  if [ $? -ne 0 ]
  then
    LOG_INFO "Creating new reservoir database instance: ${RESERVOIR_DB_INSTANCE}"
      gcloud beta sql instances create "${RESERVOIR_DB_INSTANCE}" --cpu=2 --memory=7680MiB \
    --database-version=POSTGRES_12 --zone=${GCP_ZONE} --storage-type=SSD \
    --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip
  fi

  if [ $? -ne 0 ]
  then
    LOG_INFO "Failed to create Reservoir sql database."
    return 1
  fi
  
  # reservoir_get_db_ip

  add_secret ${secrets_env_file} RESERVOIR_DB_USER "reservoir"
  add_secret ${secrets_env_file} RESERVOIR_DB_PASSWORD "$(generate_password)"
  add_secret ${secrets_env_file} RESERVOIR_DB_HOST "127.0.0.1" # Use proxy side car.
  add_secret ${secrets_env_file} RESERVOIR_DB_PORT "5432"
  add_secret ${secrets_env_file} RESERVOIR_DB_NAME "${RESERVOIR_DB_NAME}"
  add_secret ${secrets_env_file} RESERVOIR_DB_INSTANCE "${RESERVOIR_DB_INSTANCE}"
  add_secret ${secrets_env_file} RESERVOIR_DB_INSTANCE_CONNECTION_NAME "${GCP_PROJECT_ID}:${GCP_REGION}:${RESERVOIR_DB_INSTANCE}=tcp:${RESERVOIR_DB_PORT}"
  gcloud beta sql databases create "${RESERVOIR_DB_NAME}" --instance="${RESERVOIR_DB_INSTANCE}"
  
  gcloud beta sql users create "${RESERVOIR_DB_USER}" --instance="${RESERVOIR_DB_INSTANCE}" "--password=${RESERVOIR_DB_PASSWORD}"
}

function reservoir_run_init_db_job {
  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  set -x
  ${script_dir}/kapply k8s/reservoir-db-migration-job.yaml.in
  set +x

  # Give the migration time to complete
  LOG_INFO "Waiting one minute for migrations to complete."
  sleep 60s

  kubectl logs -l name=reservoir-db-migration

  LOG_INFO "To delete db init job run: kubectl delete jobs reservoir-db-migration"
}
