DART_LIB_FILES_ALL := $(shell find lib -name *.dart)
DART_TEST_FILES_ALL := $(shell find test -name *.dart)
DART_TEST_FILES := $(shell find test -name *.dart ! -name *.part.dart)

# Add Dart SDK to path.
PATH := $(shell jiri profile env --profiles=v23:dart DART_SDK=)/bin:$(PATH)

# Point to where FLUTTER_ROOT lives.
export FLUTTER_ROOT := $(JIRI_ROOT)/flutter

# This section is used to setup the environment for running with mojo_shell.
ifdef ANDROID
	MOJO_DEVTOOLS := $(shell jiri profile env --profiles=v23:mojo --target=arm-android MOJO_DEVTOOLS=)
	MOJO_SHELL := $(shell jiri profile env --profiles=v23:mojo --target=arm-android MOJO_SHELL=)
endif
SHELL := /bin/bash -euo pipefail

# Flags for Syncbase service running as Mojo service.
SYNCBASE_FLAGS := --v=0

ifdef ANDROID
	# Parse the adb devices output to obtain the correct device id.
	# sed takes out the ANDROID_PLUS_ONE'th row of the output
	# awk takes just the first bit of the line (before whitespace).
	ANDROID_PLUS_ONE := $(shell echo $(ANDROID) \+ 1 | bc)
	DEVICE_ID := $(shell adb devices | sed -n $(ANDROID_PLUS_ONE)p | awk '{ print $$1; }')
endif

# The default mount table location. Note: May not always exist.
MOUNTTABLE := /192.168.86.254:8101

# If defined, use the proxy and global mount table.
ifdef GLOBAL
	PROXY_FLAG := --v23.proxy=/ns.dev.v.io:8101/proxy
	MOUNTTABLE := /ns.dev.v.io:8101/tmp/croupier
endif

ifdef ANDROID
	MOJO_ANDROID_FLAGS := --android
	SYNCBASE_MOJO_BIN_DIR := packages/syncbase/mojo_services/android
	DISCOVERY_MOJO_BIN_DIR := packages/v23discovery/mojo_services/arm_android

	# Name to mount under.
	SYNCBASE_NAME_FLAG := --name=$(MOUNTTABLE)/croupier-$(DEVICE_ID)
	SYNCBASE_FLAGS += $(SYNCBASE_NAME_FLAG)

	APP_HOME_DIR = /data/data/org.chromium.mojo.shell/app_home
	ANDROID_CREDS_DIR := /sdcard/v23creds

	SYNCBASE_FLAGS += --logtostderr=true \
		--root-dir=$(APP_HOME_DIR)/syncbase_data \
		--v23.credentials=$(ANDROID_CREDS_DIR) \
		$(PROXY_FLAG)

else
	SYNCBASE_MOJO_BIN_DIR := packages/syncbase/mojo_services/linux_amd64
	DISCOVERY_MOJO_BIN_DIR := packages/v23discovery/mojo_services/linux_amd64
	SYNCBASE_FLAGS += --root-dir=$(PWD)/tmp/syncbase_data --v23.credentials=$(PWD)/creds
endif

# If this is not the first mojo shell, then you must reuse the dev servers
# to avoid a "port in use" error.
ifneq ($(shell fuser 31841/tcp),)
	REUSE_FLAG := --reuse-servers
endif

# We should consider combining these URLs and hosting our *.mojo files.
# https://github.com/vanadium/issues/issues/834
export SYNCBASE_SERVER_URL := https://mojo.v.io/syncbase_server.mojo
export DISCOVERY_SERVER_URL := https://mojo2.v.io/discovery.mojo
MOJO_SHELL_FLAGS := --enable-multiprocess \
	--map-origin="https://mojo2.v.io=$(DISCOVERY_MOJO_BIN_DIR)" \
	--map-origin="https://mojo.v.io=$(SYNCBASE_MOJO_BIN_DIR)" --args-for="$(SYNCBASE_SERVER_URL) $(SYNCBASE_FLAGS)"

ifdef ANDROID
	TARGET_DEVICE_FLAG +=  --target-device $(DEVICE_ID)
endif

# Runs a sky app.
# $1 is location of flx file.
define RUN_SKY_APP
	pub run flutter_tools -v run_mojo \
	--app $1 \
	$(MOJO_ANDROID_FLAGS) \
	--devtools-path $(MOJO_DEVTOOLS)/mojo_run \
	--checked \
	--mojo-debug \
	-- $(TARGET_DEVICE_FLAG) \
	$(MOJO_SHELL_FLAGS) \
	$(REUSE_FLAG) \
	--no-config-file
