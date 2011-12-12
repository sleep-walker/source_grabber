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
# It is not meant to be easy to use, but heavily configurable and extensible.
# This script is more like skeleton and library of shell functions. It's up to
# you to create configuration files for source code repositories and use these
# functions or even redefine them.
#
# Workflow:
# for each repository (or for the one you specified)
#   1] source repository configuration file
#   2] update source repository
#   3] for every package in the repository
#      a] update local copy of OBS package
#      b] detect, if there is change since the last packaged state
#         if not, go to next package
#      c] call configure and `make dist-bzip2'
#      d] copy result tarball to OBS package repository
#      e] update spec file (and note current repository version)
#      f] add record to .changes file
#      g] commit changes
#
################################################################################

if [ -d "$HOME/.source_grabber" ]; then
	CONF_PATH="$HOME/.source_grabber"
else
	CUR_PATH="${BASH_SOURCE[0]}"
	CONF_PATH="${CUR_PATH%/*}"/config.d
fi

# read basic configuration
if [ ! -f "$CONF_PATH/base.conf" ]; then
	error "Basic configuration wasn't found."
	#return 1
else
	source "$CONF_PATH/base.conf"
fi

# clear some session specific variables first
unset SKIP_UPDATE SKIP_COMMIT SKIP_TARBALL DEBUG

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
	if [ "$DEBUG" ]; then
		"$@"
		return
	fi
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

is_defined() {
	type -t "$1" &> /dev/null
}

pkg_specific() {
	if is_defined "${PKG//-/_}_${FUNCNAME[1]}"; then
		inform "      * package specific ${FUNCNAME[1]} found, calling it"
		"${PKG//-/_}_${FUNCNAME[1]}"
		return $?
	else
		return 255
	fi
}

###
# SVN functions
###############

