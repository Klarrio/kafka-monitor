#!/bin/bash

# Expects a 'klarrio-build.json' file to be present in the repository, with the following content:
#  - dockerRepository: Docker image repository
#  - version.upstream: version of the upstream (open source) project
#  - version.klarrio: our own semver-based versioning scheme
#  - buildCommand: command to build the binary that should be included in the Docker image. In this command you have access to the BUILD_VERSION and BUILD_DOCKER_TAG variables.
#  - dockerFile: location of the Dockerfile relative to the project directory. Defaults to the Dockerfile in the project directory.
#  - mainBranch: name of the main branch in the git repository. Release builds will be only allowed to be run on this branch. Defaults to the branch with name "master".
#
# Example:
# {
#   "dockerRepository": "registry.cp.kpn-dsh.com/<project>/<repo>",
#   "version": {
#     "upstream": "x.x.x",
#     "klarrio": "x.x.x"
#   },
#   "buildCommand": "rm -rf build; ./gradlew jar",
#   "dockerFile": "docker/Dockerfile",
#   "mainBranch": "master"
# }

set -e

usage() {
    cat <<EOF
Usage: $(basename $0) [-h|-?] [-b] [-p] [-t major|minor|revision] snapshot|release
    
    -h                  help
    -b                  build the container only; don't push [snapshot mode only]
    -p                  push an existing container; don't build the container first [snapshot mode only]
    -t <upstep>         kind of release: major, minor or revision [release mode only, default=minor]
    
    snapshot            uploads an artifact labeled <version>-SNAPSHOT
    release             uploads an artifact labeled <version>, applies version tag and updates version number
EOF
    exit 1
}

# utility functions {{{
SCRIPTDIR=$(dirname $(readlink -f "$0"))

# pretty colors
NORMAL="\033[0m"
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
WHITE="\033[1;37m"

colorecho() {
    echo -e $*
}

bail() {
    colorecho "$RED" $* "$NORMAL"
    exit 1
}

warn() {
    colorecho "$YELLOW" $* "$NORMAL"
}

info() {
    colorecho "$WHITE" $* "$NORMAL"
}

silent() {
    $* > /dev/null 2> /dev/null
}

binary_in_path() {
    binary="$1"
    silent which "$binary"
}

prerequisite_check() {
    if [ -z $EDITOR ] ; then
        bail "EDITOR environment variable should be set to your preferred editor"
    fi

    if [ ! -f "klarrio-build.json" ] ; then
        bail "Could not find klarrio-build.json"
    fi

    if ! binary_in_path git ; then
        bail "You need git to run this tool"
    fi

    if ! binary_in_path docker ; then
        bail "You need docker to run this tool"
    fi
}

split_version() {
    local v="$1"
    local oifs="$IFS"
    IFS='.'
    local components=($v)
    IFS="$oifs"
    echo ${components[*]}
}


# increment version
# args: <version> {major|minor|revision} 
next_version() {
    if [ $# -ne 2 ] ; then
        bail next_version wrong number of arguments
    fi

    local version="$1"
    local component="$2"

    echo $version | grep -q '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'
    if [ $? -ne 0 ] ; then
        bail next_version invalid version format
    fi

    version_components=($(split_version $version))
    local major=${version_components[0]:-0}
    local minor=${version_components[1]:-0}
    local revision=${version_components[2]:-0}

    case "$component" in 
        major)
            echo $((major+1)).0.0
            ;;
        minor)
            echo $major.$((minor+1)).0
            ;;
        revision)
            echo $major.$minor.$((revision+1))
            ;;
        *)
            bail "next_version invalid version component"
            ;;
    esac
}

git_current_branch() {
    echo "git_current_branch $*" >&2
    git branch | grep '^\*' | awk '{ print $1 }'
}

git_behind_branch() {
    local branch="$1"

    silent git fetch
    git rev-list --left-right --count "origin/$branch...$branch" | awk '{ print $1 }'
}

git_ahead_branch() {
    local branch="$1"

    silent git fetch
    git rev-list --left-right --count "origin/$branch...$branch" | awk '{ print $2 }'
}

git_is_committed() {
    local num_modified=$(git status --porcelain | grep -v '^\?' | wc -l)
    if [ $num_modified -eq 0 ] ; then
        return 0
    else
        return 1
    fi
}

project_get_value() {
    local field="$1"
    cat "klarrio-build.json" | jq -r ".${field}"
}

# }}} 

# arg parsing {{{
BUILD_ONLY=n
PUSH_ONLY=n
OPTIND=1
UPSTEP=minor
while getopts ":hbpt:" opt ; do
    case "$opt" in
        h|\?)
            usage
            ;;
        b)
            BUILD_ONLY=y
            ;;
        p)
            PUSH_ONLY=y
            ;;
        t)
            UPSTEP="$OPTARG"
            ;;
    esac
done
shift $(( $OPTIND - 1 ))
if [ $# -ne 1 ] ; then
    usage
fi

MODE="$1"

prerequisite_check

case "$MODE" in
    snapshot|snap|s)
        MODE="snapshot"
        SUFFIX="-SNAPSHOT"
        UPSTEP="revision"
        ;;
    release|rel|r)
        MODE="release"
        SUFFIX=""
        ;;
    *)
        usage
        ;;
esac

