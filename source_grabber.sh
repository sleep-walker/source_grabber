#!/bin/bash
####
#
# Source Grabber
# --------------
#
# Tool for easy updating packages from VCS as SVN or GIT.
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
# - it should work with directories of project (parameter will be project dir)
# - I may need to mark spec files which I'd like to take care of
# - how to update VCS repository only once for whole project? how to remember such
# - 
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
	return 1
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

# TODO: currently unused - use (update) or remove
pkg_specific() {
	return 255
#	if is_defined "${PKG//-/_}_${FUNCNAME[1]}"; then
#		inform "      * package specific ${FUNCNAME[1]} found, calling it"
#		"${PKG//-/_}_${FUNCNAME[1]}"
#		return $?
#	else
#		return 255
#	fi
}

rename_dir_in_tarball() {
#	$1	new tarball name without suffix

	if [ "$RESULT_TARBALL" = "$1" ]; then
		warn "Result tarball and the new one after rename is the same, skipping"
		return 0
	fi
	local TMPDIR="$(mktemp -d)"
	(
		set -e
		cd "$TMPDIR"
		tar xjf "${SPEC%/*}/$RESULT_TARBALL" || error "Cannot untar result tarball"
		mv "${RESULT_TARBALL%.tar.bz2}" "${1%.tar.bz2}" || error "Cannot rename: " "'${RESULT_TARBALL%.tar.bz2}' --> '$1'"
		tar cjf "${SPEC%/*}/$1" "${1%.tar.bz2}" || error "Cannot tar: " "'${1%.tar.bz2}' into '$SRC_DIR${SRC_REL_DIR:+/$SRC_REL_DIR}/$1'"
		rm "${SPEC%/*}/$RESULT_TARBALL" || error "Cannot remove old result tarball"
	)
	if [ $? -ne 0 ]; then
		return 1
	fi
	NEW_VERSION="$RENAMED_VERSION"
	RESULT_TARBALL="$1"
	cd "$OLD_PWD"
	rm -rf "$TMPDIR"
}

###
# SVN functions
###############

find_last_packed_version_svn() {
# I rely on revision previously added to version string in spec file
	OLD_REVISION="$(sed -n 's/^Version:[[:blank:]]\+[0-9.]*\.\([0-9]\+\)[[:blank:]]*$/\1/p' "$OBS_PRJ_DIR/$OBS_PKG/$OBS_PKG.spec")"
}

need_update_svn() {
	# what is last revision in spec file?
	find_last_packed_version_svn
	# were there any changes since that revision?
	NEW_REVISION="$(svn info | sed -n 's/^Revision: \([0-9]\+\)$/\1/p')"
	[ "$(cd "$SRC_DIR"; svn log -r "$REVISION:HEAD" ${SRC_REL_DIR:+"$SRC_REL_DIR"} 2>/dev/null | wc -l)" -gt 0 ]
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
}


###
# GIT functions
###############

need_update_git() {
	NEW_REVISION="$(git --git-dir="$SRC_DIR/.git" log --format=oneline -n 1 ${SRC_REL_DIR:+-- "$SRC_REL_DIR"} | cut -d\  -f1)"
	# what is last revision in spec file?
	if [ -z "$REVISION" ] || ! [[ $REVISION =~ ^[0-9a-f]+$ ]]; then
		return 0
	fi
	# were there any changes since that revision?
	[ "$(cd "$SRC_DIR"; git log --format=oneline "$REVISION..HEAD" ${SRC_REL_DIR:+-- "$SRC_REL_DIR"} 2>/dev/null | wc -l)" -gt 0 ]

}

update_spec_git() {
	# there is already place with REVISION, update it
	if grep '^### REVISION=' "$SPEC" &> /dev/null; then
		sed -i "s/^### REVISION=.*$/### REVISION=$NEW_REVISION/" "$SPEC"
	# there is not REVISION, but there is already some part of spec relevant for this script
	elif grep '^### ' "$SPEC" &> /dev/null; then
		local LINE="$(grep -m1 -n '^### ' "$SPEC" | cut -d\: -f1)"
		sed -i "$((LINE+1))s/^/### REVISION=$NEW_REVISION\n/" "$SPEC"
	# there is nothing relevant for this script yet
	else
		sed -i "/^[^#]/s/^/### # begin - this section is used for automatic updates\n### REVISION=$NEW_REVISION\n### # end -this section is used for automatic updates\n/;T;q" "$SPEC"
	fi
	sed -i "s@^Version:.*@Version:\t$NEW_VERSION@" "$SPEC"
}

