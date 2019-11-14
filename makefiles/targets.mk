# Copyright (c) 2018-2019 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

.PHONY: deps-common sanity-checks go-checks nat-libs libminiupnpc.a libnatpmp.a clean-common mrproper github-ssh build-nim update-common update-remote status ntags ctags fetch-dlls

#- when the special ".SILENT" target is present, all recipes are silenced as if they all had a "@" prefix
#- by setting SILENT_TARGET_PREFIX to a non-empty value, the name of this target becomes meaningless to `make`
#- idea stolen from http://make.mad-scientist.net/managing-recipe-echoing/
$(SILENT_TARGET_PREFIX).SILENT:

# dir
build:
	mkdir $@

sanity-checks:
	which $(CC) &>/dev/null || { echo "C compiler ($(CC)) not installed. Aborting."; exit 1; }

MIN_GO_VER := 1.12
DISABLE_GO_CHECKS := 0
go-checks:
ifeq ($(DISABLE_GO_CHECKS), 0)
	which go &>/dev/null || { echo "Go compiler not installed. Aborting."; exit 1; }
	GO_VER="$$(go version | sed -E 's/^.*go([0-9.]+).*$$/\1/')"; \
	       [[ $$(echo -e "$${GO_VER}\n$(MIN_GO_VER)" | sort -t '.' -k 1,1 -k 2,2 -g | head -n 1) == "$(MIN_GO_VER)" ]] || \
	       { echo "Minimum Go compiler version required: $(MIN_GO_VER). Version available: $$GO_VER. Aborting."; exit 1; }
endif

#- runs only the first time and after `make update`, so have "normal"
#  (timestamp-checked) prerequisites here
#- $(NIM_BINARY) is both a proxy for submodules having been initialised
#  and a check for the actual compiler build
deps-common: sanity-checks $(NIM_BINARY) $(NIMBLE_DIR) nat-libs

#- conditionally re-builds the Nim compiler (not usually needed, because `make update` calls this rule; delete $(NIM_BINARY) to force it)
#- allows parallel building with the '+' prefix
#- forces a rebuild of csources, Nimble and a complete compiler rebuild, in case we're called after pulling a new Nim version
#- uses our Git submodules for csources and Nimble (Git doesn't let us place them in another submodule)
#- build_all.sh looks at the parent dir to decide whether to copy the resulting csources binary there,
#  but this is broken when using symlinks, so build csources separately (we get parallel compiling as a bonus)
#- Windows is a special case, as usual
#- macOS is also a special case, with its "ln" not supporting "-r"
#- the AppVeyor 32-build is done on a 64-bit image, so we need to override the architecture detection with ARCH_OVERRIDE
build-nim: | sanity-checks
	+ NIM_BUILD_MSG="$(BUILD_MSG) Nim compiler" \
		V=$(V) \
		CC=$(CC) \
		MAKE=$(MAKE) \
		ARCH_OVERRIDE=$(ARCH_OVERRIDE) \
		"$(CURDIR)/$(BUILD_SYSTEM_DIR)/scripts/build_nim.sh" "$(NIM_DIR)" ../Nim-csources ../nimble "$(CI_CACHE)"

#- "go.mod" can be changed by the Go compiler, preventing a checkout
#- in case of submodule URL changes, propagates that change in the parent repo's .git directory
#- initialises and updates the Git submodules, avoiding automated LFS downloads
#- manages the AppVeyor cache of Nim compiler binaries
#- deletes the ".nimble" dir to force the execution of the "deps" target
#- allows parallel building with the '+' prefix
#- rebuilds the Nim compiler if the corresponding submodule is updated
$(NIM_BINARY) update-common: | sanity-checks
	- [[ -e vendor/go/src/github.com/libp2p/go-libp2p-daemon ]] && \
		cd vendor/go/src/github.com/libp2p/go-libp2p-daemon && \
		git reset --hard -q HEAD
	git submodule sync --quiet --recursive
	export GIT_LFS_SKIP_SMUDGE=1; git submodule update --init --recursive
	rm -rf $(NIMBLE_DIR)
	+ $(MAKE) build-nim

# don't use this target, or you risk updating dependency repos that are not ready to be used in Nimbus
update-remote:
	git submodule update --remote

nat-libs: | libminiupnpc.a libnatpmp.a

libminiupnpc.a: | sanity-checks
ifeq ($(OS), Windows_NT)
	+ [ -e vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc/$@ ] || \
		$(MAKE) -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc -f Makefile.mingw CC=gcc init $@ $(HANDLE_OUTPUT)
else
	+ $(MAKE) -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc $@ $(HANDLE_OUTPUT)
endif

libnatpmp.a: | sanity-checks
ifeq ($(OS), Windows_NT)
	+ $(MAKE) -C vendor/nim-nat-traversal/vendor/libnatpmp CC=gcc CFLAGS="-Wall -Os -DWIN32 -DNATPMP_STATICLIB -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" $@ $(HANDLE_OUTPUT)
else
	+ $(MAKE) CFLAGS="-Wall -Os -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" -C vendor/nim-nat-traversal/vendor/libnatpmp $@ $(HANDLE_OUTPUT)