case "$UPSTEP" in
    major|minor|revision)
        ;;
    *)
        usage
        ;;
esac
#}}}

parse_project_manifest() {
    local mft="klarrio-build.json"
    KLARRIO_VERSION=$(project_get_value version.klarrio)
    if [ "$KLARRIO_VERSION" == "null" -o -z "$KLARRIO_VERSION" ] ; then
        bail "Invalid klarrio-build.json: missing 'version.klarrio' property"
    fi

    UPSTREAM_VERSION=$(project_get_value version.upstream)
    if [ "$UPSTREAM_VERSION" == "null" -o -z "$UPSTREAM_VERSION" ] ; then
        bail "Invalid klarrio-build.json: missing 'version.upstream' property"
    fi

    DOCKER_REPO=$(project_get_value dockerRepository)
    if [ "$DOCKER_REPO" == "null" ] ; then
        DOCKER_REPO=
    fi

    if [ -z "$DOCKER_REPO" ] ; then
        bail "Invalid klarrio-build.json: 'dockerRepository' must be defined"
    fi

    BUILDCMD=$(project_get_value buildCommand)
    if [ "$BUILDCMD" == "null" -o -z "$BUILDCMD" ] ; then
        bail "Invalid klarrio-build.json: missing 'BUILDCMD' property with build instructions"
    fi

    DOCKERFILE=$(project_get_value dockerFile)
    if [ "$DOCKERFILE" == "null" ] ; then
        DOCKERFILE='Dockerfile'
    fi

    MAINBRANCH=$(project_get_value mainBranch)
    if [ "$MAINBRANCH" == "null" ] ; then
        MAINBRANCH='master'
    fi
}

parse_project_manifest
if [ $UPSTEP == "revision" ] ; then
    VERSION="${UPSTREAM_VERSION}-${KLARRIO_VERSION}"
else
    VERSION="${UPSTREAM_VERSION}-$(next_version $KLARRIO_VERSION $UPSTEP)"
fi
DOCKER_TAG="${DOCKER_REPO}:${VERSION}${SUFFIX}"

# argument sanity checks {{{
# do the arguments make sense?
if [ $BUILD_ONLY == y -a $PUSH_ONLY == y ] ; then
    bail "Cannot have both build-only (-b) and push-only (-p) set at the same time."
fi

general_release_sanity_checks() {
    branch=$(git_current_branch)
    if [ "$branch" != $MAINBRANCH ] ; then
        bail "You can only release from the repository's ${MAINBRANCH} branch!"
    fi
    if [ "0" != `git_behind_branch $MAINBRANCH` ] ; then
        bail "Your ${MAINBRANCH} branch is behind origin/${MAINBRANCH}. Cannot release."
    fi
    if [ "0" != `git_ahead_branch $MAINBRANCH` ] ; then
        bail "Your ${MAINBRANCH} branch is ahead of origin/${MAINBRANCH}. Cannot release."
    fi
    if ! git_is_committed ; then
        bail "You have uncommitted changes. Cannot release."
    fi

    if [ "$BUILD_ONLY" == "y" -o "$PUSH_ONLY" == "y" ] ; then
        bail "You cannot do build-only or push-only in release mode."
    fi
}

# in case of a RELEASE invocation, check if all conditions are met and the user is sure
if [ "$MODE" == "release" ] ; then
    general_release_sanity_checks

    info You are about to RELEASE version $VERSION of this project.
    info As a result, the version number in klarrio-build.json will be incremented to `${UPSTREAM_VERSION}-(next_version KLARRIO_VERSION revision)`.
    info This change will be pushed straight to origin/$MAINBRANCH.
    info 'Are you sure? (y/n)'
    read -n 1 -t 10 decision
    if [ "$decision" != "y" ] ; then 
        bail "You have changed your mind; aborting..."
    fi
fi
# }}}


# build the container
build_container() {
    info "Building the component..."
    # pass some information into the build process
    export BUILD_VERSION="$VERSION"
    export BUILD_DOCKER_TAG="$DOCKER_TAG"
    eval $BUILDCMD
    export -n BUILD_VERSION
    export -n BUILD_DOCKER_TAG
    info "Building the docker container..."
    docker build --no-cache -t "$DOCKER_TAG" -f "$DOCKERFILE" .
}

# push the container
push_container() {
    docker push "$DOCKER_TAG"
}

# tag with new version
tag_release() {
    git tag -a "${VERSION}"
    git push origin "${VERSION}"
}

# update the version tag in klarrio-build.json
update_version_file() {
    local new_version="${UPSTREAM_VERSION}-$(next_version $KLARRIO_VERSION revision)"
    local tmpfile=$(mktemp)
    cat "klarrio-build.json" | jq ".version.klarrio = \"${new_version}\"" > $tmpfile
    mv $tmpfile "klarrio-build.json"
    git commit -a -m "upstep release version to $new_version"
    git push
}

do_snapshot() {
    if [ "$PUSH_ONLY" != "y" ] ; then
        build_container
    fi
    if [ "$BUILD_ONLY" != "y" ] ; then
        push_container
    fi
}


do_release() {
    build_container
    push_container
    tag_release
    update_version_file
}

if [ $MODE == "snapshot" ] ; then
    do_snapshot
fi

if [ $MODE == "release" ] ; then
    do_release
fi

# vim: set fdm=marker: