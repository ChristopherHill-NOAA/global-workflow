#!/usr/bin/env python3

import os

from pygfs.task.archive import Archive
from wxflow import AttrDict, Logger, cast_strdict_as_dtypedict, chdir, logit

# initialize root logger
logger = Logger(level=os.environ.get("LOGGING_LEVEL", "DEBUG"), colored_log=True)


@logit(logger)
def main():

    config = cast_strdict_as_dtypedict(os.environ)

    # Instantiate the Archive object
    archive = Archive(config)

    # Pull out all the configuration keys needed to run the rest of archive steps
    keys = ['ATARDIR', 'current_cycle', 'IAUFHRS', 'RUN', 'PDY',
            'PSLOT', 'HPSSARCH', 'LOCALARCH', 'ROTDIR', 'PARMgfs',
            'ARCDIR', 'SDATE', 'MODE', 'ENSGRP', 'NMEM_EARCGRP',
            'NMEM_ENS', 'DO_CALC_INCREMENT_ENKF_GFS', 'DO_JEDIATMENS',
            'lobsdiag_forenkf', 'FHMIN_ENKF', 'FHMAX_ENKF_GFS',
            'FHOUT_ENKF_GFS', 'FHMAX_ENKF', 'FHOUT_ENKF', 'ENKF_SPREAD',
            'restart_interval_enkfgdas', 'restart_interval_enkfgfs',
            'DOHYBVAR', 'DOIAU_ENKF', 'IAU_OFFSET', 'DOIAU', 'DO_CA',
            'DO_CALC_INCREMENT', 'assim_freq', 'ARCH_CYC', 'DO_JEDISNOWDA',
            'ARCH_WARMICFREQ', 'ARCH_FCSTICFREQ',
            'IAUFHRS_ENKF', 'NET', 'NMEM_ENS_GFS']

    archive_dict = AttrDict()
    for key in keys:
        archive_dict[key] = archive.task_config.get(key)
        if archive_dict[key] is None:
            print(f"Warning: key ({key}) not found in task_config!")

    # Also import all COMIN* directory and template variables
    for key in archive.task_config.keys():
        if key.startswith("COM"):
            archive_dict[key] = archive.task_config[key]

    with chdir(config.ROTDIR):

        # Determine which archives to create
        atardir_sets = archive.configure_tars(archive_dict)

        # Create the backup tarballs and store in ATARDIR
        for atardir_set in atardir_sets:
            archive.execute_backup_dataset(atardir_set)


if __name__ == '__main__':
    main()
