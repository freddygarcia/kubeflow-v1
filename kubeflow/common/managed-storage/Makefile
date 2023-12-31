# Copyright 2021 Google LLC
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

PACKAGE_DIR?=$(shell pwd)/../..
YQ=docker run --rm -v "$(PACKAGE_DIR)/":/workdir mikefarah/yq:4
KF_PROJECT=$(shell $(YQ) e '.data."gcloud.core.project"' kptconfig/kpt-setter-config.yaml)
MGMTCTXT=$(shell $(YQ) e '.data.mgmt-ctxt' kptconfig/kpt-setter-config.yaml)

build_dir?=./build

.PHONY: hydrate
hydrate:
	rm -rf $(build_dir)
	mkdir -p $(build_dir)
	kustomize build -o $(build_dir)/ .

.PHONY: apply
apply: apply-cnrm wait

.PHONY: delete
delete:
	kubectl --context=$(MGMTCTXT) delete -f $(build_dir)

.PHONY: apply-cnrm
apply-cnrm: hydrate
	kubectl --context=$(MGMTCTXT) apply -f $(build_dir)

.PHONY: wait
wait:
	# Wait for all Google Cloud resources to get created and become ready.
	# If this takes long, you can view status by:
	@echo "cd common/managed-storage && make status"
	# For resources with READY=False, debug by:
	@echo "kubectl --context=$(MGMTCTXT) -n $(KF_PROJECT) describe <KIND>/<NAME>"
	@echo
	kubectl --context=$(MGMTCTXT) wait --for=condition=Ready --timeout=100s -f $(build_dir) \
		|| kubectl --context=$(MGMTCTXT) get -f $(build_dir)
	kubectl --context=$(MGMTCTXT) wait --for=condition=Ready --timeout=500s -f $(build_dir)

.PHONY: status
status:
	kubectl --context=$(MGMTCTXT) get -f $(build_dir)
