#!/bin/bash

set -xe

OS=$(uname)
if [ "${OS}" = "Linux" ]; then
    export DS_ROOT_TASK=${HOME}
fi;

if [ "${OS}" = "Darwin" ]; then
    export DS_ROOT_TASK=${TASKCLUSTER_TASK_DIR}
    export SWIG_LIB="$(find ${DS_ROOT_TASK}/homebrew/Cellar/swig/ -type f -name "swig.swg" | xargs dirname)"

    # It seems chaining |export DYLD_LIBRARY_PATH=...| does not work, maybe
    # because of SIP? Who knows ...
    if [ ! -z "${EXTRA_ENV}" ]; then
        eval "export ${EXTRA_ENV}"
    fi;
fi;

export TASKCLUSTER_ARTIFACTS=${TASKCLUSTER_ARTIFACTS:-/tmp/artifacts}
export TASKCLUSTER_TMP_DIR=${TASKCLUSTER_TMP_DIR:-/tmp}

mkdir -p ${TASKCLUSTER_TMP_DIR} || true

export DS_TFDIR=${DS_ROOT_TASK}/DeepSpeech/tf
export DS_DSDIR=${DS_ROOT_TASK}/DeepSpeech/ds

export BAZEL_CTC_TARGETS="//native_client:libctc_decoder_with_kenlm.so"

export EXTRA_AOT_CFLAGS=""
export EXTRA_AOT_LDFLAGS="-L${DS_TFDIR}/bazel-bin/tensorflow/compiler/xla -L${DS_TFDIR}/bazel-bin/tensorflow/compiler/tf2xla -L${DS_TFDIR}/bazel-bin/tensorflow/compiler/aot -L${DS_TFDIR}/bazel-bin/tensorflow/compiler/xla/service/cpu"
export EXTRA_AOT_LIBS="-ldeepspeech_model -lxla_compiled_cpu_function -lruntime -lruntime_matmul -lruntime_matvec -lexecutable_run_options"

# FIXME:
# Previously, with r1.3, we could use timesteps of 64
# With r1.4 it seems to eat too much resources at tfcompile step
export BAZEL_AOT_BUILD_FLAGS="--define=DS_NATIVE_MODEL=1 --define=DS_MODEL_TIMESTEPS=16"
export BAZEL_AOT_TARGETS="
//native_client:deepspeech_model
//tensorflow/compiler/aot:runtime
//tensorflow/compiler/xla/service/cpu:runtime_matmul
//tensorflow/compiler/xla/service/cpu:runtime_matvec
//tensorflow/compiler/xla:executable_run_options
//tensorflow/compiler/tf2xla:xla_compiled_cpu_function
"

model_source=${DEEPSPEECH_TEST_MODEL}
model_name=$(basename "${model_source}")

SUPPORTED_PYTHON_VERSIONS=${SUPPORTED_PYTHON_VERSIONS:-2.7.13 3.4.6 3.5.3 3.6.2}
# 7.10.0 and 8.0.0 targets fails to build
# > ../deepspeech_wrap.cxx:966:23: error: 'WeakCallbackData' in namespace 'v8' does not name a type
SUPPORTED_NODEJS_VERSIONS=${SUPPORTED_NODEJS_VERSIONS:-4.8.6 5.12.0 6.12.0 7.10.1 8.9.1 9.2.0}

assert_correct_inference()
{
  phrase=$1
  expected=$2

  if [ -z "${phrase}" -o -z "${expected}" ]; then
      echo "One or more empty strings:"
      echo "phrase: <${phrase}>"
      echo "expected: <${expected}>"
      return 1
  fi;

  if [ "${phrase}" = "${expected}" ]; then
      echo "Proper output has been produced:"
      echo "${phrase}"
      return 0
  else
      echo "!! Non matching output !!"
      echo "got: <${phrase}>"
      echo "xxd:"; echo "${phrase}" | xxd
      echo "-------------------"
      echo "expected: <${expected}>"
      echo "xxd:"; echo "${expected}" | xxd
      return 1
  fi;
}

