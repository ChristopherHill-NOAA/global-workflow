#!/usr/bin/env bash

###
function _usage() {
   cat << EOF
   This script automates the experiment setup process for the global workflow.
   Options are also available to update submodules, build the workflow (with
   specific build flags), specify which YAMLs and YAML directory to run, and
   whether to automatically update your crontab.

   Usage: generate_workflows.sh [OPTIONS] /path/to/RUNTESTS
          or
          RUNTESTS=/path/to/RUNTESTS generate_workflows.sh [OPTIONS]

    -H Root directory of the global workflow.
       If not specified, then the directory is assumed to be one parent
       directory up from this script's residing directory.

    -b Run build_all.sh with default flags
       (build the UFS, UPP, UFS_Utils, and GFS-utils only)

    -u Update submodules before building and/or generating experiments.

    -y "list of YAMLs to run"
       If this option is not specified, the default case (C48_ATM) will be
       run.  This option is incompatible with -G, -E, or -S.
       Example: -y "C48_ATM C48_S2SW C96C48_hybatmDA"

    -Y /path/to/directory/with/YAMLs
       If this option is not specified, then the \${HOMEgfs}/ci/cases/pr
       directory is used.

    -G Run all valid GFS cases in the specified YAML directory.
       If -b is specified, then "-g -u" (build the GSI and GDASApp)
       will be passed to build_all.sh.
       Note that these builds are disabled on some systems, which
       will result in a warning from build_all.sh.

    -E Run all valid GEFS cases in the specified YAML directory.
       If -b is specified, then "-w" will be passed to build_all.sh.

    -S Run all valid SFS cases in the specified YAML directory.

    NOTES:
         - Valid cases are determined by the experiment:system key as
           well as the skip_ci_on_hosts list in each YAML.

    -A "HPC account name"  Set the HPC account name.
       If this is not set, the default in
       \$HOMEgfs/ci/platform/config.\$machine
       will be used.

    -c Append the chosen set of tests to your existing crontab
       If this option is not chosen, the new entries that would have been
       written to your crontab will be printed to stdout.
       NOTES:
          - This option is not supported on Gaea.  Instead, the output will
            need to be written to scrontab manually.
          - For Orion/Hercules, this option will not work unless run on
            the [orion|hercules]-login-1 head node.

    -e "your@email.com" Email address to place in the crontab.
       If this option is not specified, then the existing email address in
       the crontab will be preserved.

    -t Add a 'tag' to the end of the case names in the pslots to distinguish
       pslots between multiple sets of tests.

    -v Verbose mode.  Prints output of all commands to stdout.

    -V Very verbose mode.  Passes -v to all commands and prints to stdout.

    -d Debug mode.  Same as -V but also enables logging (set -x).

    -h Display this message.
EOF
}

set -eu

# Set default options
HOMEgfs=""
_specified_home=false
_build=false
_build_flags=""
_update_submods=false
declare -a _yaml_list=("C48_ATM")
_specified_yaml_list=false
_yaml_dir=""  # Will be set based off of HOMEgfs if not specified explicitly
_specified_yaml_dir=false
_run_all_gfs=false
_run_all_gefs=false
_run_all_sfs=false
_hpc_account=""
_set_account=false
_update_cron=false
_email=""
_tag=""
_set_email=false
_verbose=false
_very_verbose=false
_verbose_flag="--"
_debug="false"
_cwd=$(pwd)
_runtests="${RUNTESTS:-${_runtests:-}}"
_nonflag_option_count=0

