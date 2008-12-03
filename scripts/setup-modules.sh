#!/bin/bash
#
#%stage: boot
#
# TODO: generate module deps and copy them to the initrd
#       take xen into account

# Global variables
# Array that stores additional dependencies. Each entry looks like
#       module:module1 module2
declare -a additional_module_dependencies

# Check if module $1 is listed in $modules.
has_module() {
    case " $modules " in
        *" $1 "*)   return 0 ;;
    esac
    return 1
}

# Check if any of the modules in $* are listed in $modules.
has_any_module() {
    local module
    for module in "$@"; do
        has_module "$module" && return 0
    done
}

# Add module $1 at the end of the module list.
add_module() {
    local module
    for module in "$@"; do
        has_module "$module" || modules="$modules $module"
    done
}

# Brief
#       Checks if the kernel version is supported at all.
#
# Description
#       Checks if the kernel version is supported. The background is: If we
#       have a kernel that is completely unsupported, we want to include all
#       modules even if the modules don't have the 'supported' attribute.
#       That allows us to use self-made kernels even on SUSE LINUX Enterprise.
#       The supported flag should not prevent users from running self-compiled
#       kernels on SLES but should prevent the loading of unsupported modules
#       on a supported kernel. Because the modprobe command is already aware
#       if it runs on a system that doesn't have the SUSE supported patch in
#       the kernel and then just loads the kernel module, we can safely include
#       such modules on such systems in initrd.
#
#       The check is done by checking if 'ipv6.ko' is supported. Since we
#       have to supported ipv6 for a very long period of time from now because
#       it's our standard file system, and that module exists on every
#       architecture and does not depend on the hardware and even exists in
#       the base package of the kernel because we need it in a virtualised
#       environment, that module is suitable for that check. I didn't know any
#       better method of checking if the kernel is supported so I implemented
#       that hack. Better than nothing. :-)
#
# Parameters
#       kernelver: the kernel version
#
# Return value
#       0 (true) if the kernel is supported, 1 (false) if the kernel is not
#       supported
check_supported_kernel() {
    local kernel_version=$1
    local output=

    output=$(modinfo -k "$kernel_version" -F supported ipv6 2>/dev/null)
    if [ "$?" -ne 0 ] ; then
        # If the command existed with an error, assume that the kernel is
        # supported. That is just the same behaviour as before we did that
        # check_supported_kernel() hack
        verbose "[MODULES]\t'modinfo -k \"$kernel_version\" -F supported' " \
                "returned with an error."
        return 0
    fi

    if [[ "$output" = *yes* ]] ; then
        verbose "[MODULES]\tSupported kernel ($kernel_version)"
        return 0
    else
        verbose "[MODULES]\tUnsupported kernel ($kernel_version)"
        return 1
    fi
}

