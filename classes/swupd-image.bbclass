# Class for swupd integration -- generates input artefacts for consumption by
# swupd-server and calls swupd-server to process the inputs into update
# artefacts for consumption by swupd-client.
#
# See docs/Guide.md for more information.

inherit swupd-client

# Created for each bundle (including os-core) and the "full" directory,
# describing files and directories that swupd-server needs to include in the update
# mechanism (i.e. without SWUPD_FILE_BLACKLIST entries). Used by swupd-server.
SWUPD_ROOTFS_MANIFEST_SUFFIX = ".content.txt"
# Additional entries which need to be in images (for example, /etc/machine-id, but
# that are excluded from the update mechanism. Ignored by swupd-server,
# used by swupdimage.bbclass.
SWUPD_IMAGE_MANIFEST_SUFFIX = ".extra-content.txt"

# Name of the base image. Always set, constant (unlike PN, which is
# different in the different virtual images).
SWUPD_IMAGE_PN = "${@ d.getVar('PN_BASE', True) or d.getVar('PN', True)}"

DEPLOY_DIR_SWUPD_UPDATE = "${DEPLOY_DIR_SWUPD}/update"

# We need to preserve xattrs, which works with bsdtar out of the box.
# It also has saner file handling (less syscalls per file) than GNU tar.
# Last but not least, GNU tar 1.27.1 had weird problems extracting
# all requested entries with -T from an archive ("Not found in archive"
# errors for entries which were present and could be extraced or listed
# when using simpler file lists).
DEPENDS += "libarchive-native"

# We need a valid CURL_CA_BUNDLE, due to YOCTO #9883.
# We could try to avoid the ca-certificates-native dependency
# here if the default is not used, but it seems to get pulled in already,
# so that's overkill.
CURL_CA_BUNDLE ??= "${RECIPE_SYSROOT_NATIVE}/${sysconfdir}/ssl/certs/ca-certificates.crt"
DEPENDS += "ca-certificates-native"

inherit distro_features_check
REQUIRED_DISTRO_FEATURES = "systemd"