while [[ $# -gt 0 && "$1" != "--" ]]; do
   while getopts ":H:bB:uy:Y:GESA:ce:t:vVdh" option; do
      case "${option}" in
        H)
           HOMEgfs="${OPTARG}"
           _specified_home=true
           if [[ ! -d "${HOMEgfs}" ]]; then
              echo "Specified HOMEgfs directory (${HOMEgfs}) does not exist"
              exit 1
           fi
           ;;
        b) _build=true ;;
        u) _update_submods=true ;;
        y) # Start over with an empty _yaml_list
           declare -a _yaml_list=()
           for _yaml in ${OPTARG}; do
              # Strip .yaml from the end of each and append to _yaml_list
              _yaml_list+=("${_yaml//.yaml/}")
           done
           _specified_yaml_list=true
           ;;
        Y) _yaml_dir="${OPTARG}" && _specified_yaml_dir=true ;;
        G) _run_all_gfs=true ;;
        E) _run_all_gefs=true ;;
        S) _run_all_sfs=true ;;
        c) _update_cron=true ;;
        e) _email="${OPTARG}" && _set_email=true ;;
        t) _tag="_${OPTARG}" ;;
        v) _verbose=true ;;
        V) _very_verbose=true && _verbose=true && _verbose_flag="-v" ;;
        A) _set_account=true && _hpc_account="${OPTARG}" ;;
        d) _debug=true && _very_verbose=true && _verbose=true && _verbose_flag="-v" && PS4='${LINENO}: ' ;;
        h) _usage && exit 0 ;;
        :)
          echo "[${BASH_SOURCE[0]}]: ${option} requires an argument"
          _usage
          exit 1
          ;;
        *)
          echo "[${BASH_SOURCE[0]}]: Unrecognized option: ${option}"
          _usage
          exit 1
          ;;
      esac
   done

   if [[ ${OPTIND:-0} -gt 0 ]]; then
      shift $((OPTIND-1))
   fi

   while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
      _runtests=${1}
      (( _nonflag_option_count += 1 ))
      if [[ ${_nonflag_option_count} -gt 1 ]]; then
         echo "Too many arguments specified."
         _usage
         exit 2
      fi
      shift
   done
done

function send_email() {
   # Send an email to $_email.
   # Only use this once we get to the long steps (building, etc) and on success.
   _subject="${_subject:-generate_workflows.sh failure on ${machine}}"
   _body="${1}"

   echo "${_body}" | mail -s "${_subject}" "${_email}"
}

if [[ -z "${_runtests}" ]]; then
   echo "Mising run directory (RUNTESTS) argument/environment variable."
   sleep 2
   _usage
   exit 3
fi

# Turn on logging if running in debug mode
if [[ "${_debug}" == "true" ]]; then
   set -x
fi

# Create the RUNTESTS directory
# Start by getting the full path
_runtests="$(realpath "${_runtests}")"
if [[ "${_verbose}" == "true" ]]; then
    printf "Creating RUNTESTS in %s\n\n" "${_runtests}"
fi
if [[ ! -d "${_runtests}" ]]; then
   set +e
   if ! mkdir -p "${_runtests}" "${_verbose_flag}"; then
      echo "Unable to create RUNTESTS directory: ${_runtests}"
      echo "Rerun with -h for usage examples."
      exit 4
   fi
   set -e
else
   echo "The RUNTESTS directory ${_runtests} already exists."
   echo "Would you like to remove it?"
   _attempts=0
   while read -r _from_stdin; do
      if [[ "${_from_stdin^^}" =~ Y ]]; then
         rm -rf "${_runtests}"
         mkdir -p "${_runtests}"
         break
      elif [[ "${_from_stdin^^}" =~ N ]]; then
         echo "Continuing without removing the directory"
         break
      else
         (( _attempts+=1 ))
         if [[ ${_attempts} == 3 ]]; then
            echo "Exiting."
            exit 99
         fi
         echo "'${_from_stdin}' is not a valid choice.  Please type Y or N"
      fi
   done
fi

# Empty the _yaml_list array if -G, -E, and/or -S were selected
if [[ "${_run_all_gfs}" == "true" || \
      "${_run_all_gefs}" == "true" || \
      "${_run_all_sfs}" == "true" ]]; then

   # Raise an error if the user specified a yaml list and any of -G -E -S
   if [[ "${_specified_yaml_list}" == "true" ]]; then
      echo "Ambiguous case selection."
      echo "Please select which tests to run explicitly with -y \"list of tests\" or"
      echo "by specifying -G (all GFS), -E (all GEFS), and/or -S (all SFS), but not both."
      exit 3
   fi

   _yaml_list=()
fi

# Set HOMEgfs if it wasn't set by the user
if [[ "${_specified_home}" == "false" ]]; then
   script_relpath="$(dirname "${BASH_SOURCE[0]}")"
   HOMEgfs="$(cd "${script_relpath}/.." && pwd)"
   if [[ "${_verbose}" == "true" ]]; then
       printf "Setting HOMEgfs to %s\n\n" "${HOMEgfs}"
   fi
fi

# Set the _yaml_dir to HOMEgfs/ci/cases/pr if not explicitly set
if [[ "${_specified_yaml_dir}" == false ]]; then
    _yaml_dir="${HOMEgfs}/ci/cases/pr"
