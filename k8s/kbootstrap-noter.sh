#! /bin/sh
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

###
###  IMPORTANT NOTE
###
###  This script is invoked by kbootstrap.sh (if ENABLE_NOTER!="" in secrets.env).
###  It's not normally intended to be run by itself, although doing so might work if you
###  are careful.
###

# Set 'script_dir' to the full path of the directory containing this script
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Load common functions
. ${script_dir}/functions.sh

# make sure the secrets file is present
secrets_env_file="./container/secrets/secrets.env"

# Uncomment this line to create a backup of secrets.env on every run (useful when editing/debugging this script):
#cp ${secrets_env_file} /tmp/secrets.env.$$

if [ \! -f "${secrets_env_file}" ] ; then
  echo "Before running kbootstrap-noter.sh, you should run ./makesecrets to generate a secrets file,"
  echo "and edit it to set the required values for a k8s deployment."
  exit -1
fi

. ${secrets_env_file}

add_secret ${secrets_env_file} NOTER_BACKEND_ADMIN_PASSWORD $(generate_password)

set -x

###
### service account
###
gcloud iam service-accounts create noter-sa --display-name 'noter access for storage'

gcloud iam service-accounts keys create /tmp/noter-service-account.json --iam-account noter-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com
cat /tmp/noter-service-account.json > container/secrets/noter-service-account.json
rm -f /tmp/noter-service-account.json

###
### storage bucket
###
set +x
add_secret ${secrets_env_file} NOTER_BUCKET "noter-${BUCKET_SUFFIX}"
set -x
gsutil mb -p ${GCP_PROJECT_ID} gs://${NOTER_BUCKET}
gsutil iam ch serviceAccount:noter-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${NOTER_BUCKET}

###
### services
###
${script_dir}/kcreate k8s/noter-backend-service.yaml.in
${script_dir}/kcreate k8s/noter-frontend-service.yaml.in

###
### clone code repos
###
clone_repo ${NOTER_BACKEND_REPO} noter-backend
clone_repo ${NOTER_FRONTEND_REPO} noter-frontend


###
### build & tag latest images
###

cloud_build noter-backend
cloud_build noter-frontend

###
### database
###

# create the sql instance
gcloud beta sql instances create noter-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_12 --zone=${GCP_ZONE} --storage-type=SSD --network=default --no-assign-ip

set +x
echo "generating passwords and storing secrets..."
# store sql instance ip in secrets
add_secret ${secrets_env_file} NOTER_BACKEND_DB_HOST `gcloud beta sql instances describe noter-sql --format="value(ipAddresses.ipAddress)"`
# generate passwords and store in secrets
add_secret ${secrets_env_file} NOTER_BACKEND_POSTGRES_PASSWORD $(generate_password)
set -x

# set the generated passwords
gcloud beta sql users set-password postgres --instance=noter-sql "--password=${NOTER_BACKEND_POSTGRES_PASSWORD}"

# perform database migration; note this uses the gcr.io noter-backend image built above to run a job
${script_dir}/resecret
${script_dir}/kcreate k8s/noter-db-migration-job.yaml.in
set +x
wait_for_k8s_job noter-db-migration
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job noter-db-migration

###
### deploy applications
###
${script_dir}/resecret
${script_dir}/kcreate k8s/noter-backend-deployment.yaml.in
${script_dir}/kcreate k8s/noter-frontend-deployment.yaml.in