update_git() {
	NEW_REVISION="$(git --git-dir="$SRC_DIR/.git" log --format=oneline -n 1 ${SRC_REL_DIR:+-- "$SRC_REL_DIR"} | cut -d\  -f1)"
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
}

###
# OBS functions
###############

autocommit() {
	yes | osc ci -m "$MSG"
}

commit_obs_package() {
	local OLD_PWD="$PWD"
	local MSG="source_grabber autoupdate to revision $NEW_REVISION"
	cd "${SPEC%/*}"
	if [ "$RESULT_TARBALL" != "${OLD_TARBALL##*/}" ]; then
		rm "$OLD_TARBALL"
	else
		inform "    * Result tarball is the same as old tarball"
	fi
	inform "      * adding/removing tarballs"
	report_on_error osc ar || warn "    * Error occured during osc addremove"
	inform "      * adding record to .changes file"
	report_on_error osc vc -m "$MSG" || warn "    * Error occured during update of .changes file"
	if [ "$SKIP_COMMIT" ]; then
		inform "    * Skipping commit to OBS ${SKIP_COMMIT:+(SKIP_COMMIT)}"
		cd "$OLD_PWD"
		return 0
	fi
	inform "      * commiting changes"
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
	local NUM="$(wc -l <<< "$RESULT_TARBALL")"
	case $NUM in
		1)
			true ;;
		0)
			error "      * Cannot locate tarball result" ;;
		*)
			error "      * Multiple result tarballs found" ;;
	esac
}

update_spec() {
	case $REPO_TYPE in
		GIT)
			update_spec_git;;
		SVN)
			update_spec_svn;;
		*)
			error "Unknown repository type, cannot run $FUNCNAME" ;;
	esac
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
	cd "$SRC_DIR${SRC_REL_DIR:+/$SRC_REL_DIR}"

	if [ "$SKIP_TARBALL" ]; then
		inform "    * Skipping tarball creation ${SKIP_TARBALL:+(SKIP_TARBALL)}"
	else
#		if find_result_tarball &> /dev/null; then
#			error "found tarball matching my rules before making one"
#			return 3
#		fi
		# if there is specific action to be made, do it (i.g. autoreconf...)
		if is_defined pre_configure_hook; then
			inform "      * pre_configure_hook defined, calling it"
			if ! report_on_error pre_configure_hook; then
				error "        * pre_configure_hook failed"
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
	mv "$SRC_DIR${SRC_REL_DIR:+/$SRC_REL_DIR}/$RESULT_TARBALL" "${SPEC%/*}"
	cd "$OLD_PWD"
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
#	for i in OBS_PKG SRC_REL_DIR; do
#		if eval [ "\"\$$1_$i\"" ]; then
#			eval "$i"="\$$1_$i"
#		else
#			eval "$i"="'$1'"
#		fi
#	done

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

##################################################################

dependency_hack() {
    # create backup of configure.ac
    mv configure.ac configure.ac.backup
    # don't require any specific version
    sed 's@ \(>=\?\) [0-9.]*@ \1 0.0.0@g' configure.ac.backup > configure.ac
    # create configure
    autoreconf -ifv
    # put changes back, so original file gets to result tarball
    cp configure.ac.backup configure.ac
}