fi

function select_all_yamls()
{
   # A helper function to select all of the YAMLs for a specified system (gfs, gefs, sfs)

   # This function is called if -G, -E, or -S are specified either with or without a
   # specified YAML list.  If a YAML list was specified, this function will remove any
   # YAMLs in that list that are not for the specified system and issue warnings when
   # doing so.

   _system="${1}"
   _SYSTEM="${_system^^}"

   # Bash cannot return an array from a function and any edits are descoped at
   # the end of the function, so use a nameref instead.
   local -n _nameref_yaml_list="${2}"

   if [[ "${_specified_yaml_list}" == false ]]; then
      # Start over with an empty _yaml_list
      _nameref_yaml_list=()
      printf "Running all %s cases in %s\n\n" "${_SYSTEM}" "${_yaml_dir}"
      _yaml_count=0

      for _full_path in "${_yaml_dir}/"*.yaml; do
         # Skip any YAML that isn't supported
         if ! grep -l "system: *${_system}" "${_full_path}" >& /dev/null ; then continue; fi

         # Select only cases for the specified system
         _yaml=$(basename "${_full_path}")
         # Strip .yaml from the filename to get the case name
         _yaml="${_yaml//.yaml/}"
         _nameref_yaml_list+=("${_yaml}")
         if [[ "${_verbose}" == true ]]; then
             echo "Found test ${_yaml//.yaml/}"
         fi
         (( _yaml_count+=1 ))
      done

      if [[ ${_yaml_count} -eq 0 ]]; then
         read -r -d '' _message << EOM
            "No YAMLs or ${_SYSTEM} were found in the directory (${_yaml_dir})!"
            "Please check the directory/YAMLs and try again"
EOM
         echo "${_message}"
         if [[ "${_set_email}" == true ]]; then
            send_email "${_message}"
         fi
         exit 6
      fi
   else
      # Check if the specified yamls are for the specified system
      for i in "${!_nameref_yaml_list}"; do
         _yaml="${_nameref_yaml_list[${i}]}"
         _found=$(grep -l "system: *${system}" "${_yaml_dir}/${_yaml}.yaml")
         if [[ -z "${_found}" ]]; then
            echo "WARNING the yaml file ${_yaml_dir}/${_yaml}.yaml is not designed for the ${_SYSTEM} system"
            echo "Removing this yaml from the set of cases to run"
            unset '_nameref_yaml_list[${i}]'
            # Sleep 2 seconds to give the user a moment to react
            sleep 2s
         fi
      done
   fi
}

# Check if running all GEFS cases
if [[ "${_run_all_gefs}" == "true" ]]; then
   # Append -w to build_all.sh flags if -E was specified
   _build_flags="${_build_flags} gefs "

   declare -a _gefs_yaml_list
   select_all_yamls "gefs" "_gefs_yaml_list"
   _yaml_list=("${_yaml_list[@]}" "${_gefs_yaml_list[@]}")
fi

# Check if running all GFS cases
if [[ "${_run_all_gfs}" == "true" ]]; then
   _build_flags="${_build_flags} gfs "

   declare -a _gfs_yaml_list
   select_all_yamls "gfs" "_gfs_yaml_list"
   _yaml_list=("${_yaml_list[@]}" "${_gfs_yaml_list[@]}")
fi

# Check if running all SFS cases
if [[ "${_run_all_sfs}" == "true" ]]; then
   _build_flags="${_build_flags} sfs "

   declare -a _gfs_yaml_list
   select_all_yamls "sfs" "_sfs_yaml_list"
   _yaml_list=("${_yaml_list[@]}" "${_sfs_yaml_list[@]}")
fi

# Loading modules sometimes raises unassigned errors, so disable checks
set +u
if [[ "${_verbose}" == "true" ]]; then
    printf "Loading modules\n\n"
fi
if [[ "${_debug}" == "true" ]]; then
    set +x
fi
if ! source "${HOMEgfs}/workflow/gw_setup.sh" >& stdout; then
   cat stdout
   echo "Failed to source ${HOMEgfs}/workflow/gw_setup.sh!"
   exit 7
fi
if [[ "${_verbose}" == "true" ]]; then
    cat stdout
fi
rm -f stdout
if [[ "${_debug}" == "true" ]]; then
    set -x
