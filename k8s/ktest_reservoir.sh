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

current_script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# 1. Create a new project with random postfix
LOG_INFO() {
    echo "[ktest_reservoir INFO $(date +"%Y-%m-%d %T %Z")] $1"
}

function generate_random_suffix {
  # Generates a random 16-character password that can be used as a bucket name suffix
  local LENGTH="${1:-15}"
  echo "b`(date ; dd if=/dev/urandom count=2 bs=1024) 2>/dev/null | md5sum | head -c ${LENGTH}`"
}

function cleanup {
  gcloud project delete "${GCP_PROJECT_ID}"
}

export GCP_POSTFIX="$(generate_random_suffix 5)"
export WYBK_ORG_ID=344127236084
export WYBK_BILLING_ID="01930B-854143-2F2F86"
LOGFILE="/tmp/ktest_reservoir_${GCP_POSTFIX}.log"
touch ${LOGFILE}
export GCP_PROJECT_ID="waybak-test-$(generate_random_suffix 5)"
export GCP_REGION=us-"east4"
export GCP_ZONE="us-east4-a"
export CLUSTER_NAME="test-cluster"
export CLOUDBUILD_LOGS_BUCKET="gs://cloudbuild-logs-$(generate_random_suffix)"
SECRETS_FILE="./container/secrets/secrets.env"

. ${current_script_dir}/functions.sh
. ${current_script_dir}/reservoir_functions.sh

(
LOG_INFO "GCP_PROJECT_ID: ${GCP_PROJECT_ID}"
LOG_INFO "CLUSTER_NAME: ${CLUSTER_NAME}"
LOG_INFO "CLOUDBUILD_LOGS_BUCKET= ${CLOUDBUILD_LOGS_BUCKET}"

# Clean and remake secrets file
if [ -f "${SECRETS_FILE}" ]
then
  LOG_INFO "Deleting secrets file."
  rm "${SECRETS_FILE}"
  python3 ./makesecrets ~/waybak-secrets.yml
fi

# Change the secrets file to match the test/current GCP_PROJECT_ID
sed -i "/GCP_PROJECT_ID/ c export GCP_PROJECT_ID=${GCP_PROJECT_ID}" "${SECRETS_FILE}"

gcloud projects create "${GCP_PROJECT_ID}" --organization="${WYBK_ORG_ID}"

if [ $? -ne 0 ]
then
  echo "Failed to create project ${GPC_PROJECT_ID}"
  return 1
fi

gcloud config set project ${GCP_PROJECT_ID}
gcloud config set compute/zone ${GCP_ZONE}

# Need billing activated to enable apis
gcloud beta billing projects link "${GCP_PROJECT_ID}" --billing-account "${WYBK_BILLING_ID}"

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

gcloud container clusters create ${CLUSTER_NAME}  --zone ${GCP_ZONE} \
  --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3

# Necessary for database creation
gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default

# Create and configure the Postgres SQL Database w/ service accounts.
if ! reservoir_create_db_instance; then
  LOG_INFO "Failed to create Reservoir DB instance."
  return 1
fi

if ! reservoir_create_cloudsql_service_account; then
  LOG_INFO "Failed to create Reservoir CloudSQL service account."
  return 1
fi

clone_reservoir

# Run cloud build
if ! reservoir_cloud_build; then
  LOG_INFO "Reservoir Cloudbuild failed."
  return 1
fi


# Create the NAS        
if ! reservoir_create_nas; then
  LOG_INFO "Reservoir failed to create network mapped storage."
  return 1
fi

# Create the Persistent Volume and Persistent Volume Claim
if ! reservoir_create_pvc; then
   LOG_INFO "Reservoir failed to create a PVC for the application to aquire the NAS."
   return 1
fi

# Initialze the CloudSQL Database with extensions and Migrations.
if ! reservoir_run_init_db_job; then
  LOG_INFO "Failed to initialize cloudsql db."
  return 1
fi

# Push an external loadbalancer for debugging
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
