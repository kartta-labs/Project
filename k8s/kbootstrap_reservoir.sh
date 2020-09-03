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
# Assumes gcloud is already propery configured.

###
### Reservoir managed NAS file storage
###

# Set 'script_dir' to the full path of the directory containing this script
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

. ${script_dir}/reservoir_functions.sh
. ${script_dir}/functions.sh

# Generate Reservoir Images via Cloud Build

reservoir_cloud_build &
RESERVOIR_CLOUD_BUILD_PID=$?

reservoir_create_nas &
RESERVOIR_CREATE_NAS=$?

reservoir_

# Create Reservoir NAS
if ! reservoir_create_nas; then
  LOG_INFO "Reservoir failed to create network mapped storage."
  return 1
fi