fi
set -u
machine=${MACHINE_ID}
platform_config="${HOMEgfs}/ci/platforms/config.${machine}"
if [[ -f "${platform_config}" ]]; then
    . "${HOMEgfs}/ci/platforms/config.${machine}"
else
   if [[ "${_set_account}" == "false" ]] ; then
      echo "ERROR Unknown HPC account!  Please use the -A option to specify."
      exit 11
   fi
fi

# If _yaml_dir is not set, set it to $HOMEgfs/ci/cases/pr
if [[ -z ${_yaml_dir} ]]; then
   _yaml_dir="${HOMEgfs}/ci/cases/pr"
fi

# Update submodules if requested
if [[ "${_update_submods}" == "true" ]]; then
   printf "Updating submodules\n\n"
   _git_cmd="git submodule update --init --recursive -j 10"
   if [[ "${_verbose}" == true ]]; then
      ${_git_cmd}
   else
      if ! ${_git_cmd} 2> stderr 1> stdout; then
         cat stdout stderr
         read -r -d '' _message << EOM
The git command (${_git_cmd}) failed with a non-zero status
Messages from git:
EOM
         _newline=$'\n'
         _message="${_message}${_newline}$(cat stdout stderr)"
         if [[ "${_set_email}" == true ]]; then
            send_email "${_message}"
         fi
         echo "${_message}"
         rm -f stdout stderr
         exit 8
      fi
      rm -f stdout stderr
   fi
fi

# Build the system if requested
if [[ "${_build}" == "true" ]]; then
   printf "Building via build_all.sh %s\n\n" "${_build_flags}"
   # Let the output of build_all.sh go to stdout regardless of verbose options
   #shellcheck disable=SC2086,SC2248
   ${HOMEgfs}/sorc/build_all.sh ${_verbose_flag} ${_build_flags}
fi

# Link the workflow silently unless there's an error
if [[ "${_verbose}" == true ]]; then
    printf "Linking the workflow\n\n"
fi
if ! "${HOMEgfs}/sorc/link_workflow.sh" >& stdout; then
   cat stdout
   echo "link_workflow.sh failed!"
   if [[ "${_set_email}" == true ]]; then
      _stdout=$(cat stdout)
      send_email "link_workflow.sh failed with the message"$'\n'"${_stdout}"
   fi
   rm -f stdout
   exit 9
fi
rm -f stdout

# Configure the environment for running create_experiment.py
if [[ "${_verbose}" == true ]]; then
    printf "Setting up the environment to run create_experiment.py\n\n"
fi
for i in "${!_yaml_list[@]}"; do
   _yaml_file="${_yaml_dir}/${_yaml_list[${i}]}.yaml"
   # Verify that the YAMLs are where we are pointed
   if [[ ! -s "${_yaml_file}" ]]; then
      echo "The YAML file ${_yaml_file} does not exist!"
      echo "Please check the input yaml list and directory."
      if [[ "${_set_email}" == true ]]; then
         read -r -d '' _message << EOM
         generate_workflows.sh failed to find one of the specified YAMLs (${_yaml_file})
         in the specified YAML directory (${_yaml_dir}).
EOM
         send_email "${_message}"
      fi
      exit 10
   fi

   # Strip any unsupported tests
   _unsupported_systems=$(sed '1,/skip_ci_on_hosts/ d' "${_yaml_file}")

   for _system in ${_unsupported_systems}; do
      if [[ "${_system}" =~ ${machine} ]]; then
         if [[ "${_specified_yaml_list}" == true ]]; then
            printf "WARNING %s is unsupported on %s, removing from case list\n\n" "${_yaml}" "${machine}"
            if [[ "${_set_email}" == true ]]; then
               _final_message="${_final_message:-}"$'\n'"The specified YAML case ${_yaml} is not supported on ${machine} and was skipped."
            fi
            # Sleep so the user has a moment to notice
            sleep 2s
         fi
         unset '_yaml_list[${i}]'
         break
      fi
   done
done

# Update the account if specified
if [[ "${_set_account}" == true ]] ; then
   export HPC_ACCOUNT=${_hpc_account}
   if [[ "${_verbose}" == true ]]; then
      printf "Setting HPC account to %s\n\n" "${HPC_ACCOUNT}"
   fi
fi

# Create the experiments
rm -f "tests.cron" "${_verbose_flag}"
echo "Running create_experiment.py for ${#_yaml_list[@]} cases"