python () {
    import os

    havebundles = (d.getVar('SWUPD_BUNDLES', True) or '') != ''
    deploy_dir = d.getVar('DEPLOY_DIR_SWUPD', True)

    # Always set, value differs among virtual image recipes.
    pn = d.getVar('PN', True)
    # The PN value of the base image recipe. None in the base image recipe itself.
    pn_base = d.getVar('PN_BASE', True)
    # For bundle images, the corresponding bundle name. None in swupd images.
    bundle_name = d.getVar('BUNDLE_NAME', True)

    # bundle-<image>-mega archives its rootfs as ${IMAGE_ROOTFS}.tar.
    # Every other recipe then can copy (do_stage_swupd_inputs) or
    # extract relevant files (do_image/create_rootfs()) without sharing
    # the same pseudo database. Not sharing pseudo instances is faster
    # and the expensive reading of individual files via pseudo only
    # needs to be done once.
    if havebundles:
        mega_rootfs = d.getVar('IMAGE_ROOTFS', True)
        mega_rootfs = mega_rootfs.replace('/' + pn +'/', '/bundle-%s-mega/' % (pn_base or pn))
        d.setVar('MEGA_IMAGE_ROOTFS', mega_rootfs)
        mega_archive = mega_rootfs + '.tar'
        workdir = d.getVar('WORKDIR', True)
        d.setVar('MEGA_IMAGE_ARCHIVE', mega_archive)
        mega_archive_rel = os.path.relpath(mega_archive, workdir)
        if os.path.sep not in mega_archive_rel:
           # The mega archive is in our work directory and must be
           # preserved for other virtual images even when rm_work.bbclass
           # is active.
           d.appendVar('RM_WORK_EXCLUDE_ITEMS', ' ' + mega_archive_rel)

    if pn_base is not None:
        # Swupd images must depend on the mega image having been
        # built, as they will copy contents from there. For bundle
        # images that is irrelevant.
        if bundle_name is None:
            mega_name = (' bundle-%s-mega:do_image_complete' % pn_base)
            d.appendVarFlag('do_image', 'depends', mega_name)

        return

    # do_swupd_update requires the full swupd directory hierarchy
    varflags = '%s/update/image %s/update/empty %s/update/www %s' % (deploy_dir, deploy_dir, deploy_dir, deploy_dir)
    d.setVarFlag('do_swupd_update', 'dirs', varflags)

    # For the base image only, set the BUNDLE_NAME to os-core and generate the
    # virtual image for the mega image
    d.setVar('BUNDLE_NAME', 'os-core')

    bundles = (d.getVar('SWUPD_BUNDLES', True) or "").split()
    extended = (d.getVar('BBCLASSEXTEND', True) or "").split()

    # We need to prevent the user defining bundles where the name might clash
    # with naming in meta-swupd and swupd itself:
    #  * mega is the name of our super image, an implementation detail in
    #     meta-swupd
    #  * full is the name used by swupd for the super manifest (listing all
    #     files in all bundles of the OS)
    def check_reserved_name(name):
        reserved_bundles = ['mega', 'full']
        if name in reserved_bundles:
            bb.error('SWUPD_BUNDLES contains an item named "%s", this is a reserved name. Please rename that bundle.' % name)

    for bndl in bundles:
        check_reserved_name(bndl)

    # Generate virtual images for all bundles.
    for bndl in bundles:
        extended.append('swupdbundle:%s' % bndl)
        dep = ' bundle-%s-%s:do_image_complete' % (pn, bndl)
        # do_stage_swupd_inputs will try and utilise artefacts of the bundle
        # image build, so must depend on it having completed
        d.appendVarFlag('do_stage_swupd_inputs', 'depends', dep)

    if havebundles:
        extended.append('swupdbundle:mega')

    # Generate real image files from the os-core bundle plus
    # certain additional bundles. All of these images can share
    # the same swupd update stream, the only difference is the
    # number of pre-installed bundles.
    for imageext in (d.getVar('SWUPD_IMAGES', True) or '').split():
        extended.append('swupdimage:%s' % imageext)

    d.setVar('BBCLASSEXTEND', ' '.join(extended))

    # The base image should depend on the mega-image having been populated
    # to ensure that we're staging the same shared files from the sysroot as
    # the bundle images.
    if havebundles:
        mega_name = (' bundle-%s-mega:do_image_complete' % pn)
        d.appendVarFlag('do_image', 'depends', mega_name)
        d.appendVarFlag('do_stage_swupd_inputs', 'depends', mega_name)

    # do_*swupd_* tasks need to re-run when ${DEPLOY_DIR_SWUPD}
    # got removed. We achieve that by creating the directory if needed
    # and adding a variable with the creation time stamp as value to
    # the do_stage_swupd_inputs vardeps. If that time stamp changes,
    # do_stage_swupd_inputs will be re-run.
    #
    # Uses a stamp file because this code runs several time during a build,
    # changing the value during a build causes hash mismatch errors, and the
    # directory ctime changes as content gets created in the directory.
    stampfile = os.path.join(deploy_dir, '.stamp')
    bb.utils.mkdirhier(deploy_dir)
    with open(stampfile, 'a+') as f:
        ctime = os.fstat(f.fileno()).st_ctime
    bb.parse.mark_dependency(d, stampfile)
    d.setVar('REDO_SWUPD', ctime)
    d.appendVarFlag('do_fetch_swupd_inputs', 'vardeps', ' REDO_SWUPD')
    d.appendVarFlag('do_stage_swupd_inputs', 'vardeps', ' REDO_SWUPD')
    d.appendVarFlag('do_swupd_update', 'vardeps', ' REDO_SWUPD')
}

# swupd-client expects a bundle subscription to exist for each
# installed bundle. This is simply an empty file named for the
# bundle in /usr/share/clear/bundles
def create_bundle_manifest(d, bundlename, dest=None):
    tgtpath = '/usr/share/clear/bundles'
    if dest:
        bundledir = dest + tgtpath
    else:
        bundledir = d.expand('${IMAGE_ROOTFS}%s' % tgtpath)
    bb.utils.mkdirhier(bundledir)
    open(os.path.join(bundledir, bundlename), 'w+b').close()