endif

#- depends on Git submodules being initialised
#- fakes a Nimble package repository with the minimum info needed by the Nim compiler
#  for runtime path (i.e.: the second line in $(NIMBLE_DIR)/pkgs/*/*.nimble-link)
$(NIMBLE_DIR): | $(NIM_BINARY)
	mkdir -p $(NIMBLE_DIR)/pkgs
	NIMBLE_DIR="$(CURDIR)/$(NIMBLE_DIR)" PWD_CMD="$(PWD)" \
		git submodule foreach --quiet '$(CURDIR)/$(BUILD_SYSTEM_DIR)/scripts/create_nimble_link.sh "$$sm_path"'

clean-common:
	rm -rf build/{*.exe,*.so,*.so.0} vendor/go/bin $(NIMBLE_DIR) $(NIM_BINARY) $(NIM_DIR)/bin/timestamp $(NIM_DIR)/nimcache nimcache
	+ [[ -e vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc ]] && $(MAKE) -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc clean $(HANDLE_OUTPUT) || true
	+ [[ -e vendor/nim-nat-traversal/vendor/libnatpmp ]] && $(MAKE) -C vendor/nim-nat-traversal/vendor/libnatpmp clean $(HANDLE_OUTPUT) || true

# dangerous cleaning, because you may have not-yet-pushed branches and commits in those vendor repos you're about to delete
mrproper: clean
	rm -rf vendor

# for when you want to use SSH keys with GitHub
github-ssh:
	git config url."git@github.com:".insteadOf "https://github.com/"
	git submodule foreach --recursive 'git config url."git@github.com:".insteadOf "https://github.com/"'

# runs `git status` in all Git repos
status: | $(REPOS)
	$(eval CMD := $(GIT_STATUS))
	$(RUN_CMD_IN_ALL_REPOS)

# https://bitbucket.org/nimcontrib/ntags/ - currently fails with "out of memory"
ntags:
	ntags -R .

#- a few files need to be excluded because they trigger an infinite loop in https://github.com/universal-ctags/ctags
#- limiting it to Nim files, because there are a lot of C files we don't care about
ctags:
	ctags -R --verbose=yes \
	--langdef=nim \
	--langmap=nim:.nim \
	--regex-nim='/(\w+)\*?\s*=\s*object/\1/c,class/' \
	--regex-nim='/(\w+)\*?\s*=\s*enum/\1/e,enum/' \
	--regex-nim='/(\w+)\*?\s*=\s*tuple/\1/t,tuple/' \
	--regex-nim='/(\w+)\*?\s*=\s*range/\1/s,subrange/' \
	--regex-nim='/(\w+)\*?\s*=\s*proc/\1/p,proctype/' \
	--regex-nim='/proc\s+(\w+)/\1/f,procedure/' \
	--regex-nim='/func\s+(\w+)/\1/f,procedure/' \
	--regex-nim='/method\s+(\w+)/\1/m,method/' \
	--regex-nim='/proc\s+`([^`]+)`/\1/o,operator/' \
	--regex-nim='/template\s+(\w+)/\1/u,template/' \
	--regex-nim='/macro\s+(\w+)/\1/v,macro/' \
	--languages=nim \
	--exclude=nimcache \
	--exclude='*/Nim/tinyc' \
	--exclude='*/Nim/tests' \
	--exclude='*/Nim/csources' \
	--exclude=nimbus/genesis_alloc.nim \
	--exclude=$(REPOS_DIR)/nim-bncurve/tests/tvectors.nim \
	.

############################
# Windows-specific section #
############################

ifeq ($(OS), Windows_NT)
  # no tabs allowed for indentation here

  # the AppVeyor 32-build is done on a 64-bit image, so we need to override the architecture detection
  ifeq ($(ARCH_OVERRIDE), x86)
    ARCH := x86
  else
    ifeq ($(PROCESSOR_ARCHITEW6432), AMD64)
      ARCH := x64
    else
      ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
        ARCH := x64
      endif
      ifeq ($(PROCESSOR_ARCHITECTURE), x86)
        ARCH := x86
      endif
    endif
  endif

  ifeq ($(ARCH), x86)
    ROCKSDB_DIR := x86
  endif
  ifeq ($(ARCH), x64)
    ROCKSDB_DIR := x64
  endif

  ROCKSDB_ARCHIVE := nimbus-deps.zip
  ROCKSDB_URL := https://github.com/status-im/nimbus-deps/releases/download/nimbus-deps/$(ROCKSDB_ARCHIVE)
  CURL := curl -O -L
  UNZIP := unzip -o

#- back to tabs
#- copied from .appveyor.yml
#- this is why we can't delete the whole "build" dir in the "clean" target
fetch-dlls: | build
	cd build && \
		$(CURL) $(ROCKSDB_URL) && \
		$(CURL) https://nim-lang.org/download/dlls.zip && \
		$(UNZIP) $(ROCKSDB_ARCHIVE) && \
		cp -a $(ROCKSDB_DIR)/*.dll . && \
		$(UNZIP) dlls.zip
endif

