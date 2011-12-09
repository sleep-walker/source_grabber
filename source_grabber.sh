#!/bin/bash
####
#
# Source Grabber
# --------------
#
# Tool for easy updating packages fro VCS as SVN or GIT.
#
# Author: Tomas Cech <sleep_walker@suse.cz>
################################################################################

CONF_PATH=config.d

# read basic configuration
source "$CONF_PATH/base"

###
# generic functionality
#######################

GREEN="\033[01;32m"
YELLOW="\033[01;33m"
RED="\033[01;31m"
NONE="\033[00m"

colorize() {
	local FIRST="$1"
	shift
	echo -e "$SPACES${COLOR}$FIRST${NONE}$*"
}

inform() {
	local COLOR="$GREEN"
	colorize "$@"
}

warn() {
	local COLOR="$YELLOW"
	colorize "$@"
}

error() {
	local COLOR="$RED"
	colorize "$@"
}

report_on_error() {
	OUTPUT="$("$@" 2>&1)"
	if [ $? -ne 0 ]; then
		error "Failed command: " "$@"
		echo "$OUTPUT"
		false
	fi
}
# for each repository (or for one specified)
#   1] source repository configuration file
#   2] update source repository
#   3] for every package in the repository
#      a] update local copy of OBS package
#      b] detect, if there is change since the last packaged state, if not, go to next package
#      c] call `make dist-bzip2'
#      d] copy result tarball to OBS package repository
#      e] update spec file (and note current repository version)
#      f] add record to .changes file
#      g] commit changes



update_git() {
	inform "  * Updating GIT..."
	if [ -d "$SRC_DIR" ]; then
		# we already downloaded repository - update only
		cd "$SRC_DIR"
		report_on_error git reset --hard
		report_on_error git pull --progress
	else
		# we don't have sources yet - clone repository first
		cd "${SRC_DIR%/*}"
		report_on_error git clone "$SRC_URL"
	fi
	NEW_REVISION="$(git log --format=oneline -n 1 | cut -d\  -f1)"
}

update_svn() {
	inform "  * Updating SVN..."
	if [ -d "$SRC_DIR" ]; then
		# we already downloaded repository - update only
		cd "$SRC_DIR"
		report_on_error svn up
	else
		# we don't have sources yet - checkout repository first
		cd "${SRC_DIR%/*}"
		# FIXME: this is obviously wrong - I have to use SVN URL here...
		report_on_error svn co "${SRC_DIR##*/}"
		cd "$SRC_DIR"
	fi
	NEW_REVISION="$(svn info | sed -n 's/^Revision: \([0-9]\+\)$/\1/p')"
	# FIXME: Possible shorter way, but it may not be needed
	# NEW_REVISION="$(sed -n 4p .svn/entries)"
}

update_packages_in_repository() {
	inform "Update packages in repository: " "$1"
	# clear _all_ used variables
	unset SRC_DIR SRC_REL_DIR OBS_PRJ OBS_PRJ_DIR OBS_PKG OLD_REVISION NEW_REVISION

	# source repository configuration
	if [ -f "$1" ]; then
		source "$1"
	elif [ -f "$CONF_PATH/$1.repo" ]; then
		source "$CONF_PATH/$1.repo"
	else
		error "Cannot find '$1' repository definition"
		return 1
	fi

}

update_all() {
	for REPO in "$CONF_PATH"/*.repo; do
		update_packages_in_repository "$REPO"
	done
}