endef

.DELETE_ON_ERROR:

# Get the packages used by the dart project, according to pubspec.yaml
# Can also use `pub get`, but Sublime occasionally reverts me to an ealier version.
# Only `pub upgrade` can escape such a thing.
packages: pubspec.yaml
	cd $(JIRI_ROOT)/flutter && git show
	cd $(JIRI_ROOT)/flutter && bin/flutter --version
	pub upgrade

# Builds mounttabled and principal.
bin: | env-check
	jiri go build -a -o $@/mounttabled v.io/x/ref/services/mounttable/mounttabled
	jiri go build -a -o $@/principal v.io/x/ref/cmd/principal
	touch $@

.PHONY: creds
creds: | bin
	./bin/principal seekblessings --v23.credentials creds
	touch $@

.PHONY: dartfmt
dartfmt:
	dartfmt -w $(DART_LIB_FILES_ALL) $(DART_TEST_FILES_ALL)

.PHONY: lint
lint: packages
	dartanalyzer lib/main.dart | grep -vE "(\[warning\]\ The\ imported\ libraries|TODO\(alexfandrianto\):)"
	dartanalyzer $(DART_TEST_FILES) | grep -vE "(\[warning\]\ The\ imported\ libraries|TODO\(alexfandrianto\):)"

.PHONY: build
build: croupier.flx

croupier.flx: packages $(DART_LIB_FILES_ALL)
	pub run flutter_tools -v build flx --manifest manifest.yaml --output-file $@

