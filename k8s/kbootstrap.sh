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

/bin/rm -f kbootstrap.log

(

# Set 'script_dir' to the full path of the directory containing this script
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Load common functions
. ${script_dir}/functions.sh

# make sure the secrets file is present
secrets_env_file="./container/secrets/secrets.env"

# Uncomment this line to create a backup of secrets.env on every run (useful when editing/debugging this script):
#cp ${secrets_env_file} /tmp/secrets.env.$$

if [ \! -f "${secrets_env_file}" ] ; then
  echo "Before running kbootstrap.sh, you should run ./makesecrets to generate a secrets file,"
  echo "and edit it to set the required values for a k8s deployment."
  exit -1
fi

. ${secrets_env_file}

# k8s-specific secrets settings which override the defaults:
add_secret ${secrets_env_file} MAPWARPER_RAILS_ENV "production"
add_secret ${secrets_env_file} MAPWARPER_GOOGLE_STORAGE_ENABLED "true"
add_secret ${secrets_env_file} MAPWARPER_SECRET_KEY_BASE $(generate_secret_key)
add_secret ${secrets_env_file} FORCE_HTTPS "true"

# For now disable these in k8s since k8s deployment for them isn't written yet.  Note this is needed
# to prevent nginx from requiring these.  These lines should be deleted once these apps are configured
# for k8s:
add_secret ${secrets_env_file} ENABLE_RESERVOIR "true"

set -x

###
### general gcp setup
###
gcloud config set project ${GCP_PROJECT_ID}
gcloud config set compute/zone ${GCP_ZONE}
gcloud services enable cloudbuild.googleapis.com container.googleapis.com containerregistry.googleapis.com file.googleapis.com redis.googleapis.com servicenetworking.googleapis.com sql-component.googleapis.com sqladmin.googleapis.com storage-api.googleapis.com storage-component.googleapis.com vision.googleapis.com maps-backend.googleapis.com geolocation.googleapis.com geocoding-backend.googleapis.com
export KLUSTER="${GCP_PROJECT_ID}-k1"
gcloud container clusters create ${KLUSTER} --zone ${GCP_ZONE} --release-channel stable --enable-ip-alias --machine-type "n1-standard-4" --num-nodes=3
gcloud compute addresses create google-managed-services-default --global --purpose=VPC_PEERING --prefix-length=20 --network=default
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --network=default --ranges=google-managed-services-default
cloudbuild_logs_bucket_suffix=$(generate_bucket_suffix)
add_secret ${secrets_env_file} CLOUDBUILD_LOGS_BUCKET "gs://cloudbuild-logs-${cloudbuild_logs_bucket_suffix}"
gsutil mb -p ${GCP_PROJECT_ID} ${CLOUDBUILD_LOGS_BUCKET}
PROJECT_NUMBER=`gcloud projects list "--filter=${GCP_PROJECT_ID}" "--format=value(PROJECT_NUMBER)"`
gsutil iam ch serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectAdmin,objectCreator,objectViewer,legacyBucketWriter ${CLOUDBUILD_LOGS_BUCKET}

#TODO: determine whether warper really uses this service account, and if not, get rid of it
gcloud iam service-accounts create warper-sa --display-name 'warper access for storage and cloud sql'
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.admin
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.client
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} --member=serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudsql.editor
gcloud iam service-accounts keys create /tmp/warper-service-account.json --iam-account warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com
cat /tmp/warper-service-account.json > container/secrets/warper-service-account.json
rm -f /tmp/warper-service-account.json

###
### warper storage buckets
###
set +x
BUCKET_SUFFIX=$(generate_bucket_suffix)
add_secret ${secrets_env_file} MAPWARPER_WARPER_BUCKET "warper-${BUCKET_SUFFIX}"
add_secret ${secrets_env_file} MAPWARPER_TILES_BUCKET "tiles-${BUCKET_SUFFIX}"
add_secret ${secrets_env_file} MAPWARPER_OCR_BUCKET "ocr-${BUCKET_SUFFIX}"
set -x
gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_WARPER_BUCKET}
gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_TILES_BUCKET}
gsutil mb -p ${GCP_PROJECT_ID} gs://${MAPWARPER_OCR_BUCKET}

