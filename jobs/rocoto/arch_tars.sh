#! /usr/bin/env bash

source "${HOMEgfs}/ush/preamble.sh"

###############################################################
# Source FV3GFS workflow modules
. "${HOMEgfs}"/ush/load_fv3gfs_modules.sh
status=$?
if [[ ${status} -ne 0 ]]; then
    exit "${status}"
fi

###############################################################
# setup python path for workflow utilities and tasks
PYTHONPATH="${PYTHONPATH:+${PYTHONPATH}:}${HOMEgfs}/ush/python"
export PYTHONPATH

export job="arch_tars"
export jobid="${job}.$$"

###############################################################
# Execute the JJOB
"${HOMEgfs}"/jobs/JGLOBAL_ARCHIVE_TARS
status=$?

exit "${status}"
