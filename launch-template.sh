#!/bin/bash
# shellcheck disable=SC2206

#SBATCH --mail-type=END
##SBATCH --mail-user=9147037394@vtext.com
#SBATCH --job-name=${JOB_NAME}
#SBATCH --output=/home/garbus/evotrade/runs/${JOB_NAME}.log
#SBATCH --account=guest
#SBATCH --time=24:00:00
#SBATCH --partition=guest-compute
#SBATCH --ntasks=6
#SBATCH --cpus-per-task=30
#SBATCH --mem-per-cpu=3GB

source /home/garbus/.bashrc
conda activate trade
julia evotrade.jl $(cat /home/garbus/evotrade/afiles/${JOB_NAME}.arg)