#  give service account "warper-sa" access to those buckets
gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_WARPER_BUCKET}
gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_TILES_BUCKET}
gsutil iam ch serviceAccount:warper-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com:objectAdmin,objectCreator,objectViewer gs://${MAPWARPER_OCR_BUCKET}

# create tiles-backend-bucket
gcloud compute backend-buckets create tiles-backend-bucket --enable-cdn --gcs-bucket-name=${MAPWARPER_TILES_BUCKET}

# set up url maps and public ip for tiles-backend-bucket
gcloud compute url-maps create warper-tiles-url-map --default-backend-bucket=tiles-backend-bucket
gcloud compute url-maps add-path-matcher warper-tiles-url-map --default-backend-bucket tiles-backend-bucket --path-matcher-name warper-tiles-bucket-matcher '--backend-bucket-path-rules=/*=tiles-backend-bucket'
gcloud compute target-http-proxies create http-tiles-lb-proxy --url-map warper-tiles-url-map
gcloud compute addresses create warper-tiles-ip --global
gcloud compute forwarding-rules create tiles-http-forwarding-rule --address=warper-tiles-ip --global --target-http-proxy http-tiles-lb-proxy --ports=80


###
### warper managed NAS file storage
###
gcloud filestore instances create warper-fs --project=${GCP_PROJECT_ID} --zone=${GCP_ZONE} --tier=STANDARD --file-share=name=mapfileshare,capacity=1TB --network=name=default
set +x
add_secret ${secrets_env_file} MAPWARPER_NFS_SERVER "`gcloud filestore instances describe warper-fs --zone=us-east4-a --format="value(networks[0].ipAddresses[0])"`"
set -x
# create PersistentVolume (nfs mount) called warper-fileserver
${script_dir}/kapply k8s/warper-filestore-storage.yaml.in

###
### create services
###
${script_dir}/kcreate k8s/cgimap-service.yaml.in
${script_dir}/kcreate k8s/editor-service.yaml.in
${script_dir}/kcreate k8s/fe-service.yaml.in
${script_dir}/kcreate k8s/warper-service.yaml.in
${script_dir}/kcreate k8s/oauth-proxy-service.yaml.in
if [ "${ENABLE_KARTTA}" != "" ]; then
  ${script_dir}/kcreate k8s/kartta-service.yaml.in
fi


###
### clone code repos
###
git clone ${EDITOR_REPO} editor-website
git clone ${MAPWARPER_REPO} warper
git clone ${CGIMAP_REPO} openstreetmap-cgimap

if [ "${ENABLE_KARTTA}" != "" ]; then
  git clone ${KARTTA_REPO} kartta
  (cd kartta ; git clone ${ANTIQUE_REPO} antique)
fi

###
### build & tag latest images
###


# oauth-proxy
export OAUTH_PROXY_SHORT_SHA=`cat Dockerfile-oauth-proxy container/config/oauth-proxy/* | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/oauth_proxy" "--substitutions=SHORT_SHA=${OAUTH_PROXY_SHORT_SHA}"  --config k8s/cloudbuild-oauth-proxy.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:${OAUTH_PROXY_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/oauth-proxy:latest"

# fe
export FE_SHORT_SHA=`cat Dockerfile-fe container/config/fe/* | md5sum  | sed -e 's/\(.\{7\}\).*/\1/'`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/fe" "--substitutions=SHORT_SHA=${FE_SHORT_SHA}"  --config k8s/cloudbuild-fe.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/fe:${FE_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/fe:latest"