fakeroot do_rootfs_append () {
    import swupd.bundles

    bundle = d.getVar('BUNDLE_NAME', True)
    bundles = ['os-core']
    if bundle == 'mega':
        bundles.extend((d.getVar('SWUPD_BUNDLES', True) or '').split())
    else:
        bundles.append(bundle)
    # swupd-client expects a bundle subscription to exist for each
    # installed bundle. This is simply an empty file named for the
    # bundle in /usr/share/clear/bundles
    for bundle in bundles:
        swupd.bundles.create_bundle_manifest(d, bundle)
}
do_rootfs[depends] += "virtual/fakeroot-native:do_populate_sysroot"

do_image_append () {
    import swupd.rootfs

    swupd.rootfs.create_rootfs(d)
}

# The content lists of each rootfs get stored separately and
# need to be preserved when rm_work.bbclass is active.
# That information is used by do_stage_swupd_inputs in the
# base recipe.
RM_WORK_EXCLUDE_ITEMS += "swupd${SWUPD_ROOTFS_MANIFEST_SUFFIX} swupd${SWUPD_IMAGE_MANIFEST_SUFFIX}"
python do_swupd_list_bundle () {
    import swupd.bundles

    swupd.bundles.list_bundle_contents(d)
}
do_swupd_list_bundle[depends] = "${@ '${SWUPD_IMAGE_PN}:do_swupd_list_bundle' if '${SWUPD_IMAGE_PN}' != '${PN}' else '' }"
addtask do_swupd_list_bundle after do_image before do_build

# Some files should not be included in swupd manifests and therefore never be
# updated on the target (i.e. certain per-device or machine-generated files in
# /etc when building for a statefule OS). Add the target paths to this list to
# prevent the specified files being copied to the swupd staging directory.
# i.e.
# SWUPD_FILE_BLACKLIST = "\
#     /etc/mtab \
#     /etc/machine-id \
#"
SWUPD_FILE_BLACKLIST ??= ""

SWUPDIMAGEDIR = "${DEPLOY_DIR_SWUPD}/update/image"
SWUPDMANIFESTDIR = "${WORKDIR}/swupd-manifests"

fakeroot python do_stage_swupd_inputs () {
    import swupd.bundles

    if d.getVar('PN_BASE', True):
        bb.debug(2, 'Skipping update input staging for non-base image %s' % d.getVar('PN', True))
        return

    swupd.bundles.create_bundle_definitions(d)
    swupd.bundles.copy_core_contents(d)
    swupd.bundles.copy_bundle_contents(d)
}
addtask stage_swupd_inputs after do_swupd_list_bundle before do_swupd_update
do_stage_swupd_inputs[dirs] = "${SWUPDIMAGEDIR} ${SWUPDMANIFESTDIR} ${DEPLOY_DIR_SWUPD}/maps/"
do_stage_swupd_inputs[depends] += " \
    virtual/fakeroot-native:do_populate_sysroot \
    ${@ ' '.join(['bundle-${SWUPD_IMAGE_PN}-%s:do_swupd_list_bundle' % x for x in (d.getVar('SWUPD_BUNDLES', True) or '').split()]) } \
"

python do_fetch_swupd_inputs () {
    import swupd.bundles

    if d.getVar('PN_BASE', True):
        bb.debug(2, 'Skipping update input staging for non-base image %s' % d.getVar('PN', True))
        return

    # Get information from remote update repo.
    swupd.bundles.download_old_versions(d)
}
do_fetch_swupd_inputs[dirs] = "${SWUPDIMAGEDIR}"
addtask do_fetch_swupd_inputs before do_swupd_update

# Change this to SWUPD_TIMING_CMD = "time" in local.conf
# to enable timing the individual swupd server command invocations.
# Relies on a build host which has "time" as a shell or system
# command.
SWUPD_TIMING_CMD ?= ""

