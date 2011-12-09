#!/bin/bash
####
#
# Source Grabber
# --------------
#
# Tool for easy updating packages fro VCS as SVN or GIT.
#
# Author: Tomas Cech <sleep_walker@suse.cz>
#
#
# It is not meant to be easy to use, but heavily configurable and
# extensible. This script is more like skeleton and shell function
# library. It's up to you to create configuration files for source
# code repositories and use these functions or even redefine them.
#
# Workflow:
# for each repository (or for the one you specified)
#   1] source repository configuration file
#   2] update source repository
#   3] for every package in the repository
#      a] update local copy of OBS package
#      b] detect, if there is change since the last packaged state, if not, go to next package
#      c] call configure and `make dist-bzip2'
#      d] copy result tarball to OBS package repository
#      e] update spec file (and note current repository version)
#      f] add record to .changes file
#      g] commit changes

################################################################################

if [ -d "$HOME/.source_grabber" ]; then
	CONF_PATH="$HOME/.source_grabber"
else
	CONF_PATH=config.d
fi

# read basic configuration
if [ ! -f "$CONF_PATH/base.conf" ]; then
	error "Basic configuration wasn't found."
	#return 1
else
	source "$CONF_PATH/base.conf"
fi

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
		error "Failed command: " 
		for i in "$@"; do
			(
				set -- $i
				[ "$2" ]
			)
			if [ $? -eq 0 ]; then
				echo -n "'$i' "
			else
				echo -n "$i "
			fi
		done
		echo
		echo "$OUTPUT"
		false
	fi
}
find_last_packed_version_svn() {
# I rely on revision previously added to version string in spec file
	OLD_REVISION="$(sed -n 's/^Version:[[:blank:]]\+[0-9.]*\.\([0-9]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
}

find_last_packed_version_git() {
	{
		read OLD_VERSION
		read OLD_REVISION
	} < <(sed -n 's/^Version:[[:blank:]]\+[0-9.]*\.\([0-9]\+\)[[:blank:]]*# git revision: \([0-9a-f]\{32\}\)$/\1\n\2/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec" )
}

need_update_svn() {
	(
		cd "$SRC_DIR"
		# what is last revision in spec file?
		find_last_packed_version_svn
		# were there any changes since that revision?
		[ "$(svn log -r "$OLD_REVISION:HEAD" "$SRC_REL_DIR" 2>/dev/null | wc -l)" -gt 0 ]
	)
}

need_update_git() {
	# what is last revision in spec file?
	find_last_packed_version_git
	if [ -z "$OLD_REVISION" ]; then
		return 0
	fi
	# were there any changes since that revision?
	[ "$(git --git-dir "$SRC_DIR/.git" log --format=oneline "$OLD_REVISION..HEAD" "$SRC_REL_DIR" 2>/dev/null | wc -l)" -gt 0 ]
}

update_spec_svn() {
	sed -i "s@^Version:.*@Version:\t$NEW_VERSION@" "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec"
}

update_spec_git() {
	sed -i "s@^Version:.*@Version:\t$NEW_VERSION # git-revision: $NEW_REVISION@" "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec"
}

autocommit() {
	yes | osc ci -m "$MSG"
}

commit_obs_package() {
	local OLD_PWD="$PWD"
	local MSG="source_grabber autoupdate to revision $NEW_REVISION"
	cd "$OBS_PRJ_DIR/$OBS_PKG"
	if ! report_on_error osc vc -m "$MSG"; then
		warn "    * Error occured during update of .changes file"
	fi
	if ! report_on_error autocommit "$MSG"; then
		error "    * Error occured during commit"
		cd "$OLD_PWD"
		return 1
	fi
	cd "$OLD_PWD"
}

update_tarball() {
# this function will create tarball using `make dist-bzip2'
	local OLD_PWD="$PWD"
	cd "$SRC_DIR/$SRC_REL_DIR"
	# if there is specific action to be made, do it (i.g. autoreconf...)
	if type -t pre_update_tarball_hook &> /dev/null; then
		inform "    * pre_update_tarball_hook defined, calling it"
		report_on_error pre_update_tarball_hook
	fi
	inform "    * running configure"
	if ! report_on_error ./configure; then
		error "Configure phase failed."
		cd "$OLD_PWD"
		return 1
	fi
	if type -t post_configure_hook &> /dev/null; then
		inform "    * post_configure_hook defined, calling it"
	fi
	inform '    * running make dist-bzip2'
	if ! report_on_error make dist-bzip2; then
		error "Make dist phase failed."
		cd "$OLD_PWD"
		return 2
	fi
	RESULT_TARBALL="$(ls "$SRC_REL_DIR"*.tar.bz2 2>/dev/null)"
	if [ -z "$RESULT_TARBALL" ]; then
		error "      - Cannot locate tarball result of \`make dist-bzip2'"
		cd "$OLD_PWD"
		return 1
	fi
	inform "    * result tarball: " "$RESULT_TARBALL"
	inform "    * copying tarball to OBS package repository"
	cp "$SRC_DIR/$SRC_REL_DIR/$RESULT_TARBALL" "$OBS_PRJ_DIR/$OBS_PKG/"
	cd "$OLD_PWD"
}

update_package() {
	# init OBS_PKG and SRC_REL_DIR to values specified in repo configuration or fallback to default
	for i in OBS_PKG SRC_REL_DIR; do
		if eval [ "\"\$$1_$i\"" ]; then
			eval "$i"="\$$1_$i"
		else
			eval "$i"="'$1'"
		fi
	done

	inform "  * Checking if update is needed"
	if ! need_update; then
		inform "    * Tarball is up to date, no update needed."
		return 0
	fi
	inform "    * Tarball needs update."

	inform "  * Updating tarball"
# FIXME: do not generate tarball during development
#	if ! update_tarball; then
#		warn "    - Tarball update failed, aborting this package"
#		return 1
#	fi

	inform "  * Updating spec file"
	if ! new_version; then
		error "    * Cannot recognize new version"
		return 1
	fi

	inform "    * new version: " "$NEW_VERSION"
	if ! update_spec; then
		error "    * Cannot update spec file"
		return 1
	fi

	inform "  * Commiting package"
if [ ! DEVEL ]; then
	if ! commit_obs_package; then
		error "    * Cannot commit package"
		return 1
	fi
fi
}

update_git() {
	inform "  * Updating GIT..."
if [ ! DEVEL ]; then
	if [ -d "$SRC_DIR" ]; then
		# we already downloaded repository - update only
		cd "$SRC_DIR"
		inform "Resetting repository state to upstream"
		report_on_error git reset --hard
		inform "Pulling origin"
		report_on_error git pull
	else
		# we don't have sources yet - clone repository first
		cd "${SRC_DIR%/*}"
		report_on_error git clone "$SRC_URL"
	fi
fi
	NEW_REVISION="$(git --git-dir "$SRC_DIR/.git" log --format=oneline -n 1 | cut -d\  -f1)"
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
		report_on_error svn co "${SRC_URL}"
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

	inform "  * Refresh source code repository"
	if ! update_source_repo; then
		warn "Update repository couldn't be updated, skipping tarball creation"
		return 1
	fi
	for PKG in "${PACKAGES[@]}"; do
		update_package "$PKG"
	done
}

update_all() {
	for REPO in "$CONF_PATH"/*.repo; do
		update_packages_in_repository "$REPO"
	done
}