# editor
export EDITOR_SHORT_SHA=`(cd editor-website ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/editor" "--substitutions=SHORT_SHA=${EDITOR_SHORT_SHA}"  --config k8s/cloudbuild-editor.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/editor:${EDITOR_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/editor:latest"

# cgimap
export CGIMAP_SHORT_SHA=`(cd openstreetmap-cgimap ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/cgimap" "--substitutions=SHORT_SHA=${CGIMAP_SHORT_SHA}"  --config k8s/cloudbuild-cgimap.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/cgimap:${CGIMAP_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/cgimap:latest"

# warper
export MAPWARPER_SHORT_SHA=`(cd warper ; git rev-parse --short HEAD)`
gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/warper" "--substitutions=SHORT_SHA=${MAPWARPER_SHORT_SHA}"  --config k8s/cloudbuild-warper.yaml .
gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/warper:${MAPWARPER_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/warper:latest"

if [ "${ENABLE_RESERVOIR}" != "" ]; then
  . ${script_dir}/reservoir_functions.sh
  LOG_INFO "Bootstrapping reservoir."
  if ! reservoir_kbootstrap; then
    LOG_ERROR "Failed to bootstrap reservoir."
  fi
else
  LOG_INFO "Skipping Reservoir bootstrap."
fi

# kartta
if [ "${ENABLE_KARTTA}" != "" ]; then
  export KARTTA_SHORT_SHA=`(cd kartta ; git rev-parse --short HEAD)`
  gcloud builds submit "--gcs-log-dir=${CLOUDBUILD_LOGS_BUCKET}/kartta" "--substitutions=SHORT_SHA=${KARTTA_SHORT_SHA}"  --config k8s/cloudbuild-kartta.yaml kartta
  gcloud container images add-tag --quiet "gcr.io/${GCP_PROJECT_ID}/kartta:${KARTTA_SHORT_SHA}" "gcr.io/${GCP_PROJECT_ID}/kartta:latest"
fi

###
### editor database
###

# create the sql instance
#   Note we set temp_file_limit=2147483647, which is the max allowd value per
#   https://cloud.google.com/sql/docs/postgres/flags#gcloud, because a large limit is needed to support generating data
#   exports with osmosis.
gcloud beta sql instances create editor-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_11 --zone=${GCP_ZONE} --storage-type=SSD --network=default --database-flags temp_file_limit=2147483647 --no-assign-ip

set +x
echo "generating passwords and storing secrets..."
# store sql instance ip in secrets
add_secret ${secrets_env_file} EDITOR_DB_HOST `gcloud beta sql instances describe editor-sql --format="value(ipAddresses.ipAddress)"`
# generate passwords and store in secrets
add_secret ${secrets_env_file} EDITOR_DB_USER karttaweb
add_secret ${secrets_env_file} EDITOR_SQL_POSTGRES_PASSWORD $(generate_password)
add_secret ${secrets_env_file} EDITOR_SQL_KARTTAWEB_PASSWORD $(generate_password)
set -x

# set the generated passwords
gcloud beta sql users set-password postgres --instance=editor-sql "--password=${EDITOR_SQL_POSTGRES_PASSWORD}"
gcloud beta sql users create karttaweb --instance=editor-sql "--password=${EDITOR_SQL_KARTTAWEB_PASSWORD}"

# perform database migration; note this uses the gcr.io editor image built above to run a job
${script_dir}/resecret
${script_dir}/kcreate k8s/editor-db-migration-job.yaml.in
set +x
wait_for_k8s_job editor-db-migration
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job editor-db-migration

###
### warper database
###

#  create sql instance, store ip, generate and store password
gcloud beta sql instances create warper-sql --cpu=1 --memory=3840MiB --database-version=POSTGRES_9_6 --zone=${GCP_ZONE} --storage-type=SSD --network=default --no-assign-ip
set +x
echo "generating passwords and storing secrets..."
add_secret ${secrets_env_file} MAPWARPER_DB_HOST `gcloud beta sql instances describe warper-sql --format="value(ipAddresses.ipAddress)"`
add_secret ${secrets_env_file} MAPWARPER_POSTGRES_PASSWORD $(generate_password)
set -x

# set the generated password
gcloud sql users set-password postgres --instance=warper-sql "--password=${MAPWARPER_POSTGRES_PASSWORD}"

# create warper_production database
gcloud sql databases create warper_production --instance=warper-sql


# perform database migration; note this uses the gcr.io warper image built above to run a job
${script_dir}/resecret
${script_dir}/kcreate k8s/warper-db-migration-job.yaml.in
set +x
wait_for_k8s_job warper-db-migration
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job warper-db-migration

 

###
### warper redis instance
###
gcloud beta redis instances create warper-redis --size=2 --region=${GCP_REGION} --zone=${GCP_ZONE} --redis-version=redis_4_0 --redis-config maxmemory-policy=allkeys-lru
set +x
add_secret ${secrets_env_file} MAPWARPER_REDIS_HOST "`gcloud redis instances describe warper-redis --region=${GCP_REGION} --format="value(host)"`"
add_secret ${secrets_env_file} MAPWARPER_REDIS_URL "redis://${MAPWARPER_REDIS_HOST}:6379/0/cache"
set -x


###
### warper file storage initialization
###
${script_dir}/resecret
${script_dir}/kcreate k8s/warper-fs-initialization-job.yaml.in
set +x
wait_for_k8s_job warper-fs-initialization
set -x
# Don't delete this job for now, to make it possible to view its logs.
#kubectl delete job warper-fs-initialization


###
### deploy applications
###
${script_dir}/resecret
${script_dir}/kcreate k8s/cgimap-deployment.yaml.in
${script_dir}/kcreate k8s/editor-deployment.yaml.in
${script_dir}/kcreate k8s/fe-deployment.yaml.in
${script_dir}/kcreate k8s/oauth-proxy-deployment.yaml.in
${script_dir}/kcreate k8s/warper-deployment.yaml.in
if [ "${ENABLE_KARTTA}" != "" ]; then
  ${script_dir}/kcreate k8s/kartta-deployment.yaml.in
fi

###
### create ssl cert and https ingress
###
${script_dir}/kcreate k8s/managed-certificate.yaml.in
${script_dir}/kcreate k8s/backend-config.yaml.in
${script_dir}/kcreate k8s/nodeport-service.yaml.in
${script_dir}/kcreate k8s/ingress.yaml.in
set +x
wait_for_ingress_ip "kartta-ingress"
add_secret ${secrets_env_file} INGRESS_IP ${INGRESS_IP}
echo "got INGRESS_IP=${INGRESS_IP}"
set -x


set +x
echo ""
echo "########################################################################################"
echo ""
echo "Everything is launched.  Excellent!"
echo ""
echo "Run"
echo "    kubectl get pods"
echo "to see the list of running pods.  It might take a few minutes for all pods to"
echo "become ready."
echo ""
echo "You should now create a public DNS entry to associate the name ${SERVER_NAME}"
echo "with the ip address ${INGRESS_IP}."
echo ""
echo "After creating the public DNS entry, run the command"
echo "    kubectl describe managedcertificate"
echo "every few minutes until the domain status says 'Active'. It might take 15-30"
echo "minutes or so.  If the domain status says 'FailedNotVisible', it means the"
echo "the DNS name isn't recognized yet.  If that happens, double-check that you"
echo "correctly created the DNS entry, and wait a few more minutes and check again."
echo "GKE will repeatedly try to provision the certificate every few minutes."
echo ""
echo "Once the certificate is provisioned, you can access the site at"
echo "    https://${SERVER_NAME}"
echo ""
echo "It's normal to get 'Error: Server Error' 502 errors for the first few minutes"
echo "after the certificate is provisioned.  If that happens, wait a few minutes and"
echo "reload the page."
echo ""

) 2>&1 | tee kbootstrap.log