find_last_packed_version_svn() {
# I rely on revision previously added to version string in spec file
	OLD_REVISION="$(sed -n 's/^Version:[[:blank:]]\+[0-9.]*\.\([0-9]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
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

update_spec_svn() {
	sed -i "s@^Version:.*@Version:\t$NEW_VERSION@" "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec"
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
}


###
# GIT functions
###############

find_last_packed_version_git() {
	OLD_REVISION="$(sed -n 's/^# git-revision: \([0-9a-f]\+\)$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
	# TODO: I'm not sure if I need also this one:
	#OLD_VERSION="$(sed -n 's/^Version:[[:blank:]]\+[0-9.]*\.\([0-9]\+\)[[:blank:]]*/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
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

update_spec_git() {
	sed -i "/^# git-revision: .*$/d;s@^Version:.*@# git-revision: $NEW_REVISION\nVersion:\t$NEW_VERSION@" "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec"
	#sed -i "s@^Version:.*@Version:\t$NEW_VERSION@;T;s@# git-revision: .*@# git-revision: $NEW_REVISION@;t;s@^@# git-revision: $NEW_REVISION\n@" "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec"
}

update_git() {
	if [ "$SKIP_UPDATE_SRC" -o "$SKIP_UPDATE" ]; then
		inform "  * Skipping update of GIT repository ${SKIP_UPDATE:+(SKIP_UPDATE)} ${SKIP_UPDATE_SRC:+(SKIP_UPDATE_SRC)}"
	else
		#local OLD_PWD="$PWD"
		inform "  * Updating GIT..."
		if [ -d "$SRC_DIR" ]; then
			# we already downloaded repository - update only
			# cd "$SRC_DIR"
			# FIXME: do I really need to reset?
			#inform "    * Resetting repository state to the last commit"
			#report_on_error git reset --hard
			inform "    * Pulling origin"
			report_on_error git --git-dir="$SRC_DIR/.git" pull
		else
			# we don't have sources yet - clone repository first
			#cd "${SRC_DIR%/*}"
			report_on_error git clone "$SRC_URL" "$SRC_DIR"
		fi
		#cd "$OLD_PWD"
	fi
	NEW_REVISION="$(git --git-dir="$SRC_DIR/.git" log --format=oneline -n 1 | cut -d\  -f1)"
}

###
# OBS functions
###############

autocommit() {
	yes | osc ci -m "$MSG"
}

commit_obs_package() {
	if [ "$SKIP_COMMIT" ]; then
		inform "    * Skipping commit to OBS ${SKIP_COMMIT:+(SKIP_COMMIT)}"
		return 0
	fi
	local OLD_PWD="$PWD"
	local MSG="source_grabber autoupdate to revision $NEW_REVISION"
	cd "$OBS_PRJ_DIR/$OBS_PKG"
	if [ "$RESULT_TARBALL" != "${OLD_TARBALL##*/}" ]; then
		rm "$OLD_TARBALL"
	else
		inform "    * Result tarball is the same as old tarball"
	fi
	report_on_error osc ar || warn "    * Error occured during osc addremove"
	report_on_error osc vc -m "$MSG" || warn "    * Error occured during update of .changes file"
	if ! report_on_error autocommit "$MSG"; then
		error "    * Error occured during commit"
		cd "$OLD_PWD"
		return 1
	fi
	cd "$OLD_PWD"
}

update_obs() {
	if [ "$SKIP_UPDATE_OBS" -o "$SKIP_UPDATE" ]; then
		inform "    * Skipping update of OBS package ${SKIP_UPDATE_OBS:+(SKIP_UPDATE_OBS)} ${SKIP_UPDATE:+(SKIP_UPDATE)}"
		return 0
	fi
	local OLD_PWD="$PWD"
	inform "    * Updating local copy of OBS package"
	if [ -d "$OBS_PRJ_DIR" ]; then
		if [ -d "${OBS_PRJ_DIR%/}/$OBS_PKG" ]; then
			cd "${OBS_PRJ_DIR%/}/$OBS_PKG"
			if report_on_error osc up; then
				cd "$OLD_PWD"
				return
			fi
			error "      * Update of OBS package failed. Trying to rename package dir to $OBS_PKG.old and checkout it again."
			cd ..
			mv "$OBS_PKG" "$OBS_PKG".old
		fi
		cd "$OBS_PRJ_DIR"
		report_on_error osc co "$OBS_PKG"
	else
		cd "${OBS_PRJ_DIR%$OBS_PRJ}"
		report_on_error osc co "$OBS_PRJ" "$OBS_PKG"
	fi
	if [ $? -ne 0 ]; then
		error "      * Unable to update OBS package repository"
		cd "$OLD_PWD"
		return 1
	fi
	cd "$OLD_PWD"
}

###
# Generic skeleton functions
###################

new_version() {
	pkg_specific
	local RES=$?
	if [ $RES -ne 255 ]; then
		return "$RES"
	fi
	# remove tarball suffix
	NEW_VERSION="${RESULT_TARBALL%.tar.bz2}"
	NEW_VERSION="${NEW_VERSION%.tar.gz}"
	# remove package name
	NEW_VERSION="${NEW_VERSION##$PKG-}"
}

find_result_tarball() {
	pkg_specific
	local RES=$?
	if [ $RES -ne 255 ]; then
		return "$RES"
	fi
	RESULT_TARBALL="$(ls "${SRC_REL_DIR##*/}"*.tar.bz2 2>/dev/null)"
	if [ -z "$RESULT_TARBALL" ]; then
		error "      * Cannot locate tarball result"
		return 1
	fi
}

make_tarball() {
# Make bzip2 tarball by calling `make dist-bzip2'
# Current working dir is source code in the repository
	pkg_specific
	local RES=$?
	if [ $RES -ne 255 ]; then
		return "$RES"
	fi
	inform '      * running make dist-bzip2'
	if ! report_on_error make dist-bzip2; then
		error "      * make dist phase failed."
		return 1
	fi
}

run_configure() {
	pkg_specific
	local RES=$?
	if [ $RES -ne 255 ]; then
		return "$RES"
	fi
	inform "      * running configure"
	if ! report_on_error ./configure; then
		error "      * ./configure failed"
		return 1
	fi
}

update_tarball() {
# Create new tarball by calling
#   1] pre_update_tarball_hook if exists (good place for autoreconf)
#   2] run_configure
# this function will create tarball using `make dist-bzip2'
#
	local OLD_PWD="$PWD"
	cd "$SRC_DIR/$SRC_REL_DIR"

	if [ "$SKIP_TARBALL" ]; then
		inform "    * Skipping tarball creation ${SKIP_TARBALL:+(SKIP_TARBALL)}"
	else
		# if there is specific action to be made, do it (i.g. autoreconf...)
		if is_defined pre_update_tarball_hook; then
			inform "      * pre_update_tarball_hook defined, calling it"
			if ! report_on_error pre_update_tarball_hook; then
				error "        * pre_update_tarball_hook failed"
				cd "$OLD_PWD"
				return 1
			fi
		fi

		if ! run_configure; then
			cd "$OLD_PWD"
			return 1
		fi
		if is_defined post_configure_hook; then
			inform "      * post_configure_hook defined, calling it"
		fi

		inform "    * making tarball"
		if ! make_tarball; then
			error "      * making tarball failed"
			cd "$OLD_PWD"
			return 2
		fi
	fi
	# find_result_tarball should set RESULT_TARBALL
	if ! find_result_tarball; then
		cd "$OLD_PWD"
		return 3
	fi
	inform "    * result tarball: " "$RESULT_TARBALL"
	inform "    * copying tarball to OBS package repository"
	cp "$SRC_DIR/$SRC_REL_DIR/$RESULT_TARBALL" "$OBS_PRJ_DIR/$OBS_PKG/"
	cd "$OLD_PWD"
}

find_old_tarball_from_spec() {
	local NAME="$(sed -n 's/^Name:[[:blank:]]\+\([^[:blank:]]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
	local VERSION="$(sed -n 's/^Version:[[:blank:]]\+\([^[:blank:]]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
	local SOURCE="$(sed -n 's/^Source:[[[:blank:]]\+\([^[:blank:]]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
	local FILENAME="$(sed "s/%{\?name}\?/$NAME/;s/%{\?version}\?/$VERSION/" <<< "$SOURCE")"
	OLD_TARBALL="$(ls "$OBS_PRJ_DIR/$OBS_PKG/$FILENAME" 2> /dev/null)"
	if [ ! -f "$OLD_TARBALL" ]; then
		error "    * Cannot find tarball from spec file ($FILENAME)"
		return 1
	fi
	inform "    * Found old tarball from spec file ($FILENAME)"
	return 0
}

find_old_tarball_from_name() {
	local OLD_TARBALLS="$(ls "$OBS_PRJ_DIR/$OBS_PKG/$PKG-"*.tar.{bz2,gz} 2> /dev/null)"
	if [ "$(wc -l <<< "$OLD_TARBALLS")" -ne 1 ]; then
		error "    * There is more than one tarball matching $PKG-*.tar.{bz2,gz} in OBS package directory"
		return 1
	fi
	OLD_TARBALL="$OLD_TARBALLS"
	inform "     * Found old tarball based on name"
	return 0
}

find_some_old_tarball() {
	local OLD_TARBALLS="$(ls "$OBS_PRJ_DIR/$OBS_PKG/"*.tar.{bz2,gz} 2> /dev/null)"
	if [ "$(wc -l <<< "$OLD_TARBALLS")" -ne 1 ]; then
		error "    * There is more than one tarball in OBS package directory"
		return 1
	fi
	OLD_TARBALL="$OLD_TARBALLS"
	inform "     * There is only one tarball"
	return 0
}

find_old_tarball() {
	if find_some_old_tarball; then
		return 0
	elif find_old_tarball_from_name; then
		return 0
	elif find_old_tarball_from_spec; then
		return 0
	fi
	unset OLD_TARBALL
	return 1
}

update_package() {
	inform "  * Updating package: " "$1"
	# init OBS_PKG and SRC_REL_DIR to values specified in repo configuration or fallback to default
	for i in OBS_PKG SRC_REL_DIR; do
		if eval [ "\"\$$1_$i\"" ]; then
			eval "$i"="\$$1_$i"
		else
			eval "$i"="'$1'"
		fi
	done

	if ! update_obs; then
		error "    * Cannot obtain OBS package repository"
		return 1
	fi
	if ! find_old_tarball; then
		error "    * Cannot identify old tarball"
		return 1
	fi
	inform "    * Checking if update is needed"
	if ! need_update; then
		inform "      * Tarball is up to date, no update needed."
		return 0
	fi
	inform "      * Tarball needs update."

	inform "    * Updating tarball"
	if ! update_tarball; then
		error "      * Tarball update failed, aborting this package"
		return 1
	fi

	inform "    * Updating spec file"
	if ! new_version; then
		error "      * Cannot recognize new version"
		return 1
	fi

	inform "      * new version: " "$NEW_VERSION"
	if ! update_spec; then
		error "      * Cannot update spec file"
		return 1
	fi

	inform "    * Commiting package"
	if ! commit_obs_package; then
		error "      * Cannot commit package"
		return 1
	fi
}

update_packages_in_repository() {
	inform "Update packages in repository: " "$1"
	# clear _all_ used variables
	unset SRC_DIR SRC_REL_DIR OBS_PRJ OBS_PRJ_DIR OBS_PKG OLD_REVISION NEW_REVISION NEW_VERSION RESULT_TARBALL

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
	if [ "$SKIP_UPDATE" ]; then
	       inform "    * skipped"
	elif ! update_source_repo; then
		warn "Update repository couldn't be updated, skipping tarball creation"
		return 1
	fi
	if [ "$2" ]; then
		PKG="$2"
		update_package "$PKG"
	else
		for PKG in "${PACKAGES[@]}"; do
			update_package "$PKG"
		done
	fi
}

update_all() {
	for REPO in "$CONF_PATH"/*.repo; do
		update_packages_in_repository "$REPO"
	done
}

interrupt_handler() {
	[ "$OLD_PWD" ] && cd "$OLD_PWD"
}

trap interrupt_handler SIGINT SIGTERM