if [[ "${_verbose}" == true ]]; then
    printf "Selected cases: %s\n\n" "${_yaml_list[*]}"
fi
for _case in "${_yaml_list[@]}"; do
   if [[ "${_verbose}" == false ]]; then
       echo "${_case}"
   fi
   _pslot="${_case}${_tag}"
   _create_exp_cmd="./create_experiment.py -y ../ci/cases/pr/${_case}.yaml --overwrite"
   if [[ "${_verbose}" == true ]]; then
      pslot=${_pslot} RUNTESTS=${_runtests} ${_create_exp_cmd}
   else
      if ! pslot=${_pslot} RUNTESTS=${_runtests} ${_create_exp_cmd} 2> stderr 1> stdout; then
         _output=$(cat stdout stderr)
         _message="The create_experiment command (${_create_exp_cmd}) failed with a non-zero status.  Output:"
         _message="${_message}"$'\n'"${_output}"
         if [[ "${_set_email}" == true ]]; then
            send_email "${_message}"
         fi
         echo "${_message}"
         rm -f stdout stderr
         exit 12
      fi
      rm -f stdout stderr
   fi
   # Check if this experiment is using cron or scron
   cron_file="${_runtests}/EXPDIR/${_pslot}/${_pslot}.crontab"
   scron_sh_file="${_runtests}/EXPDIR/${_pslot}/${_pslot}.scron.sh"
   if [[ -f "${scron_sh_file}" ]]; then
      _use_scron=true
      _crontab_cmd="scrontab"
   elif [[ -f "${cron_file}" ]]; then
      _use_scron=false
      _crontab_cmd="crontab"
   else
      echo "Could not find a crontab file for case ${_pslot}!"
      echo "Expected to find ${cron_file}"
      exit 13
   fi

   if [[ "${_use_scron}" == true ]]; then
      {
      grep "^#.*${_pslot}" "${_runtests}/EXPDIR/${_pslot}/${_pslot}.crontab"
      grep "^#SCRON" "${cron_file}"
      grep "${scron_sh_file}" "${_runtests}/EXPDIR/${_pslot}/${_pslot}.crontab"
      } >> tests.cron
   else
      grep "${_pslot}" "${_runtests}/EXPDIR/${_pslot}/${_pslot}.crontab" >> tests.cron
   fi
done
echo

# Update the cron
if [[ "${_update_cron}" == "true" ]]; then
   printf "Updating the existing crontab\n\n"
   echo
   rm -f existing.cron final.cron "${_verbose_flag}"
   touch existing.cron final.cron

   ${_crontab_cmd} -l | grep -v "no crontab for" > existing.cron || true

   if [[ "${_debug}" == "true" ]]; then
      echo "Existing crontab: "
      echo "#######################"
      cat existing.cron
      echo "#######################"
   fi

   if [[ "${_set_email}" == "true" ]]; then
      # Replace the existing email in the crontab
      if [[ "${_verbose}" == "true" ]]; then
         printf "Updating crontab/scrontab email to %s\n\n" "${_email}"
      fi

      if [[ "${_use_scron}" == true ]]; then
         sed -i "s/.*--mail-user.*/#SCRON --mail-user=\"${_email}\"/" tests.cron
      else
         sed -i "s/^MAILTO.*/MAILTO=\"${_email}\"/" existing.cron
      fi
   fi

   cat existing.cron tests.cron >> final.cron

   if [[ "${_verbose}" == "true" ]]; then
      echo "Setting crontab to:"
      echo "#######################"
      cat final.cron
      echo "#######################"
   fi

   ${_crontab_cmd} final.cron
else
   _message="Add the following to your crontab or scrontab to start running:"
   _cron_tests=$(cat tests.cron)
   _message="${_message}"$'\n'"${_cron_tests}"
   echo "${_message}"
   if [[ "${_set_email}" == true ]]; then
      final_message="${final_message:-}"$'\n'"${_message}"
   fi
fi

# Cleanup
if [[ "${_debug}" == "false" ]]; then
    rm -f final.cron existing.cron tests.cron "${_verbose_flag}"
fi

echo "Success!!"
if [[ "${_set_email}" == true && "${_debug}" == "true" ]]; then
   final_message=$'Success!\n'"${final_message:-}"
   _subject="generate_workflow.sh completed successfully" send_email "${final_message}"
fi
