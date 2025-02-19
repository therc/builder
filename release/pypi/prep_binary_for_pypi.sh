#!/usr/bin/env bash

# Preps binaries for publishing to pypi by removing the
# version suffix we normally add for all binaries
# (outside of default ones, CUDA 10.2 currently)

# Usage is:
# $ prep_binary_for_pypy.sh <path_to_whl_file> <path_to_multiple_whl_files>

# Will output a whl in your current directory

set -eou pipefail
shopt -s globstar

# Function copied from manywheel/build_common.sh
make_wheel_record() {
    FPATH=$1
    if echo $FPATH | grep RECORD >/dev/null 2>&1; then
        # if the RECORD file, then
        echo "$FPATH,,"
    else
        HASH=$(openssl dgst -sha256 -binary $FPATH | openssl base64 | sed -e 's/+/-/g' | sed -e 's/\//_/g' | sed -e 's/=//g')
        FSIZE=$(ls -nl $FPATH | awk '{print $5}')
        echo "$FPATH,sha256=$HASH,$FSIZE"
    fi
}

OUTPUT_DIR=${OUTPUT_DIR:-$(pwd)}

tmp_dir="$(mktemp -d)"
trap 'rm -rf ${tmp_dir}' EXIT

DEBUG=${DEBUG:-}

for whl_file in "$@"; do
    whl_file=$(realpath "${whl_file}")
    whl_dir="${tmp_dir}/$(basename "${whl_file}")_unzipped"
    mkdir -pv "${whl_dir}"
    (
        set -x
        unzip -q "${whl_file}" -d "${whl_dir}"
    )
    version_with_suffix=$(grep '^Version:' "${whl_dir}"/*/METADATA | cut -d' ' -f2)
    version_with_suffix_escaped=${version_with_suffix/+/%2B}

    # Remove all suffixed +bleh versions
    version_no_suffix=${version_with_suffix/+*/}
    new_whl_file=${OUTPUT_DIR}/$(basename "${whl_file/${version_with_suffix_escaped}/${version_no_suffix}}")
    dist_info_folder=$(find "${whl_dir}" -type d -name '*.dist-info' | head -1)
    basename_dist_info_folder=$(basename "${dist_info_folder}")
    dirname_dist_info_folder=$(dirname "${dist_info_folder}")
    (
        set -x

        # Special build with pypi cudnn remove it from version
        if [[ $whl_file == *"with.pypi.cudnn"* ]]; then
            rm -rf "${whl_dir}/caffe2"
            rm -rf "${whl_dir}"/torch/lib/libnvrtc*
            find "${whl_dir}/torch/include/caffe2" -maxdepth 1 -mindepth 1 -type d|grep -v serialize|xargs rm -rf
            sed -i -e "s/Requires-Dist: nvidia-cuda-runtime-cu11/Requires-Dist: nvidia-cuda-runtime-cu11 (==11.7.99)/" "${whl_dir}"/*/METADATA
            sed -i -e "/^Requires-Dist: nvidia-cublas-cu11 (==11.10.3.66).*/a Requires-Dist: nvidia-cuda-nvrtc-cu11 (==11.7.99)" "${whl_dir}"/*/METADATA

            sed -i -e "s/-with-pypi-cudnn//g" "${whl_dir}/torch/version.py"
            find "${whl_dir}/torch/" -maxdepth 1 -type f -name "*.so*" | while read sofile; do
                patchelf --set-rpath '$ORIGIN/../../nvidia/cublas/lib:$ORIGIN/../../nvidia/cudnn/lib:$ORIGIN/../../nvidia/cuda_nvrtc/lib:$ORIGIN:$ORIGIN/lib' \
                    --force-rpath $sofile
                patchelf --print-rpath $sofile
            done

            find "${whl_dir}/torch/lib" -maxdepth 1 -type f -name "*.so*" | while read sofile; do
                patchelf --set-rpath '$ORIGIN/../../nvidia/cublas/lib:$ORIGIN/../../nvidia/cudnn/lib:$ORIGIN/../../nvidia/cuda_nvrtc/lib:$ORIGIN' \
                    --force-rpath $sofile
                patchelf --print-rpath $sofile
            done
            patchelf --replace-needed libnvrtc-d833c4f3.so.11.2 libnvrtc.so.11.2 "${whl_dir}/torch/lib/libcaffe2_nvrtc.so"
        fi

        find "${dist_info_folder}" -type f -exec sed -i "s!${version_with_suffix}!${version_no_suffix}!" {} \;
        # Moves distinfo from one with a version suffix to one without
        # Example: torch-1.8.0+cpu.dist-info => torch-1.8.0.dist-info
        mv "${dist_info_folder}" "${dirname_dist_info_folder}/${basename_dist_info_folder/${version_with_suffix}/${version_no_suffix}}"
        cd "${whl_dir}"

        (
            set +x
            # copied from manywheel/build_common.sh
            # regenerate the RECORD file with new hashes
            record_file="${dirname_dist_info_folder}/${basename_dist_info_folder/${version_with_suffix}/${version_no_suffix}}/RECORD"
            if [[ -e $record_file ]]; then
                echo "Generating new record file $record_file"
                rm -f $record_file
                # generate records for folders in wheel
                find * -type f | while read fname; do
                    echo $(make_wheel_record $fname) >>$record_file
                done
            fi
        )

        zip -qr9 "${new_whl_file}" .
    )
done