assert_correct_ldc93s1()
{
  assert_correct_inference "$1" "she had your dark suit in greasy wash water all year"
}

assert_correct_ldc93s1_prodmodel()
{
  assert_correct_inference "$1" "she had the duck so ingrecywachworallyear"
}

assert_correct_ldc93s1_somodel()
{
    somodel_nolm=$1
    somodel_withlm=$2

    # We want to be able to return non zero value from the function, while not
    # failing the whole execution
    set +e

    assert_correct_ldc93s1 "${somodel_nolm}"
    so_nolm=$?

    assert_correct_ldc93s1 "${somodel_withlm}"
    so_lm=$?

    set -e

    # We accept that with no LM there may be errors, but we do not accept that
    # for LM. For now.
    if [ ${so_lm} -eq 1 ] && [ ${so_nolm} -eq 1 -o ${so_nolm} -eq 0 ];
    then
        exit 1
    elif [ ${so_lm} -eq 0 ] && [ ${so_nolm} -eq 1 -o ${so_nolm} -eq 0 ];
    then
        exit 0
    else
        echo "Unexpected status"
        exit 2
    fi
}

generic_download_tarxz()
{
  target_dir=$1
  url=$2

  if [ -z "${target_dir}" -o -z "${url}" ]; then
    echo "Empty name for target directory or URL:"
    echo " target_dir=${target_dir}"
    echo " url=${url}"
    exit 1
  fi;

  mkdir -p ${target_dir} || true

  wget ${url} -O - | pixz -d | tar -C ${target_dir} -xf -
}

download_native_client_files()
{
  generic_download_tarxz "$1" "${DEEPSPEECH_ARTIFACTS_ROOT}/native_client.tar.xz"
}

download_aot_model_files()
{
  generic_download_tarxz "$1" "${DEEPSPEECH_AOT_ARTIFACTS_ROOT}/native_client.tar.xz"
}

download_ctc_kenlm()
{
  generic_download_tarxz "$1" "${DEEPSPEECH_LIBCTC}"
}

download_data()
{
  wget ${model_source} -O ${TASKCLUSTER_TMP_DIR}/${model_name}
  wget https://catalog.ldc.upenn.edu/desc/addenda/LDC93S1.wav -O ${TASKCLUSTER_TMP_DIR}/LDC93S1.wav
  cp ${DS_ROOT_TASK}/DeepSpeech/ds/data/alphabet.txt ${TASKCLUSTER_TMP_DIR}/alphabet.txt
  cp ${DS_ROOT_TASK}/DeepSpeech/ds/data/lm/lm.binary ${TASKCLUSTER_TMP_DIR}/lm.binary
  cp ${DS_ROOT_TASK}/DeepSpeech/ds/data/lm/trie ${TASKCLUSTER_TMP_DIR}/trie
}

download_material()
{
  target_dir=$1
  maybe_aot=$2

  if [ "${maybe_aot}" = "--aot" ]; then
    download_aot_model_files "${target_dir}"
  else
    download_native_client_files "${target_dir}"
  fi

  download_data

  ls -hal ${TASKCLUSTER_TMP_DIR}/${model_name} ${TASKCLUSTER_TMP_DIR}/LDC93S1.wav ${TASKCLUSTER_TMP_DIR}/alphabet.txt
}

install_pyenv()
{
  if [ -z "${PYENV_ROOT}" ]; then
    echo "No PYENV_ROOT set";
    exit 1;
  fi;

  git clone --quiet https://github.com/pyenv/pyenv.git ${PYENV_ROOT}
  pushd ${PYENV_ROOT}
    git checkout --quiet 0c909f7457a027276a1d733d78bfbe70ba652047
  popd
  eval "$(pyenv init -)"
}