# Brief
#       Loads additional dependencies information
#
# Description
#       In /etc/modprobe.conf, /etc/modprobe.conf.local and /etc/modprobe.d/*
#       we have a special syntax
#
#               # SUSE INITRD: foo REQUIRES bar
#
#       to introduce additional dependencies which are expressed in the install
#       lines but cannot be parsed by mkinitrd statically.
#
#       This function loads that dependencies into the global
#       additional_module_dependencies array.
load_additional_dependencies()
{
    # array already filled
    if [ ${#additional_module_dependencies[*]} -ne 0 ] ; then
        return
    fi

    for file in /etc/modprobe.conf \
                /etc/modprobe.conf.local \
                /etc/modprobe.d/* ; do
        # skip files if it does not exist
        if ! [ -r "$file" ] ; then
            continue
        fi

        while read line ; do
            local string module requirement dependencies dependency

            string=${line##*SUSE INITRD: }
            module=${string/ REQUIRES*}
            requirement=${string##*REQUIRES }

            if [ -z "$module" -o -z "$requirement" ] ; then
                echo >&2 "Requirement line '$line' in file '$file' is invalid."
                continue
            fi

            number=0
            added=0
            for entry in ${additional_module_dependencies[@]} ; do
                local module2 requirements2 val
                module2=${entry/:*}
                requirements2=${entry/*:}
                if [ "$module2" = "$module" ] ; then
                    added=1
                    val="$module:$requirements2 $requirement"
                    additional_module_dependencies[$number]=$val
                    break
                fi
                number=$[number+1]
            done

            if [ $added -eq 0 ] ; then
                additional_module_dependencies=( \
                        "${additional_module_dependencies[@]}" \
                        "$module:$requirement" )
            fi
        done < <(grep '^# SUSE INITRD: ' $file)
    done
}

# Brief
#       Returns additional module requirements from
#       additional_module_dependencies
#
# Description
#       Checks for a given kernel modules if there are additional dependencies
#       found by load_additional_dependencies.
#
#       Prints a list (separated by ' ') of modules if there are additional
#       dependencies.
#
# Parameters
#       mod: the module for which additional depdencies should be found
#       ver: the kernel version
#       recursive: recursive call if 1, don't print the final newline
#
# Return value
#       0 (true) if there are additional dependencies, 1 (false) otherwise
get_add_module_deps()
{
    local mod=${1##*/}
    local version=$2
    local recursive=$3
    local printed=0
    mod=${mod%.ko}

    for entry in "${additional_module_dependencies[@]}" ; do
        local module requirements m

        module=${entry/:*}
        requirements=${entry/*:}
        if [ "$module" = "$mod" ] ; then
            for m in $requirements ; do
                filename=$(modinfo -k "$version" -F filename $m)
                if [ -z "$filename" ] ; then
                    echo >&2 "Ignoring additional requirement $mod REQUIRES $m"
                else
                    echo -n "$filename "
                    get_add_module_deps "$m" "$version" 1
                    printed=$[printed+1]
                fi
            done
        fi
    done

    # build the return value
    if [ $printed -ne 0 ] ; then
        if [ "$recursive" -ne 1 ] ; then
            echo ""
        fi
        return 0
    fi

    return 1
}

# Resolve module dependencies and parameters. Returns a list of modules and
# their parameters.
resolve_modules() {
    local kernel_version=$1
    local module=
    local supported=
    local additional_args=
    shift

    if ! check_supported_kernel $kernel_version ; then
        additional_args=--allow-unsupported-modules
    fi

    for module in "$@"; do
        module=${module%.o}  # strip trailing ".o" just in case.
        module=${module%.ko}  # strip trailing ".ko" just in case.

        # don't use a modprobe.conf to get rid of the install lines
        module_list=$(/sbin/modprobe \
            -C /dev/null \
            --set-version $kernel_version --ignore-install \
            --show-depends $module \
            $additional_args \
            | sed -ne 's:.*insmod /\?::p' | sed -ne 's:\ .*\?::p' )
        if [ ! "$module_list" ]; then
            echo \
"WARNING: no dependencies for kernel module '$module' found." >&2
        fi
        for mod in $module_list ; do
            if ! $(echo $resolved_modules | grep -q $mod) ; then
                resolved_modules="$resolved_modules $mod"

                # check for additional requirements specified by
                # SUSE INITRD comments in /etc/modprobe.conf{,local,.d/*}
                additional_reqs=$(get_add_module_deps "$mod" "$kernel_version" 0)
                if [ $? -eq 0 ] ; then
                    local req

                    for req in $additional_reqs ; do
                        if ! $(echo $resolved_modules | grep -q $req) ; then
                            resolved_modules="$resolved_modules $req"
                        fi
                    done
                fi
            fi
        done
    done
    echo $resolved_modules
}

resolve_modalias() {
    local tofind="$1" alias module
        
    while read a alias module; do
        case $tofind in $alias) echo "$module" ;;
        esac
    done < /lib/modules/$kernel_version/modules.alias
}

# gather all the modules we are supposed to copy
modules=
for script in $INITRD_PATH/boot/*.sh; do
    if use_script "$script"; then # only include the modules if the script gets used
        verbose -n ""
        for module in $(cat $script | egrep '%udevmodules: |%modules: ' | sed 's/^.*s: \(.*\)$/\1/'); do
            [ "$module" ] && verbose "[MODULES]\t$(basename $script): $(eval echo $module)"
            add_module $(eval echo $module)
        done
    fi
done

# parsing of '# SUSE INITRD' lines
load_additional_dependencies
resolved_modules="$(resolve_modules $kernel_version $modules)"
if [ $? -ne 0 ] ; then
    return 1
fi

# cut out all modules which have a minus preceding them
modules=$(
for module in $modules; do
    skip=
    for m2 in $modules; do
        if [ "-$module" = "$m2" ]; then
            skip=1
        fi
    done
    [ ${module:0:1} = "-" ] && continue
    [ "$skip" ] || echo "$module"
done
)

if [ "$resolved_modules" ] ; then
    echo -ne "Kernel Modules:\t"
    for mod in $resolved_modules ; do
        modname=${mod##*/}
            echo -n "${modname%%.ko} "
    done
    echo
fi

# Copy all modules into the initrd
for module in $resolved_modules; do
    if [ ! -r $root_dir/$module ]; then
        oops 9 "Module $module not found."
        continue
    fi
    if ! ( cd ${root_dir:-/} ; cp -p --parents $module $tmp_mnt ) ; then
        oops 6 "Failed to add module $module."
        rm -rf $tmp_mnt
        return 1
    fi
done

if [ "$resolved_modules" ] ; then
    [ ! -d $tmp_mnt/lib/modules/$kernel_version ] && oops 10 "No modules have been installed"
    ( cd $tmp_mnt; /sbin/depmod -b $tmp_mnt -e -F $map $kernel_version )
fi


