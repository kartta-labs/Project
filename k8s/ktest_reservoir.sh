#!/bin/bash
#
# Simple test script that will deploy Reservoir to a Kubernetes Cluster.
#
# Broken out as separate job from kbootstrap to facilitate rapid testing of the deployment of Reservoir
# without the need to spin up the full Waybak suite of tools.
#
# Creates new project with random suffix and deploys all necessary reserouces to the cluster
# Note you need to be a billing admin in the wybk.org organization to run this script.
#
# Useful command for monitoring INFO/ERROR messages in rich log file:
# tail -f /tmp/ktest_reservoir_[timestamp]_[hash].log | grep 'INFO\|ERROR'
#

current_script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

. ${current_script_dir}/functions.sh
. ${current_script_dir}/reservoir_functions.sh

function cleanup {
  gcloud project delete "${GCP_PROJECT_ID}"
}

# Overwrite the LOG_INFO function in this file.
LOG_INFO() {
    echo "[ktest_reservoir INFO $(date +"%Y-%m-%d %T %Z")] $1"
}

# This will update the SECRETS_FILE
if ! create_waybak_test_project; then
  LOG_INFO "Failed to create waybak test project GCP_PROJECT_ID: ${GCP_PROJECT_ID}"
  return 1
fi

LOG_INFO "From ktest: SECRETS_FILE: ${SECRETS_FILE}"
LOGFILE="/tmp/ktest_reservoir_$(date +%m%d%y_%H%M%S)_${GCP_PROJECT_SUFFIX}.log"
touch ${LOGFILE}
LOG_INFO "LOGFILE: ${LOGFILE}"
export CLUSTER_NAME="test-cluster"
export CLOUDBUILD_LOGS_BUCKET="gs://cloudbuild-logs-${GCP_PROJECT_SUFFIX}"

(
LOG_INFO "GCP_PROJECT_ID: ${GCP_PROJECT_ID}"
LOG_INFO "CLUSTER_NAME: ${CLUSTER_NAME}"
LOG_INFO "CLOUDBUILD_LOGS_BUCKET= ${CLOUDBUILD_LOGS_BUCKET}"

# Clean and remake secrets file
# if [ -f "${SECRETS_FILE}" ]
# then
#   LOG_INFO "Deleting secrets file."
#   rm "${SECRETS_FILE}"
#   python3 ./makesecrets ~/waybak-secrets.yml
# fi


LOG_INFO "Enable gcloud services for Reservoir."
set -x
gcloud services enable cloudbuild.googleapis.com container.googleapis.com \
  containerregistry.googleapis.com file.googleapis.com redis.googleapis.com \
  servicenetworking.googleapis.com sql-component.googleapis.com sqladmin.googleapis.com \
  storage-api.googleapis.com storage-component.googleapis.com vision.googleapis.com
set +x


if [ ! $(gsutil ls "${CLOUDBUILD_LOGS_BUCKET}") ]; then
  LOG_INFO "Creating cloud build logs bucket: ${CLOUDBUILD_LOGS_BUCKET}"
  gsutil mb -p "${GCP_PROJECT_ID}" "${CLOUDBUILD_LOGS_BUCKET}"
  if [ $? -ne 0 ]; then
    LOG_INFO "FAILED TO CREATE BUCKET."
    return 1
  fi
fi

LOG_INFO "Creating Reservoir kubernetes cluster."
gcloud container clusters create ${CLUSTER_NAME}  --zone ${GCP_ZONE} \
  --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3

# Necessary for database creation
gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default


LOG_INFO "Creating Reservoir image, DB, NAS, PVC, service accounts, and initializing DB."
if ! reservoir_create_resources_parallel; then
  LOG_INFO "Failed to create Reservoir resources."
  return 1
fi
LOG_INFO "Finished creating Reservoir resources."

# Push an external loadbalancer for debugging
LOG_INFO "Creating external Reservoir LB service."
if ! reservoir_start_external_service; then
  LOG_INFO "Failed to start externally available service."
  return 1
else
  LOG_INFO "Service available at external ip: $(kubectl get services)"
fi

# Pushing debug deployment
if ! reservoir_deploy_debug; then
  LOG_INFO "Failed to push deployment."
  return 1
fi

LOG_INFO "To clean up this test, run the following command: gcloud projects delete ${GCP_PROJECT_ID}"

) 2>&1 | tee "${LOGFILE}"
