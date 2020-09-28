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

function LOG {
  echo "[reservoir_functions ${LEVEL} ${LINENO} $(date +"%Y-%m-%d %T %Z")] $@"
}

function LOG_INFO {
  LEVEL="INFO" LOG $@
}

function LOG_ERROR {
  LEVEL="ERROR" LOG $@
}

function generate_random_suffix {
  # Generates a random 16-character password that can be used as a bucket name suffix
  local LENGTH="${1:-15}"
  echo "b`(date ; dd if=/dev/urandom count=2 bs=1024) 2>/dev/null | md5sum | head -c ${LENGTH}`"
}

function create_waybak_test_project {
  export WYBK_ORG_ID=344127236084
  export WYBK_BILLING_ID="01930B-854143-2F2F86"
  export GCP_PROJECT_SUFFIX="$(generate_random_suffix 8)"
  export GCP_PROJECT_ID="waybak-test-${GCP_PROJECT_SUFFIX}"
  
  LOG_INFO "Creating gcloud project with GCP_PROJECT_ID: ${GCP_PROJECT_ID}"
  gcloud projects create "${GCP_PROJECT_ID}" --organization="${WYBK_ORG_ID}"

  if [ $? -ne 0 ]
  then
    echo "Failed to create project ${GPC_PROJECT_ID}"
    return 1
  fi

  if [ -z "${SECRETS_FILE}" ] 
  then
    LOG "secrets_env_file unset, setting to ./container/secrets/secrets.env"
    export SECRETS_FILE="./container/secrets/secrets.env"
    export secrets_env_file="${SECRETS_FILE}"

    if [ \! -f "${SECRETS_FILE}" ] ; then
      echo "Before running kbootstrap.sh, you should run ./makesecrets to generate a secrets file,"
      echo "and edit it to set the required values for a k8s deployment."
      exit -1
    fi
  fi

  LOG_INFO "Re-writing GCP_PROJECT_ID in secrets file to ${GCP_PROJECT_ID}"

  # Change the secrets file to match the test/current GCP_PROJECT_ID
  sed -i "/GCP_PROJECT_ID/ c export GCP_PROJECT_ID=${GCP_PROJECT_ID}" "${SECRETS_FILE}"

  LOG_INFO "$(cat ${SECRETS_FILE} | grep GCP_PROJECT_ID)"
  
  gcloud config set project ${GCP_PROJECT_ID}

  if [ -z "${GCP_REGION}" ] ; then
    LOG_INFO "SETTING GCP_REGION TO us-east4"
    export GCP_REGION="us-east4"
  fi

  if [ -z "${GCP_ZONE}" ] ; then
    LOG_INFO "Setting GCP_ZONE to us-east4-a"
    export GCP_ZONE="us-east4-a"
  fi
  
  gcloud config set compute/zone ${GCP_ZONE}
  
  # Need billing activated to enable apis
  LOG_INFO "Enable gcloud billing"
  gcloud beta billing projects link "${GCP_PROJECT_ID}" --billing-account "${WYBK_BILLING_ID}"
}