install_pyenv_virtualenv()
{
  PYENV_VENV=$1

  if [ -z "${PYENV_VENV}" ]; then
    echo "No PYENV_VENV set";
    exit 1;
  fi;

  git clone --quiet https://github.com/pyenv/pyenv-virtualenv.git ${PYENV_VENV}
  pushd ${PYENV_VENV}
      git checkout --quiet 27270877575fe8c3e7be5385b8b6a1e4089b39aa
  popd
  eval "$(pyenv virtualenv-init -)"
}

do_get_model_parameters()
{
  local __result=$2
  model_url=$1
  model_file=/tmp/$(basename "${model_url}")

  if [ -z "${model_url}" ]; then
    echo "Empty URL for model"
    exit 1
  fi;

  wget "${model_url}" -O "${model_file}"
  wget "${SUMMARIZE_GRAPH_BINARY}" -O "/tmp/summarize_graph"
  wget "${LIBTENSORFLOW_FRAMEWORK}" -O "/tmp/libtensorflow_framework.so"

  chmod +x /tmp/summarize_graph

  if [ ! -f "${model_file}" ]; then
    echo "No such model: ${model_file}"
    exit 1
  fi;

  model_width=$(/tmp/summarize_graph --in_graph="${model_file}" | grep "inputs" | grep -Eo "shape=\[\?,\?,[[:digit:]]+" | cut -d',' -f3)

  eval $__result="'--define=DS_MODEL_FRAMESIZE=${model_width} --define=DS_MODEL_FILE=${model_file}'"
}

do_bazel_build()
{
  cd ${DS_ROOT_TASK}/DeepSpeech/tf
  eval "export ${BAZEL_ENV_FLAGS}"
  PATH=${DS_ROOT_TASK}/bin/:$PATH bazel ${BAZEL_OUTPUT_USER_ROOT} build \
    -c opt ${BAZEL_BUILD_FLAGS} ${BAZEL_TARGETS}
}

do_deepspeech_binary_build()
{
  cd ${DS_DSDIR}
  make -C native_client/ \
    TARGET=${SYSTEM_TARGET} \
    TFDIR=${DS_TFDIR} \
    RASPBIAN=/tmp/multistrap-raspbian-jessie \
    EXTRA_CFLAGS="${EXTRA_LOCAL_CFLAGS}" \
    EXTRA_LDFLAGS="${EXTRA_LOCAL_LDFLAGS}" \
    EXTRA_LIBS="${EXTRA_LOCAL_LIBS}" \
    deepspeech
}