detect_repo_type() {
	if [[ $SRC_URL =~ ^git:// ]] || [[ $SRC_URL =~ \.git$ ]]; then
		REPO_TYPE=GIT
		return 0
	elif [[ $SRC_URL =~ ^svn:// ]]; then
		REPO_TYPE=SVN
		return 0
	fi
	return 1
}

new_version() {
# NOTE: This function expects no manipulation with tarball name
# 1] split old tarball name into 3 parts:
#    begin - old version string - end
# 2] from result tarball cut begin and end to get new version string

	# 1] split old name to these variables
	{
		read NAME_BEGIN
		read NAME_END
	} < <(sed -n "s/^\(.*\)${VERSION//./\\.}\(.*\)/\1\n\2/p" <<< "$OLD_TARBALL")
	# check if everything is as it should be
	if [ -z "$NAME_BEGIN" -o -z "$NAME_END" ]; then
		error "Cannot find old find string before version and after version in old source file"
		return 1
	fi

	# 2] cut begin (prefix) and end (suffix) if possible
	local WITHOUT_BEGIN="${RESULT_TARBALL#$NAME_BEGIN}"
	if [ "${WITHOUT_BEGIN}" = "${RESULT_TARBALL}" ]; then
		error "Cannot cut '$NAME_BEGIN' from beginning of '$RESULT_TARBALL'"
		return 1
	fi
	local WITHOUT_END="${WITHOUT_BEGIN%$NAME_END}"
	if [ "$WITHOUT_END" = "${WITHOUT_BEGIN}" ]; then
		error "Cannot cut '$NAME_END' from end of '$WITHOUT_BEGIN'"
		return 1
	fi
	# it's not possible to have '-' in version string
	local WITHOUT_DASH="${WITHOUT_END%%-*}"
	# if there is RENAME_TO defined, evaluate it (so it can use variables defined after reading configuration)
	if [ "$RENAME_TO" ]; then
		eval eval RENAME_TO="\"$RENAME_TO\""
		eval eval RENAMED_VERSION="\"$RENAMED_VERSION\""
	else
		if [ "$WITHOUT_END" != "${WITHOUT_DASH}" ]; then
			# so if there is, use only left part
			# but also rename tarball and contained directory
			RENAME_TO="$NAME_BEGIN${WITHOUT_DASH}$NAME_END"
			RENAMED_VERSION="$WITHOUT_DASH"
			inform "Version contains '-', directory in tarball and the filename will be altered to: " "$RENAME_TO"
		else
			unset RENAME_TO RENAMED_VERSION
		fi
	fi
	NEW_VERSION="${WITHOUT_END}"
}

locate_spec() {
	SPEC="$(ls "$OBS_PRJ_DIR/$OBS_PKG/"*.spec)"
	local NUM="$(wc -l <<< "$SPEC")"
	case NUM in
		0)
			error "Cannot find spec file"; return 1;;
		1)
			inform "Spec file: " "$SPEC";;
		*)
			error "Multiple spec file detected, I don't know which one to use"; return 1;;
	esac
}

read_spec() {
# Find all important information from spec file.
# Need to run: SPEC
	# find SRC_URL, NAME, VERSION
	source <(rpmspec -D "%_sourcedir ${SPEC%/*}" -q --qf 'SRC_URL=%{url}\nNAME=%{name}\nVERSION=%{version}\n' "$SPEC" | head -n 3)
	if [ -z "$SRC_URL" -o -z "$NAME" -o -z "$VERSION" ]; then
		error "Cannot parse from specfile: " "${SRC_URL:-SRC_URL} ${NAME:-NAME} ${VERSION:-VERSION}"
		return 1
	fi
	# find current source
	OLD_TARBALL="$(rpmspec -D "%_sourcedir ${SPEC%/*}" -P "$SPEC" | \
		sed -n 's/Source:[[:blank:]]*\([^[:blank:]]\+\)[[:blank:]]*$/\1/p')"
	if [ ! -f "${SPEC%/*}/$OLD_TARBALL" ]; then
		error "Cannot identify old tarball"
		return 1
	fi
	# read hook functions, SRC_REL_DIR, REVISION
	source <(sed -n 's/^### //p' "$SPEC")
	if [ -z "$REVISION" ]; then
		warn "Cannot parse from specfile: " "'${REVISION:-REVISION}'"
		warn "Continuing anyway..."
#		return 1
	fi
	find_src_dir || return 1
	if [ -z "$REPO_TYPE" ]; then
		if ! detect_repo_type; then
			error "Cannot recognize repository type for '$SRC_URL'. Specify manually as \$REPO_TYPE or make detect_repo_type() more clever"
			return 1
		fi
	fi
}

find_src_dir() {
	unset SRC_DIR
	for i in $(seq 0 3 ${#LOCAL_REPOS[@]}); do
		if [ "${1:-$SRC_URL}" = "${LOCAL_REPOS[i]}" ]; then
			REPO_TYPE="${LOCAL_REPOS[i+1]}"
			SRC_DIR="${LOCAL_REPOS[i+2]}"
			break
		fi
	done
	if [ -z "$SRC_DIR" ]; then
		error "    * Local repository for '${1:-$SRC_URL}' is not defined, please, specify in local configuration"
	else
		inform "    * Local repository: " "$SRC_DIR"
	fi
}

need_update() {
	case $REPO_TYPE in
		GIT)
			need_update_git ;;
		SVN)
			need_update_svn ;;
		*)
			error "Unknown repository type: " "'$REPO_TYPE'" ;;
	esac
}
update_project_package() {
	#locate_spec
	(
		SPEC="$1"
		unset REVISION OLD_TARBALL RESULT_TARBALL RENAME_TO NAME_BEGIN NAME_END
		read_spec || exit 1
		
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
		if [ "$RENAME_TO" ]; then
			inform "Converting tarball from '$RESULT_TARBALL' to '$RENAME_TO'"
			rename_dir_in_tarball "$RENAME_TO"
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
	)
}

is_spec_to_be_used() {
# is the spec file usable for this script?
# FIXME: define, what is needed for using spec file as source for update
# SRC_REL_DIR may be empty (using repository root)
# REPO_TYPE may be empty (URL may be sufficient for identifying repository type git:// svn://)
# REVISION may be undefined for the first time and it means that update is needed for sure

	grep '^### ' "$1" &> /dev/null
}

update_vcs() {
	case $REPO_TYPE in
		GIT)
			update_git ;;
		SVN)
			update_svn ;;
		*)
			error "Unknown repository type: " "'$REPO_TYPE'";;
	esac
}

update_project() {
#	$1	project directory
	OBS_PRJ_DIR="$1"
	# if it is not absolute path, make it so (well, almost)
	if [ "${1:0:1}" != '/' ]; then
		OBS_PRJ_DIR="$PWD/$OBS_PRJ_DIR"
	fi
	if [ ! -d "$1" ]; then
		error "Project '$1' doesn't exists"
		return 1
	elif [ ! -d "$1/.osc" ]; then
		error "Directory '$1' doesn't seem to be OBS project"
		return 1
	fi
	OBS_PRJ="$(cat "$OBS_PRJ_DIR/.osc/_project" 2>/dev/null)"
	# repositories to update
	inform "Updating needed VCS repositories"
	local line
	while read line; do
			ARRAY=( $line )
			REPO_TYPE="${ARRAY[0]}"
			SRC_URL="${ARRAY[1]}"
			SPEC="${ARRAY[2]}"
			find_src_dir
			update_vcs || return 1
	done < <(for SPEC in "$OBS_PRJ_DIR"/eina/eina.spec; do
		if is_spec_to_be_used "$SPEC"; then
			read_spec &> /dev/null
			echo "$REPO_TYPE $SRC_URL $SPEC"
		fi
	done | sort -uk 1,2)
	unset SRC_DIR SRC_URL REPO_TYPE SPEC ARRAY BROKEN
	for SPEC in "$OBS_PRJ_DIR"/*/*.spec; do
		if is_spec_to_be_used "$SPEC"; then
			inform "Updating: " "'${SPEC#${OBS_PRJ_DIR%/}/}'"
			if ! update_project_package "$SPEC"; then
				BROKEN[${#BROKEN[@]}]="$SPEC"
			fi
		fi
	done
	if [ "$BROKEN" ]; then
		inform "Failed spec files:"
		for i in "${BROKEN[@]}"; do
			echo "   $i"
		done
	fi

}
