# Build and tag Multica executor images — single source:
# deploy/executor/Dockerfile.agent, targets base / claude / dsh / full.
#
# build-<variant> chains on the base image tag produced by build-base
# (--build-arg BASE_IMAGE=…), so the multi-GB base layer is built once and
# each variant is a thin CLI-install layer. Set BUILD_BASE= to skip reuse and
# build variants from the in-file base stage instead.
#
# Run from anywhere in the repo:
#   make -f deploy/executor/Makefile build-all
#   make -f deploy/executor/Makefile build-claude TAG=local-test
#   make -f deploy/executor/Makefile build-all TAG=v0.4.41 MULTICA_TAG=v0.4.41
#   make -f deploy/executor/Makefile build-full BUILD_BASE=
#
# 注意：claude/full target 需要能访问 claude.ai（native installer 下载源）；
# 国内网络被封时本地只能构建 base/dsh，claude/full 走 CI。

export DOCKER_BUILDKIT := 1
export BUILDKIT_PROGRESS := plain

IMAGE          ?= ghcr.io/utter-office/multica-executor
TAG            ?= utter-main
MULTICA_IMAGE  ?= ghcr.io/utter-office/multica-backend
MULTICA_TAG    ?= utter-main
# Base tag variants chain on; empty = build from the Dockerfile's base stage.
BUILD_BASE     ?= $(IMAGE)-base:$(TAG)
# Claude Code version for the native installer (positional arg of install.sh).
CLAUDE_CODE_VERSION ?= latest

# The Dockerfile COPYs deploy/executor/entrypoint.sh, so the build context
# must be the repo root, not deploy/executor. Resolve it relative to this
# Makefile so `make -f deploy/executor/Makefile` works from any directory.
REPO_ROOT := $(shell cd $(dir $(lastword $(MAKEFILE_LIST))) && cd ../.. && pwd)
DOCKERFILE := $(REPO_ROOT)/deploy/executor/Dockerfile.agent
CONTEXT    := $(REPO_ROOT)

.DEFAULT_GOAL := help

.PHONY: help build-base build-claude build-dsh build-full build-all
.PHONY: tag-claude tag-dsh tag-full

help:            ## list targets and variables
	@echo 'Usage: make -f deploy/executor/Makefile <target> [VAR=value ...]'
	@echo
	@echo 'Targets:'
	@echo '  build-base    build $(IMAGE)-base:$(TAG)      (multica CLI + toolchains + entrypoint)'
	@echo '  build-claude  build $(IMAGE)-claude:$(TAG)    (base + Claude Code)'
	@echo '  build-dsh     build $(IMAGE)-dsh:$(TAG)       (base + DeepSeek Harness)'
	@echo '  build-full    build $(IMAGE):$(TAG)           (base + claude + dsh; compose/SIT default)'
	@echo '  build-all     build-base + the three variants'
	@echo '  tag-claude / tag-dsh / tag-full   aliases of the build-* targets'
	@echo
	@echo 'Variables (defaults in parentheses):'
	@echo '  IMAGE         image name prefix, variant suffix appended ($(IMAGE))'
	@echo '  TAG           image tag ($(TAG))'
	@echo '  MULTICA_IMAGE backend image the multica CLI is copied from ($(MULTICA_IMAGE))'
	@echo '  MULTICA_TAG   backend tag to match — same version as the server ($(MULTICA_TAG))'
	@echo '  BUILD_BASE    base tag variants chain on ($(BUILD_BASE)); empty = in-file base stage'
	@echo '  CLAUDE_CODE_VERSION  claude version for the native installer ($(CLAUDE_CODE_VERSION))'

build-all: build-base build-claude build-dsh build-full

build-base:
	docker build -f $(DOCKERFILE) --target base \
		--pull \
		--build-arg MULTICA_IMAGE=$(MULTICA_IMAGE) \
		--build-arg MULTICA_TAG=$(MULTICA_TAG) \
		-t $(IMAGE)-base:$(TAG) $(CONTEXT)

VARIANT_ARGS := \
	--pull \
	--build-arg MULTICA_IMAGE=$(MULTICA_IMAGE) \
	--build-arg MULTICA_TAG=$(MULTICA_TAG) \
	--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION)
ifdef BUILD_BASE
VARIANT_ARGS += --build-arg BASE_IMAGE=$(BUILD_BASE)
endif

build-claude: build-base
	docker build -f $(DOCKERFILE) --target claude $(VARIANT_ARGS) -t $(IMAGE)-claude:$(TAG) $(CONTEXT)

build-dsh: build-base
	docker build -f $(DOCKERFILE) --target dsh $(VARIANT_ARGS) -t $(IMAGE)-dsh:$(TAG) $(CONTEXT)

build-full: build-base
	docker build -f $(DOCKERFILE) --target full $(VARIANT_ARGS) -t $(IMAGE):$(TAG) $(CONTEXT)

# Alias targets (same as build-*)
tag-claude: build-claude
tag-dsh: build-dsh
tag-full: build-full
