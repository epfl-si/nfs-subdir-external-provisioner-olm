# VERSION defines the project version for the bundle.
# Update this value when you upgrade the version of your project.
# To re-generate a bundle for another specific version without changing the standard setup, you can:
# - use the VERSION as arg of the bundle target (e.g make bundle VERSION=0.0.2)
# - use environment variables to overwrite this value (e.g export VERSION=0.0.2)
VERSION ?= 0.0.24

# CHANNELS define the bundle channels used in the bundle.
# Add a new line here if you would like to change its default config. (E.g CHANNELS = "candidate,fast,stable")
# To re-generate a bundle for other specific channels without changing the standard setup, you can:
# - use the CHANNELS as arg of the bundle target (e.g make bundle CHANNELS=candidate,fast,stable)
# - use environment variables to overwrite this value (e.g export CHANNELS="candidate,fast,stable")
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

# DEFAULT_CHANNEL defines the default channel used in the bundle.
# Add a new line here if you would like to change its default config. (E.g DEFAULT_CHANNEL = "stable")
# To re-generate a bundle for any other default channel without changing the default setup, you can:
# - use the DEFAULT_CHANNEL as arg of the bundle target (e.g make bundle DEFAULT_CHANNEL=stable)
# - use environment variables to overwrite this value (e.g export DEFAULT_CHANNEL="stable")
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# IMAGE_TAG_BASE defines the docker.io namespace and part of the image name for remote images.
IMAGE_TAG_BASE ?= quay-its.epfl.ch/svc0041/nfs-subdir-ext-provisioner-olm

# BUNDLE_IMG defines the image:tag used for the bundle.
# You can use it as an arg. (E.g make bundle-build BUNDLE_IMG=<some-registry>/<project-name-bundle>:<tag>)
BUNDLE_IMG ?= $(IMAGE_TAG_BASE)-bundle:v$(VERSION)

# BUNDLE_GEN_FLAGS are the flags passed to the operator-sdk generate bundle command
BUNDLE_GEN_FLAGS ?= --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

# USE_IMAGE_DIGESTS defines if images are resolved via tags or digests
# You can enable this value if you would like to use SHA Based Digests
# To enable set flag to true
USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

# Image URL to use all building/pushing image targets
IMG ?= $(IMAGE_TAG_BASE):v$(VERSION)

CONTROLLER_IMG ?= $(shell echo $(IMG) \
  | sed 's|quay-its.epfl.ch|anonymous.apps.t-ocp-its-01.xaas.epfl.ch|')

.PHONY: all
all: docker-build

#############################################################################
##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: run
run: helm-operator ## Run against the configured Kubernetes cluster in ~/.kube/config
	$(HELM_OPERATOR) run


#############################################################################
##@ Deploying from source (for testing)

.PHONY: install
install: ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	kubectl apply -f nfssubdirprovisioner_crd.yaml

.PHONY: uninstall
uninstall: ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	kubectl delete -f nfssubdirprovisioner_crd.yaml

_subst_manager_image := sed -e 's|^\#\( *image: \)controller:latest|\1 $(CONTROLLER_IMG)|'

.PHONY: deploy
deploy: ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	for rbac in rbac/*; do  kubectl apply -f $$rbac; done
	$(_subst_manager_image) < deploy/manager.yaml | \
	  kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	for rbac in rbac/*; do kubectl delete -f $$rbac; done
	kubectl delete -f deploy/manager.yaml

#############################################################################
##@ Building the main image

.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	docker build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> than the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: test ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- docker buildx create --name project-v3-builder
	docker buildx use project-v3-builder
	- docker buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- docker buildx rm project-v3-builder
	rm Dockerfile.cross

###########################################################################
##@ Building the bundle image
#
# The bundle image only contains YAML files and Docker label metadata.
# It has no binaries, and no container or pod ever gets created out of
# it. The bundle image is kept small enough to be swallowed whole by
# e.g. `opm render`, (a golang-library equivalent of) which will be
# run by the OLM operator. This is the reason why be build and push it
# separately from the main image (the one with the controller binary
# inside); even though technically, nothing would prevent us from
# merging them.

.PHONY: bundle-build
bundle-build: bundle ## Generate bundle manifests and metadata, validate generated files
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	docker push $(BUNDLE_IMG)

bundle: \
    bundle/manifests/clusterserviceversion.yaml \
    bundle/manifests/nfssubdirprovisioner_crd.yaml \
    bundle/metadata/annotations.yaml
	operator-sdk bundle validate $@
	touch $@

# The main task here is to preprocess the ClusterServiceVersion object
# using the `operator-sdk bundle generate` command; fleshing out its
# CRD(s), RBAC, `alm-examples` annotation, and more. The officially
# supported project layout invokes that task out of a Makefile (like
# we do); yet `operator-sdk bundle generate` styles itself as an
# idempotent command i.e. one that both reads and writes from the same
# file? 🤷 Here, we make sure to put that stuff in a temporary
# directory, so as to clearly segregate inputs from outputs.
bundle/manifests/clusterserviceversion.yaml: \
  deploy/manager.yaml \
  nfssubdirprovisioner_crd.yaml \
  $(wildcard rbac/*.yaml) \
  nfssubdirprovisioner_example.yaml \
  clusterserviceversion-tmpl.yaml
	install -d $(dir $@)
	@rm -rf bundle/csv-tmp; mkdir -p bundle/csv-tmp
	( for src in $^; do \
	    cat $$src | case "$$src" in \
	      deploy/manager.yaml) $(_subst_manager_image) ;; \
	      *) cat ;; \
	    esac ; \
	    echo; echo "---"; \
	  done ) | \
	  (cd bundle/csv-tmp; operator-sdk generate bundle --package nfs-subdir-external-provisioner-olm $(BUNDLE_GEN_FLAGS) --verbose --output-dir .)
	sed 's|project_layout: unknown|project_layout: helm.sdk.operatorframework.io/v1|' < $$(find bundle/csv-tmp/manifests/ -name *.clusterserviceversion.yaml) > $@
	rm -rf bundle/csv-tmp

bundle/manifests/nfssubdirprovisioner_crd.yaml: nfssubdirprovisioner_crd.yaml
	install -d $(dir $@)
	cp $< $@

bundle/metadata/annotations.yaml: bundle.Dockerfile
	install -d $(dir $@)
	( echo "annotations:" ; \
	  sed -ne 's/^LABEL \(.*\)=\(.*\)$$/  \1: \2/p' < $< ) > $@

#############################################################################
##@ Downloading helper binaries

OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')

.PHONY: helm-operator
HELM_OPERATOR = $(shell pwd)/bin/helm-operator
helm-operator: ## Download helm-operator locally if necessary, preferring the $(pwd)/bin path over global if both exist.
ifeq (,$(wildcard $(HELM_OPERATOR)))
ifeq (,$(shell which helm-operator 2>/dev/null))
	@{ \
	set -e ;\
	mkdir -p $(dir $(HELM_OPERATOR)) ;\
	curl -sSLo $(HELM_OPERATOR) https://github.com/operator-framework/operator-sdk/releases/download/v1.28.0/helm-operator_$(OS)_$(ARCH) ;\
	chmod +x $(HELM_OPERATOR) ;\
	}
else
HELM_OPERATOR = $(shell which helm-operator)
endif
endif

##@ Cleanup

.PHONY: clean
clean: ## Remove intermediate files and built Docker images
	rm -rf bundle
	docker rmi $(IMG) $(BUNDLE_IMG) || true