SETTINGS_FILE := /sdcard/croupier_settings.json
SETTINGS_JSON := {\"deviceID\": \"$(DEVICE_ID)\", \"mounttable\": \"$(MOUNTTABLE)\"}
.PHONY: push-settings
push-settings:
ifdef ANDROID
	adb -s $(DEVICE_ID) shell 'echo $(SETTINGS_JSON) > $(SETTINGS_FILE)'
endif

# Starts the app on the specified ANDROID device.
# Don't forget to make creds first if they are not present.
.PHONY: start
start: croupier.flx install-shell env-check packages push-settings
ifdef ANDROID
	# Make creds dir if it does not exist.
	mkdir -p creds
	adb -s $(DEVICE_ID) push -p $(PWD)/creds $(ANDROID_CREDS_DIR)
endif
	$(call RUN_SKY_APP,$<)

# Occasionally, mojo will leave some dev servers running on port 31841, which
# prevents proper restarts. This rule cleans up the offending process.
.PHONY: stop-mojo
stop-mojo:
	-fuser -k 31841/tcp

APP_ICON := $(PWD)/images/croupier_icon.png
APP_FLX_FILE := $(PWD)/croupier.flx
SYNCBASE_MOJO_DIR := $(PWD)/packages/syncbase/mojo_services
DISCOVERY_MOJO_DIR := $(PWD)/packages/v23discovery/mojo_services
GS_BUCKET_PATH := gs://mojo_services

# TODO(alexfandrianto): Group services into same bucket subdirectory.
# See https://github.com/vanadium/issues/issues/1156
# Note: The deploy assumes that the media_service.mojo file, which is used for
# audio, is already present at $(GS_BUCKET_PATH)/media_service.mojo.
# This file is developed separately from Croupier.
.PHONY: deploy
deploy: build
	gsutil cp $(APP_ICON) $(GS_BUCKET_PATH)/croupier
	gsutil cp $(APP_FLX_FILE) $(GS_BUCKET_PATH)/croupier
	gsutil cp $(FLUTTER_ROOT)/bin/cache/artifacts/engine/android-arm/flutter.mojo $(GS_BUCKET_PATH)/flutter
	gsutil cp -r $(SYNCBASE_MOJO_DIR) $(GS_BUCKET_PATH)/syncbase
	gsutil cp -r $(DISCOVERY_MOJO_DIR) $(GS_BUCKET_PATH)/v23discovery
	gsutil -m acl set -R -a public-read $(GS_BUCKET_PATH)/croupier
	gsutil -m acl set -R -a public-read $(GS_BUCKET_PATH)/flutter
	gsutil -m acl set -R -a public-read $(GS_BUCKET_PATH)/syncbase
	gsutil -m acl set -R -a public-read $(GS_BUCKET_PATH)/v23discovery

CROUPIER_SHORTCUT_NAME := Croupier
CROUPIER_URL := mojo://storage.googleapis.com/mojo_services/croupier/croupier.flx
CROUPIER_URL_TO_ICON := https://storage.googleapis.com/mojo_services/croupier/croupier_icon.png
MOJO_SHELL_CMD_PATH := /data/local/tmp/org.chromium.mojo.shell.cmd

# Creates a shortcut on the phone that runs the hosted version of croupier.flx
# Does nothing if ANDROID is not defined.
define GENERATE_SHORTCUT_FILE
	sed -e "s;%DEVICE_ID%;$1;g" -e "s;%SYNCBASE_NAME_FLAG%;$2;g" -e "s;%PROXY_FLAG%;$3;g" \
	shortcut_template > shortcut_commands
endef

shortcut: install-shell env-check push-settings
ifdef ANDROID
	# Create the shortcut file.
	$(call GENERATE_SHORTCUT_FILE,$(DEVICE_ID),$(SYNCBASE_NAME_FLAG))

	# TODO(alexfandrianto): Mojo Shell only allows a single default command. This may prove problematic.
	adb -s $(DEVICE_ID) push -p shortcut_commands $(MOJO_SHELL_CMD_PATH)
	adb -s $(DEVICE_ID) shell chmod 555 $(MOJO_SHELL_CMD_PATH)

	# TODO(alexfandrianto): Put this in Mojo shared instead.
	$(MOJO_DIR)/src/mojo/devtools/common/mojo_run --android $(TARGET_DEVICE_FLAG) "mojo:shortcut $(CROUPIER_SHORTCUT_NAME) $(CROUPIER_URL) $(CROUPIER_URL_TO_ICON)"
endif

# Removes the shortcut data from Mojo shell.
# TODO(alexfandrianto): Can we remove the shortcut icon?
shortcut-remove: env-check
ifdef ANDROID
	adb -s $(DEVICE_ID) shell rm -f $(MOJO_SHELL_CMD_PATH)
endif

.PHONY: install-shell
install-shell: shortcut-remove
ifdef ANDROID
	adb -s $(DEVICE_ID) install $(MOJO_SHELL)
endif

.PHONY: uninstall-shell
uninstall-shell: clear-shortcut
ifdef ANDROID
	adb -s $(DEVICE_ID) uninstall org.chromium.mojo.shell
endif

.PHONY: mock
mock:
	mv lib/src/syncbase/log_writer.dart lib/src/syncbase/log_writer.dart.backup
	mv lib/src/syncbase/settings_manager.dart lib/src/syncbase/settings_manager.dart.backup
	mv lib/src/syncbase/util.dart lib/src/syncbase/util.dart.backup
	cp lib/src/mocks/log_writer.dart lib/src/syncbase/
	cp lib/src/mocks/settings_manager.dart lib/src/syncbase/
	cp lib/src/mocks/util.dart lib/src/syncbase/

.PHONY: unmock
unmock:
	mv lib/src/syncbase/log_writer.dart.backup lib/src/syncbase/log_writer.dart
	mv lib/src/syncbase/settings_manager.dart.backup lib/src/syncbase/settings_manager.dart
	mv lib/src/syncbase/util.dart.backup lib/src/syncbase/util.dart

.PHONY: env-check
env-check:
ifndef MOJO_DIR
	$(error MOJO_DIR is not set)
endif
ifndef JIRI_ROOT
	$(error JIRI_ROOT is not set)
endif

.PHONY: test
test: test-unit

# TODO(alexfandrianto): I split off the syncbase logic from game.dart because it
# would not run in a stand-alone VM. We will need to add mojo_test eventually.
.PHONY: test-unit
test-unit: packages
	# Mock the syncbase implementations and unmock regardless of the test outcome.
	$(MAKE) mock
	pub run test -r expanded $(DART_TEST_FILES) || ($(MAKE) unmock && exit 1)
	$(MAKE) unmock

.PHONY: clean
clean:
ifdef ANDROID
	adb -s $(DEVICE_ID) shell run-as org.chromium.mojo.shell rm -rf $(APP_HOME_DIR)/syncbase_data
	adb -s $(DEVICE_ID) shell rm $(SETTINGS_FILE)
endif
	rm -f croupier.flx snapshot_blob.bin
	rm -rf bin tmp
	rm -rf .packages .pub packages pubspec.lock

.PHONY: clean-creds
clean-creds:
ifdef ANDROID
	# Clean syncbase creds dir.
	adb -s $(DEVICE_ID) shell rm -rf $(ANDROID_CREDS_DIR)
endif
	rm -rf creds

.PHONY: veryclean
veryclean: clean clean-creds