do_deepspeech_python_build()
{
  rename_to_gpu=$1

  unset PYTHON_BIN_PATH
  unset PYTHONPATH
  export PYENV_ROOT="${DS_ROOT_TASK}/DeepSpeech/.pyenv"
  export PATH="${PYENV_ROOT}/bin:$PATH"

  install_pyenv "${PYENV_ROOT}"
  install_pyenv_virtualenv "$(pyenv root)/plugins/pyenv-virtualenv"

  mkdir -p wheels

  SETUP_FLAGS=""
  if [ "${rename_to_gpu}" ]; then
    SETUP_FLAGS="--project_name deepspeech-gpu"
  fi

  for pyver in ${SUPPORTED_PYTHON_VERSIONS}; do
    pyenv install ${pyver}
    pyenv virtualenv ${pyver} deepspeech
    source ${PYENV_ROOT}/versions/${pyver}/envs/deepspeech/bin/activate

    EXTRA_CFLAGS="${EXTRA_LOCAL_CFLAGS}" EXTRA_LDFLAGS="${EXTRA_LOCAL_LDFLAGS}" EXTRA_LIBS="${EXTRA_LOCAL_LIBS}" make -C native_client/ \
      TARGET=${SYSTEM_TARGET} \
      RASPBIAN=/tmp/multistrap-raspbian-jessie \
      TFDIR=${DS_TFDIR} \
      SETUP_FLAGS="${SETUP_FLAGS}" \
      bindings-clean bindings

    cp native_client/dist/*.whl wheels

    make -C native_client/ bindings-clean

    deactivate
    pyenv uninstall --force deepspeech
  done;
}

do_deepspeech_nodejs_build()
{
  rename_to_gpu=$1

  npm update && npm install node-gyp node-pre-gyp

  export PATH="$(npm root)/.bin/:$PATH"

  for node in ${SUPPORTED_NODEJS_VERSIONS}; do
    EXTRA_CFLAGS="${EXTRA_LOCAL_CFLAGS}" EXTRA_LDFLAGS="${EXTRA_LOCAL_LDFLAGS}" EXTRA_LIBS="${EXTRA_LOCAL_LIBS}" make -C native_client/javascript \
      TARGET=${SYSTEM_TARGET} \
      RASPBIAN=/tmp/multistrap-raspbian-jessie \
      TFDIR=${DS_TFDIR} \
      NODE_ABI_TARGET=--target=$node \
      clean node-wrapper
  done;

  if [ "${rename_to_gpu}" ]; then
    make -C native_client/javascript clean npm-pack PROJECT_NAME=deepspeech-gpu
  else
    make -C native_client/javascript clean npm-pack
  fi

  tar -czf native_client/javascript/wrapper.tar.gz \
    -C native_client/javascript/ lib/
}

do_deepspeech_npm_package()
{
  cd ${DS_DSDIR}

  npm update && npm install node-gyp node-pre-gyp

  export PATH="$(npm root)/.bin/:$PATH"

  all_tasks="$(curl -s https://queue.taskcluster.net/v1/task/${TASK_ID} | python -c 'import json; import sys; print(" ".join(json.loads(sys.stdin.read())["dependencies"]));')"

  for dep in ${all_tasks}; do
    curl -L https://queue.taskcluster.net/v1/task/${dep}/artifacts/public/wrapper.tar.gz | tar -C native_client/javascript -xzvf -
  done;

  make -C native_client/javascript clean npm-pack
}

package_native_client()
{
  tensorflow_dir=${DS_TFDIR}
  deepspeech_dir=${DS_DSDIR}
  artifacts_dir=${TASKCLUSTER_ARTIFACTS}
  artifact_name=$1

  if [ ! -d ${tensorflow_dir} -o ! -d ${deepspeech_dir} -o ! -d ${artifacts_dir} ]; then
    echo "Missing directory. Please check:"
    echo "tensorflow_dir=${tensorflow_dir}"
    echo "deepspeech_dir=${deepspeech_dir}"
    echo "artifacts_dir=${artifacts_dir}"
    exit 1
  fi;

  if [ -z "${artifact_name}" ]; then
    echo "Please specify artifact name."
  fi;

  if [ -f "${tensorflow_dir}/bazel-bin/native_client/libdeepspeech_model.so" ]; then
    tar -cf - \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/ libtensorflow_cc.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/ libtensorflow_framework.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/compiler/aot/ libruntime.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/compiler/xla/service/cpu/ libruntime_matmul.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/compiler/xla/service/cpu/ libruntime_matvec.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/compiler/xla/ libexecutable_run_options.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/compiler/tf2xla/ libxla_compiled_cpu_function.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ generate_trie \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libctc_decoder_with_kenlm.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libdeepspeech.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libdeepspeech_model.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libdeepspeech_utils.so \
      -C ${deepspeech_dir}/ LICENSE \
      -C ${deepspeech_dir}/native_client/ deepspeech \
      -C ${deepspeech_dir}/native_client/kenlm/ README.mozilla \
      | pixz -9 > "${artifacts_dir}/${artifact_name}"
  else
    tar -cf - \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/ libtensorflow_cc.so \
      -C ${tensorflow_dir}/bazel-bin/tensorflow/ libtensorflow_framework.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ generate_trie \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libctc_decoder_with_kenlm.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libdeepspeech.so \
      -C ${tensorflow_dir}/bazel-bin/native_client/ libdeepspeech_utils.so \
      -C ${deepspeech_dir}/ LICENSE \
      -C ${deepspeech_dir}/native_client/ deepspeech \
      -C ${deepspeech_dir}/native_client/kenlm/ README.mozilla \
      | pixz -9 > "${artifacts_dir}/${artifact_name}"
  fi;
}