# do_swupd_update uses its own pseudo database, for several reasons:
# - Performance is better when the pseudo instance is not shared
#   with other tasks that run in parallel (for example, meta-isafw's do_analyse_image).
# - Wiping out the deploy/swupd directory and re-executing do_stage_swupd_inputs/do_swupd_update
#   really starts from a clean slate.
# - The log.do_swupd_update will show commands that can be invoked directly, without
#   having to enter a devshell (slightly more convenient).
do_swupd_update () {
    if [ -z "${BUNDLE_NAME}" ] || [ ! -z "${PN_BASE}" ] ; then
        bbdebug 1 'We only generate swupd updates for the base image, skipping ${PN}:do_swupd_update'
        exit
    fi

    if [ ! "${SWUPD_GENERATE}" -eq 1 ]; then
        bbnote 'Update generation disabled, skipping.'
        exit
    fi

    if [ -z ${SWUPD_SIGNING_PUBCERT} ] || [ -z ${SWUPD_SIGNING_PRIVKEY} ]; then
        bbfatal "Manifest signing private key or public certificate path not set."
        exit
    fi

    # Copy public certificate and private key into mixer workspace and make sure it's writable
    cp ${SWUPD_SIGNING_PUBCERT} ${MIXER_DOCKER_HOST_DIR}/Swupd_Root.pem
    chmod +w ${MIXER_DOCKER_HOST_DIR}/Swupd_Root.pem
    cp ${SWUPD_SIGNING_PRIVKEY} ${MIXER_DOCKER_HOST_DIR}/private.pem
    chmod +w ${MIXER_DOCKER_HOST_DIR}/private.pem

    export SWUPD_CERTS_DIR="${STAGING_ETCDIR_NATIVE}/swupd-certs"
    export LEAF_KEY="leaf.key.pem"
    export LEAF_CERT="leaf.cert.pem"
    export CA_CHAIN_CERT="ca-chain.cert.pem"
    export PASSPHRASE="${SWUPD_CERTS_DIR}/passphrase"

    export XZ_DEFAULTS="--threads 0"

    MIXER_WORKSPACE_UPDATE_DIR=${MIXER_WORKSPACE_DIR}/update

    ${SWUPD_LOG_FN} "New OS_VERSION is ${OS_VERSION}"
    # If the swupd directory already exists don't trample over it, but let
    # the user know we're not doing any update generation.
    if [ -e ${DEPLOY_DIR_SWUPD_UPDATE}/www/${OS_VERSION} ]; then
        bbwarn 'swupd image directory exists for OS_VERSION=${OS_VERSION}, not generating updates.'
        bbwarn 'Ensure OS_VERSION is incremented if you want to generate updates.'
        exit
    fi

    # do_stage_swupd_inputs creates image/${OS_VERSION} for us, but
    # only if there has been some change in the input data that causes
    # the tasks to be rerun. In production that is unlikely, but it
    # happens when experimenting with swupd update creation. In that case
    # we can safely re-use the most recent version.
    #
    # However, we must unpack full.tar again to get the additional file
    # attributes right under our pseudo instance, so wipe it out in this case.
    if ! [ -e ${DEPLOY_DIR_SWUPD_UPDATE}/image/${OS_VERSION} ]; then
        latest=$(ls "${DEPLOY_DIR_SWUPD_UPDATE}/image" | grep '^[0-9]*$' | sort -n | tail -1)
        if [ "$latest" ]; then
           ln -s $latest ${DEPLOY_DIR_SWUPD_UPDATE}/image/${OS_VERSION}

           UPDATE_DIR_IN_DOCKER=$(echo "$dir" | sed "s@${DEPLOY_DIR_SWUPD_UPDATE}@${MIXER_WORKSPACE_UPDATE_DIR}@")
           FULL_DIR_IN_DOCKER="$UPDATE_DIR_IN_DOCKER/image/$latest/full"

           eval /usr/bin/docker run -i --network=host --workdir /home/clr/mix --entrypoint rm -v "${MIXER_DOCKER_HOST_DIR}:${MIXER_WORKSPACE_DIR}" ${MIXER_CONTAINER_NAME} "-rf $FULL_DIR_IN_DOCKER"
        else
           bbfatal '${DEPLOY_DIR_SWUPD_UPDATE}/image/${OS_VERSION} does not exist and no previous version was found either.'
           exit 1
        fi
    fi

    swupd_format_of_version () {
        if [ ! -f ${DEPLOY_DIR_SWUPD_UPDATE}/www/$1/Manifest.MoM ]; then
            bbfatal "Cannot determine swupd format of $1, ${DEPLOY_DIR_SWUPD_UPDATE}/www/$1/Manifest.MoM not found."
            exit 1
        fi
        format=`head -1 ${DEPLOY_DIR_SWUPD_UPDATE}/www/$1/Manifest.MoM | perl -n -e '/^MANIFEST\s(\d+)$/ && print $1'`
        if [ ! "$format" ]; then
            bbfatal "Cannot determine swupd format of $1, ${DEPLOY_DIR_SWUPD_UPDATE}/www/$1/Manifest.MoM does not have MANIFEST with format number in first line."
            exit 1
        fi
        echo $format
    }

    # do_fetch_swupd_inputs() creates this file when a content
    # URL was set, so creating an empty file shouldn't be necessary
    # in most cases. Also determine whether we are switching
    # formats.
    #
    # When the new format is different compared to what was used by
    # latest.version, then swupd-server will automatically ignore
    # the old content. That includes the case where tool format
    # hasn't changed and only the distro format was bumped. In that
    # case, reusing old content would be possible, but swupd-server
    # would have to be improved to know that.
    if [ -e ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version ]; then
        PREVREL=`cat ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version`
        if [ ! -e ${DEPLOY_DIR_SWUPD_UPDATE}/www/$PREVREL/Manifest.MoM ]; then
            bbfatal "${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version specifies $PREVREL as last version, but there is no corresponding ${DEPLOY_DIR_SWUPD_UPDATE}/www/$PREVREL/Manifest.MoM."
            exit 1
        fi
        PREVFORMAT=`swupd_format_of_version $PREVREL`
        if [ ! "$PREVFORMAT" ]; then
            bbfatal "Format number not found in first line of ${DEPLOY_DIR_SWUPD_UPDATE}/www/$PREVREL/Manifest.MoM"
            exit 1
        fi
        # For now assume that SWUPD_DISTRO_FORMAT is always 0 and that thus
        # $PREVFORMAT also is the format of the previous tools.
        PREVTOOLSFORMAT=$PREVFORMAT

        if [ $PREVFORMAT -ne ${SWUPD_FORMAT} ] && [ $PREVREL -ge ${OS_VERSION_INTERIM} ]; then
            bbfatal "Building two releases because of a format change, so OS_VERSION - 1 = ${OS_VERSION_INTERIM} must be higher than last version $PREVREL."
        elif [ $PREVREL -ge ${OS_VERSION} ]; then
            bbfatal "OS_VERSION = ${OS_VERSION} must be higher than last version $PREVREL."
            exit 1
        fi
    else
        bbdebug 2 "Stubbing out empty latest.version file"
        touch ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version
        PREVREL="0"
        PREVFORMAT=${SWUPD_FORMAT}
        PREVTOOLSFORMAT=${SWUPD_FORMAT}
    fi

    # swupd-server >= 3.2.8 uses a different name. Support old and new names
    # via symlinking.
    ln -sf latest.version ${DEPLOY_DIR_SWUPD_UPDATE}/image/LAST_VER

    ${SWUPD_LOG_FN} "Generating update from $PREVREL (format $PREVFORMAT) to ${OS_VERSION} (format ${SWUPD_FORMAT})"

    # Generate swupd-server configuration
    SERVER_INI="${DEPLOY_DIR_SWUPD_UPDATE}/server.ini"
    bbdebug 2 "Writing ${SERVER_INI}"
    if [ -e "${SERVER_INI}" ]; then
       rm ${SERVER_INI}
    fi
    cat << END > ${SERVER_INI}
[Server]
imagebase=${MIXER_WORKSPACE_DIR}/update/image/
outputdir=${MIXER_WORKSPACE_DIR}/update/www/
emptydir=${MIXER_WORKSPACE_DIR}/update/empty/
END

    GROUPS_INI="${DEPLOY_DIR_SWUPD_UPDATE}/groups.ini"
    bbdebug 2 "Writing ${GROUPS_INI}"
    if [ -e "${GROUPS_INI}" ]; then
       rm ${GROUPS_INI}
    fi
    touch ${GROUPS_INI}
    ALL_BUNDLES="os-core ${SWUPD_BUNDLES} ${SWUPD_EMPTY_BUNDLES}"
    for bndl in ${ALL_BUNDLES}; do
        echo "[$bndl]" >> ${GROUPS_INI}
        echo "group=$bndl" >> ${GROUPS_INI}
        echo "" >> ${GROUPS_INI}
    done

    invoke_bsdtar () {
        eval /usr/bin/docker run -i -e LANG=en_US.UTF-8 -e LC_ALL=en_US.UTF-8 --network=host --workdir /home/clr/mix --entrypoint bsdtar -v "${MIXER_DOCKER_HOST_DIR}:${MIXER_WORKSPACE_DIR}" ${MIXER_CONTAINER_NAME} "$@"
    }

    # Unpack the input rootfs dir(s) for use with the swupd tools. Might have happened
    # already in a previous run of this task.
    for archive in ${DEPLOY_DIR_SWUPD_UPDATE}/image/*/*.tar; do
        dir=$(echo $archive | sed -e 's/.tar$//')
        if [ -e $archive ] && ! [ -d $dir ]; then
            mkdir -p $dir

            # Note @ must be used for delimiter as slashes are contained in the string and break sed
            ARCHIVE_IN_DOCKER=$(echo "$archive" | sed "s@${DEPLOY_DIR_SWUPD_UPDATE}@${MIXER_WORKSPACE_UPDATE_DIR}@")
            DIR_IN_DOCKER=$(echo "$dir" | sed "s@${DEPLOY_DIR_SWUPD_UPDATE}@${MIXER_WORKSPACE_UPDATE_DIR}@")
            bbnote "Unpacking inside container ${ARCHIVE_IN_DOCKER} to ${DIR_IN_DOCKER}"
            invoke_bsdtar "-xf ${ARCHIVE_IN_DOCKER} -C ${DIR_IN_DOCKER} --numeric-owner"
        fi
    done

    invoke_mixer () {
        eval /usr/bin/docker run -i --network=host --workdir /home/clr/mix --entrypoint mixer -v "${MIXER_DOCKER_HOST_DIR}:${MIXER_WORKSPACE_DIR}" ${MIXER_CONTAINER_NAME} "$@" --native
    }

    if [ "${SWUPD_CONTENT_BUILD_URL}" ]; then
        content_url_parameter="'${SWUPD_CONTENT_BUILD_URL}'"
    else
        content_url_parameter="''"
    fi

    create_version () {
        swupd_format=$1
        tool_format=$2
        os_version=$3
        prev_version=${PREVREL}

        if [ "${prev_version}" = "0" ]; then
            prev_version="1"
        fi

        ${SWUPD_LOG_FN} 'Using mixer version:'
        invoke_mixer "--version"

        ${SWUPD_LOG_FN} 'Initializing mixer workspace'
        MIXER_INIT_CMD="init --clear-version ${prev_version} --format ${swupd_format} --upstream-url ${content_url_parameter} --no-default-bundles --mix-version ${os_version} --offline"
        invoke_mixer ${MIXER_INIT_CMD}

        ${SWUPD_LOG_FN} "Generating fullfiles and zero-packs for $os_version, this can take some time."
        invoke_mixer build update --format ${swupd_format}

        if [ ! -z "${SWUPD_DELTAPACK_VERSIONS}" ]; then
            # Generate delta-packs against previous number of versions chosen by our caller,
            # if possible. Different formats make this useless because the previous
            # version won't be able to update to the new version directly.
            invoke_mixer build delta-packs --report --previous-versions ${SWUPD_DELTAPACK_VERSIONS} --to $os_version
        else
            bbnote 'SWUPD_DELTAPACK_VERSIONS not set, skipping delta pack generation.'
        fi
    }

    if [ $PREVFORMAT -ne ${SWUPD_FORMAT} ]; then
        # Exact same content (including the OS_VERSION in the os-release file),
        # just different tool and/or format in the manifests.
        ln -sf ${OS_VERSION} ${DEPLOY_DIR_SWUPD_UPDATE}/image/${OS_VERSION_INTERIM}
        echo $PREVREL > ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version
        create_version $PREVFORMAT $PREVTOOLSFORMAT ${OS_VERSION_INTERIM}
    fi
    echo $PREVREL > ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version
    create_version ${SWUPD_FORMAT} ${SWUPD_TOOLS_FORMAT} ${OS_VERSION}
    echo ${OS_VERSION} > ${DEPLOY_DIR_SWUPD_UPDATE}/image/latest.version
}

SWUPDDEPENDS = "\
    virtual/fakeroot-native:do_populate_sysroot \
    rsync-native:do_populate_sysroot \
    bsdiff-native:do_populate_sysroot \
"

addtask swupd_update after do_image_complete before do_build
do_swupd_update[depends] = "${SWUPDDEPENDS}"

# pseudo does not handle xattrs correctly for hardlinks:
# https://bugzilla.yoctoproject.org/show_bug.cgi?id=9317
#
# This started to become a problem when copying rootfs
# content around for swupd bundle creation. As a workaround,
# we avoid having hardlinks in the rootfs and replace them
# with symlinks.
python swupd_replace_hardlinks () {
    import os
    import stat

    # Collect all inodes and which entries share them.
    inodes = {}
    for root, dirs, files in os.walk(d.getVar('IMAGE_ROOTFS', True)):
        for file in files:
            path = os.path.join(root, file)
            s = os.lstat(path)
            if stat.S_ISREG(s.st_mode):
                inodes.setdefault(s.st_ino, []).append(path)

    for inode, paths in inodes.items():
        if len(paths) > 1:
            paths.sort()
            bb.debug(3, 'Removing hardlinks: %s' % ' = '.join(paths))
            # Arbitrarily pick the first entry as symlink target.
            target = paths.pop(0)
            for path in paths:
                reltarget = os.path.relpath(target, os.path.dirname(path))
                os.unlink(path)
                os.symlink(reltarget, path)
}
ROOTFS_POSTPROCESS_COMMAND += "swupd_replace_hardlinks; "

# Check whether the constructed image contains any dangling symlinks, these
# are likely to indicate deeper issues.
# NOTE: you'll almost certainly want to override these for your distro.
# /run, /var/volatile and /dev only get mounted at runtime.
# Enable this check by adding it to IMAGE_QA_COMMANDS
# IMAGE_QA_COMMANDS += " \
#     swupd_check_dangling_symlinks \
# "
SWUPD_IMAGE_SYMLINK_WHITELIST ??= " \
    /run/lock \
    /var/volatile/tmp \
    /var/volatile/log \
    /dev/null \
    /proc/mounts \
    /run/resolv.conf \
"

python swupd_check_dangling_symlinks() {
    from oe.utils import ImageQAFailed

    rootfs = d.getVar("IMAGE_ROOTFS", True)

    def resolve_links(target, root):
        if not target.startswith('/'):
            target = os.path.normpath(os.path.join(root, target))
        else:
            # Absolute links are in fact relative to the rootfs.
            # Can't use os.path.join() here, it skips the
            # components before absolute paths.
            target = os.path.normpath(rootfs + target)
        if os.path.islink(target):
            root = os.path.dirname(target)
            target = os.readlink(target)
            target = resolve_links(target, root)
        return target

    # Check for dangling symlinks. One common reason for them
    # in swupd images is update-alternatives where the alternative
    # that gets chosen in the mega image then is not installed
    # in a sub-image.
    #
    # Some allowed cases are whitelisted.
    whitelist = d.getVar('SWUPD_IMAGE_SYMLINK_WHITELIST', True).split()
    message = ''
    for root, dirs, files in os.walk(rootfs):
        for entry in files + dirs:
            path = os.path.join(root, entry)
            if os.path.islink(path):
                target = os.readlink(path)
                final_target = resolve_links(target, root)
                if not os.path.exists(final_target) and not final_target[len(rootfs):] in whitelist:
                    message = message + 'Dangling symlink: %s -> %s -> %s does not resolve to a valid filesystem entry.\n' % (path, target, final_target)

    if message != '':
        message = message + '\nIf these symlinks not pointing to a valid destination is not an issue \
i.e. the link is to a file which only exists at runtime, such as files in /proc, add them to \
SWUPD_IMAGE_SYMLINK_WHITELIST to resolve this error.'
        raise ImageQAFailed(message, swupd_check_dangling_symlinks)
}