function clone_reservoir {
  if [ ! -d "./reservoir" ]
  then
    LOG "Cloning Reservoir repository."
    git clone ${RESERVOIR_REPO} reservoir
  else
    LOG "Pulling latest Reservoir repository."
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
  
  if [ -z $CLOUDBUILD_LOGS_BUCKET ]; then
    CLOUDBUILD_LOGS_BUCKET="gs://cloudbuild-logs-$(generate_bucket_suffix)"
    LOG "Generating new cloud build logs bucket: ${CLOUDBUILD_LOGS_BUCKET}"
    if ! gsutil mb "${CLOUDBUILD_LOGS_BUCKET}"; then
       LOG_ERROR "Failed to create logs storage bucket."
       return 1
    fi    
  fi
       
  LOG "CLOUDBUILD_LOGS_BUCKET: ${CLOUDBUILD_LOGS_BUCKET}"

  set -x
  gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/reservoir" "--substitutions=SHORT_SHA=${RESERVOIR_SHORT_SHA}"  --config ${reservoir_script_dir}/cloudbuild-reservoir.yaml ./reservoir
  set +x

  if [ $? -ne 0 ]
  then
    LOG "Failed to submit gcloud build"
    return 1
  fi

  if ! gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/reservoir:${RESERVOIR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/reservoir:latest"; then
    LOG "Failed to label reservoir build ${RESERVOIR_SHORT_SHA} as latest."
    return 1
  fi
}

function get_reservoir_nfs_server_ip {
  RESERVOIR_NFS_SERVER=$(gcloud filestore instances describe reservoir-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])")
  LOG "RESERVOIR_NFS_SERVER IP: ${RESERVOIR_NFS_SERVER}"
  LOG "Adding RESERVOIR_NFS_SERVER to secrets file."
  
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
    LOG "RESERVOIR_NFS_SERVER not set."
    # The NAS creation may have been done in a separate process and the IP variable not available in
    # the current environment. Attempt to fetch it from the cluster.
    RESERVOIR_NFS_SERVER=$(gcloud filestore instances describe reservoir-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])")
    if [ $? -ne 0 ]; then
       LOG_ERROR "Failed to fetch RESERVOIR_NFS_SERVER IP."
       return 1
    else
      LOG_INFO "Found RESERVOIR_NFS_SERVER: ${RESERVOIR_NFS_SERVER}"
    fi
  fi
  
  # create PersistentVolume (nfs mount) called reservoir-fileserver
  ${script_dir}/kapply k8s/reservoir-filestore-storage.yaml.in
}


function reservoir_get_db_ip {
  RESERVOIR_DB_IP=$(gcloud beta sql instances describe "${RESERVOIR_DB_INSTANCE}" --format="value(ipAddresses.ipAddress)")
  
  if [ -z "${RESERVOIR_DB_IP}" ]
  then
    LOG "Failed to retrieve reservoir db host ip."
    return 1
  fi
  
  LOG "RESERVOIR_DB_IP: ${RESERVOIR_DB_IP}"
}

function reservoir_create_cloudsql_service_account {
  local TMP_DIR="/tmp/reservoir"
  RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT="reservoir-cloudsql-sa"
  RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED="${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
  RESERVOIR_CLOUDSQL_KEY_SECRET="reservoir-sa-key"

  if [ -z "${GCP_PROJECT_ID}" ]
  then
    LOG "Please specify GCP_PROJECTID env variable."
  fi
    
  if [ ! -d "${TMP_DIR}" ]
  then
    LOG "Creating ${TMP_DIR}"
    mkdir "${TMP_DIR}"
  fi

  if ! gcloud iam service-accounts describe ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED}
  then
    LOG "Creating service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED}"
    if ! gcloud iam service-accounts create "${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}" \
      --description "Service Account for Reservoir CloudSQL Proxy."; then
      LOG "Failed to create service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}"
      return 1
    fi
  else
    LOG "${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED} already exists."
  fi

  gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
    --member=serviceAccount:${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT_QUALIFIED} \
    --role=roles/cloudsql.editor

  if [ $? -ne 0 ]
  then
    LOG "Failed to bind ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT} to cloudsql.admin role."
    return 1
  fi
  
  LOG "Creating new access key for reservoir service account: ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}"
  
  if ! gcloud iam service-accounts keys create "${TMP_DIR}/key.json" \
    --iam-account ${RESERVOIR_CLOUDSQL_SERVICE_ACCOUNT}@${GCP_PROJECT_ID}.iam.gserviceaccount.com;
  then
    LOG "Failed to create ${RESERVOIR_CLOUD_SERVICE_ACCOUNT_NAME} service account key."
    return 1
  else
    LOG "Key: $(cat ${TMP_DIR}/key.json)"
  fi

  if kubectl get secrets "${RESERVOIR_CLOUDSQL_KEY_SECRET}"
  then
    LOG "Deleteing old ${RESERVOIR_CLOUDSQL_KEY_SECRET} key."
    kubectl delete secrets "${RESERVOIR_CLOUDSQL_KEY_SECRET}"
  fi
  
  kubectl create secret generic "${RESERVOIR_CLOUDSQL_KEY_SECRET}" \
    --from-file=service_account.json="${TMP_DIR}/key.json"  
}

function reservoir_create_db_credentials {
  add_secret ${secrets_env_file} RESERVOIR_DB_USER "reservoir"
  add_secret ${secrets_env_file} RESERVOIR_DB_PASSWORD "$(generate_password)"
  add_secret ${secrets_env_file} RESERVOIR_DB_HOST "127.0.0.1" # Use proxy side car.
  add_secret ${secrets_env_file} RESERVOIR_DB_PORT "5432"
  add_secret ${secrets_env_file} RESERVOIR_DB_NAME "${RESERVOIR_DB_NAME}"
  add_secret ${secrets_env_file} RESERVOIR_DB_INSTANCE "${RESERVOIR_DB_INSTANCE}"
  add_secret ${secrets_env_file} RESERVOIR_DB_INSTANCE_CONNECTION_NAME "${GCP_PROJECT_ID}:${GCP_REGION}:${RESERVOIR_DB_INSTANCE}=tcp:${RESERVOIR_DB_PORT}"
}

function reservoir_create_db_instance {

  if [ -z "${RESERVOIR_DB_PASSWORD}" ]; then
     LOG "RESERVOIR_DB_PASSWORD is not set, creating DB credentials."
     reservoir_create_db_credentials
  fi
  gcloud sql databases list --instance="${RESERVOIR_DB_INSTANCE}"

  if [ $? -ne 0 ]
  then
    LOG "Creating new reservoir database instance: ${RESERVOIR_DB_INSTANCE}"
      gcloud beta sql instances create "${RESERVOIR_DB_INSTANCE}" --cpu=2 --memory=7680MiB \
    --database-version=POSTGRES_12 --zone=${GCP_ZONE} --storage-type=SSD \
    --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip
  fi

  if [ $? -ne 0 ]
  then
    LOG "Failed to create Reservoir sql database."
    return 1
  fi
  
  # reservoir_get_db_ip
  gcloud beta sql databases create "${RESERVOIR_DB_NAME}" --instance="${RESERVOIR_DB_INSTANCE}"
  
  gcloud beta sql users create "${RESERVOIR_DB_USER}" --instance="${RESERVOIR_DB_INSTANCE}" "--password=${RESERVOIR_DB_PASSWORD}"
}

function reservoir_run_init_db_job {
  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  set -x
  ${script_dir}/kapply k8s/reservoir-db-migration-job.yaml.in
  set +x

  # Give the migration time to complete
  LOG "Waiting one minute for migrations to complete."
  sleep 60s

  kubectl logs -l name=reservoir-db-migration

  LOG "To delete db init job run: kubectl delete jobs reservoir-db-migration"
}

function reservoir_start_internal_service {
  LOG "Starting Reservoir internal Load Balancer."

  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  set -x
  ${script_dir}/kapply k8s/reservoir-service.yaml.in
  set +x

  # Give the service a few seconds to start
  sleep 30s

  kubectl get services
}

function reservoir_start_external_service {
  LOG_INFO "Starting Reservoir external Load Balancer."

  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  set -x
  ${script_dir}/kapply k8s/reservoir-service-external.yaml.in
  set +x

  # Give the service a few seconds to start
  sleep 30s

  kubectl get services
}

function reservoir_deploy_debug {
  add_secret ${secrets_env_file} RESERVOIR_DEBUG "True"
  add_secret ${secrets_env_file} RESERVOIR_PORT "8080"
  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  ${script_dir}/kapply k8s/reservoir-deployment.yaml.in
}

function reservoir_deploy_prod {
  add_secret ${secrets_env_file} RESERVOIR_DEBUG "False"
  add_secret ${secrets_env_file} RESERVOIR_SITE_PREFIX "r"
  add_secret ${secrets_env_file} RESERVOIR_STATIC_URL "/r/static/"
  add_secret ${secrets_env_file} RESERVOIR_MODEL_DIR "/reservoir/models"

  sed -i "/RESERVOIR_PORT/ c export RESERVOIR_PORT=80" "${SECRETS_FILE}"
  
  local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  ${script_dir}/kapply k8s/reservoir-deployment.yaml.in
}

function reservoir_create_resources_parallel {
  # Wait for this to complete prior to kicking of parallel cloud build.
  clone_reservoir

  # Wait on this so that create_db and cloud_build have access to the same
  # credentials through the secrets file.
  if ! reservoir_create_db_credentials; then
    LOG_ERROR "Failed to create database credentials."
  else
    LOG_ERROR "Created database credentials."
  fi
  
  reservoir_cloud_build &
  RESERVOIR_CLOUD_BUILD_PID=$!

  reservoir_create_db_instance &
  RESERVOIR_CREATE_DB_INSTANCE_PID=$!

  reservoir_create_cloudsql_service_account &
  RESERVOIR_CREATE_CLOUDSQL_SERVICE_ACCOUNT_PID=$!

  reservoir_create_nas &
  RESERVOIR_CREATE_NAS_PID=$!

  RESERVOIR_JOB_PIDS="${RESERVOIR_CLOUD_BUILD_PID} ${RESERVOIR_CREATE_DB_INSTANCE_PID} ${RESERVOIR_CREATE_CLOUDSQL_SERVICE_ACCOUNT_PID} ${RESERVOIR_CREATE_NAS_PID}"
  
  LOG_INFO "RESERVOIR_JOB_PIDS: ${RESERVOIR_JOB_PIDS}"

  function killalljobs {
    LOG_ERROR "KILLING Reservoir resource jobs: ${RESERVOIR_JOB_PIDS}"
    for job_pid in ${RESERVOIR_JOB_PIDS}; do
      set -x 
      LOG_ERROR "KILLING: ${job_pid}"
      echo "echo KILLING: ${job_pid}"
      kill -9 ${job_pid}
      set +x
    done
  }

  # do we need to wait on NAS before PVC creation?
  LOG_INFO "Waiting on NAS creation."
  if ! wait $RESERVOIR_CREATE_NAS_PID; then
    LOG_ERROR "Failed to create NAS."
    killalljobs
  fi


  LOG_INFO "Launching Reservoir PVC creation."
  reservoir_create_pvc &
  RESERVOIR_CREATE_PVC_PID=$!
  RESERVOIR_JOB_PIDS="${RESERVOIR_JOB_PIDS} $RESERVOIR_CREATE_PVC_PID"

  if ! wait $RESERVOIR_CREATE_PVC_PID; then
    LOG_ERROR "Failed to create Reservoir PVC."
    killalljobs
    return 1
  else
    LOG_INFO "Finished creating Reservoir PVC."
  fi

  LOG_INFO "Waiting for DB creation."
  if ! wait $RESERVOIR_CREATE_DB_INSTANCE_PID; then
    LOG_ERROR "Failed to create Reservoir DB Instance."
    killalljobs
    return 1
  else
    LOG_INFO "Created Reservoir DB Instance."
  fi

  LOG_INFO "Waiting for Reservoir Cloud Build."
  if ! wait $RESERVOIR_CLOUD_BUILD_PID; then
    LOG_ERROR "Reservoir CloudBuild Failed."
    killalljobs
    return 1
  else
    LOG_INFO "Finished Reservoir CloudBuild."
  fi

  if ! wait $RESERVOIR_CREATE_CLOUDSQL_SERVICE_ACCOUNT_PID; then
    LOG_ERROR "Failed to create Reservoir CloudSQL service account."
    killalljobs
    return 1
  fi
  
  if ! reservoir_run_init_db_job; then
    LOG_ERROR "Failed to Initialize Reservoir cloudsql DB."
    killalljobs
    return 1
  fi

  LOG_INFO "Sucessfully created Reservoir resources."
}

function reservoir_kbootstrap {
  LOG_INFO "Creating Reservoir image, DB, NAS, PVC, service accounts and initializing DB."

  if ! reservoir_create_resources_parallel; then
    LOG_INFO "Failed to create Reservoir resources."
    return 1
  fi

  LOG_INFO "Finished allocating Reservoir resources."

  LOG_INFO "Deploying production reservoir application."
  if ! reservoir_deploy_prod; then
    LOG_INFO "Failed to deploy reservoir production application."
    return 1
  fi

  LOG_INFO "Deploying reservoir internal LB service."
  if ! reservoir_start_internal_service; then
    LOG_ERROR "Failed to start reservoir internal service."
    return 1
  fi

}
