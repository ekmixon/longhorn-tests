#!/usr/bin/env bash

set -x

# create and clean tmpdir
TMPDIR="/tmp/longhorn"
mkdir -p ${TMPDIR}
rm -rf "${TMPDIR}/"

LONGHORN_NAMESPACE="longhorn-system"

# Longhorn version tag (e.g v1.1.0), use "master" for latest stable
# we will use this version as the base for upgrade
LONGHORN_STABLE_VERSION=${LONGHORN_STABLE_VERSION:-master}
LONGHORN_STABLE_MANIFEST_URL="https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_STABLE_VERSION}/deploy/longhorn.yaml"

set_kubeconfig_envvar(){
	ARCH=${1}
	BASEDIR=${2}

    if [[ ${ARCH} == "amd64" ]] ; then
        export KUBECONFIG="${BASEDIR}/kube_config_rke.yml"
    elif [[ ${ARCH} == "arm64"  ]]; then
        export KUBECONFIG="${BASEDIR}/../k3s.yaml"
    fi
}


install_csi_snapshotter_crds(){
    CSI_SNAPSHOTTER_REPO_URL="https://github.com/kubernetes-csi/external-snapshotter.git"
    CSI_SNAPSHOTTER_REPO_BRANCH="master"
    CSI_SNAPSHOTTER_REPO_DIR="${TMPDIR}/k8s-csi-external-snapshotter"

    git clone --single-branch \
              --branch "${CSI_SNAPSHOTTER_REPO_BRANCH}" \
      		  "${CSI_SNAPSHOTTER_REPO_URL}" \
      		  "${CSI_SNAPSHOTTER_REPO_DIR}"

    kubectl apply -f ${CSI_SNAPSHOTTER_REPO_DIR}/client/config/crd \
                  -f ${CSI_SNAPSHOTTER_REPO_DIR}/deploy/kubernetes/snapshot-controller
}


wait_longhorn_status_running(){
    local RETRY_COUNTS=10  # in minutes
	local RETRY_INTERVAL="1m"

    RETRIES=0
    while [[ -n `kubectl get pods -n ${LONGHORN_NAMESPACE} --no-headers | awk '{print $3}' | grep -v Running` ]]; do
        echo "Longhorn is still installing ... re-checking in 1m"
        sleep ${RETRY_INTERVAL}
        RETRIES=$((RETRIES+1))

        if [[ ${RETRIES} -eq ${RETRY_COUNTS} ]]; then echo "Error: longhorn installation timeout"; exit 1 ; fi
    done
}


generate_longhorn_yaml_manifest() {
	MANIFEST_BASEDIR="${1}"

	LONGHORN_MANAGER_REPO_URI=${LONGHORN_MANAGER_REPO_URI:-"https://github.com/longhorn/longhorn-manager.git"}
	LONGHORN_MANAGER_BRANCH=${LONGHORN_MANAGER_BRANCH:-"master"}
	LONGHORN_MANAGER_REPO_DIR="${TMPDIR}/longhorn-manager"

    CUSTOM_LONGHORN_MANAGER_IMAGE=${CUSTOM_LONGHORN_MANAGER_IMAGE:-"longhornio/longhorn-manager:master-head"}
    CUSTOM_LONGHORN_ENGINE_IMAGE=${CUSTOM_LONGHORN_ENGINE_IMAGE:-"longhornio/longhorn-engine:master-head"}

    CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE=${CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE:-""}
    CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE=${CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE:-""}
    CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE=${CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE:-""}


	git clone --single-branch \
		      --branch ${LONGHORN_MANAGER_BRANCH} \
			  ${LONGHORN_MANAGER_REPO_URI} \
			  ${LONGHORN_MANAGER_REPO_DIR}

    for FILE in `find "${LONGHORN_MANAGER_REPO_DIR}/deploy/install" -type f -name "*\.yaml" | sort`; do
      cat ${FILE} >> "${MANIFEST_BASEDIR}/longhorn.yaml"
      echo "---"  >> "${MANIFEST_BASEDIR}/longhorn.yaml"
    done

	# get longhorn default images from yaml manifest
    LONGHORN_MANAGER_IMAGE=`grep -io "longhornio\/longhorn-manager:.*$" "${MANIFEST_BASEDIR}/longhorn.yaml"| head -1`
    LONGHORN_ENGINE_IMAGE=`grep -io "longhornio\/longhorn-engine:.*$" "${MANIFEST_BASEDIR}/longhorn.yaml"| head -1`
    LONGHORN_INSTANCE_MANAGER_IMAGE=`grep -io "longhornio\/longhorn-instance-manager:.*$" "${MANIFEST_BASEDIR}/longhorn.yaml"| head -1`
    LONGHORN_SHARE_MANAGER_IMAGE=`grep -io "longhornio\/longhorn-share-manager:.*$" "${MANIFEST_BASEDIR}/longhorn.yaml"| head -1`
    LONGHORN_BACKING_IMAGE_MANAGER_IMAGE=`grep -io "longhornio\/backing-image-manager:.*$" "${MANIFEST_BASEDIR}/longhorn.yaml"| head -1`

	# replace longhorn images with custom images
    sed -i 's#'${LONGHORN_MANAGER_IMAGE}'#'${CUSTOM_LONGHORN_MANAGER_IMAGE}'#' "${MANIFEST_BASEDIR}/longhorn.yaml"
    sed -i 's#'${LONGHORN_ENGINE_IMAGE}'#'${CUSTOM_LONGHORN_ENGINE_IMAGE}'#' "${MANIFEST_BASEDIR}/longhorn.yaml"

	# replace images if custom image is specified.
	if [[ ! -z ${CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE} ]]; then
    	sed -i 's#'${LONGHORN_INSTANCE_MANAGER_IMAGE}'#'${CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE}'#' "${MANIFEST_BASEDIR}/longhorn.yaml"
	else
		# use instance-manager image specified in yaml file if custom image is not specified
		CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE=${LONGHORN_INSTANCE_MANAGER_IMAGE}
	fi

	if [[ ! -z ${CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE} ]]; then
    	sed -i 's#'${LONGHORN_SHARE_MANAGER_IMAGE}'#'${CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE}'#' "${MANIFEST_BASEDIR}/longhorn.yaml"
	else
		# use share-manager image specified in yaml file if custom image is not specified
		CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE=${LONGHORN_SHARE_MANAGER_IMAGE}
	fi


	if [[ ! -z ${CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE} ]]; then
    	sed -i 's#'${LONGHORN_BACKING_IMAGE_MANAGER_IMAGE}'#'${CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE}'#' "${MANIFEST_BASEDIR}/longhorn.yaml"
	else
		# use backing-image-manager image specified in yaml file if custom image is not specified
		CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE=${LONGHORN_BACKING_IMAGE_MANAGER_IMAGE}
	fi
}


install_longhorn_stable(){
	kubectl apply -f "${LONGHORN_STABLE_MANIFEST_URL}"
	wait_longhorn_status_running
}


install_longhorn_master(){
	LONGHORN_MANIFEST_FILE_PATH="${1}"

	kubectl apply -f "${LONGHORN_MANIFEST_FILE_PATH}"
	wait_longhorn_status_running
}


create_longhorn_namespace(){
  kubectl create ns ${LONGHORN_NAMESPACE}
}


install_backupstores(){
  MINIO_BACKUPSTORE_URL="https://raw.githubusercontent.com/longhorn/longhorn-tests/master/manager/integration/deploy/backupstores/minio-backupstore.yaml"
  NFS_BACKUPSTORE_URL="https://raw.githubusercontent.com/longhorn/longhorn-tests/master/manager/integration/deploy/backupstores/nfs-backupstore.yaml"
  kubectl create -f ${MINIO_BACKUPSTORE_URL} \
	             -f ${NFS_BACKUPSTORE_URL}
}


create_aws_secret(){
	AWS_ACCESS_KEY_ID_BASE64=`echo -n "${TF_VAR_lh_aws_access_key}" | base64`
	AWS_SECRET_ACCESS_KEY_BASE64=`echo -n "${TF_VAR_lh_aws_secret_key}" | base64`
	AWS_DEFAULT_REGION_BASE64=`echo -n "${TF_VAR_aws_region}" | base64`

	yq e -i '.data.AWS_ACCESS_KEY_ID |= "'${AWS_ACCESS_KEY_ID_BASE64}'"' "${TF_VAR_tf_workspace}/templates/aws_cred_secrets.yml"
	yq e -i '.data.AWS_SECRET_ACCESS_KEY |= "'${AWS_SECRET_ACCESS_KEY_BASE64}'"' "${TF_VAR_tf_workspace}/templates/aws_cred_secrets.yml"
	yq e -i '.data.AWS_DEFAULT_REGION |= "'${AWS_DEFAULT_REGION_BASE64}'"' "${TF_VAR_tf_workspace}/templates/aws_cred_secrets.yml"

	kubectl apply -f "${TF_VAR_tf_workspace}/templates/aws_cred_secrets.yml"
}


run_longhorn_upgrade_test(){
	LONGHORH_TESTS_REPO_BASEDIR=${1}

	LONGHORN_UPGRADE_TEST_POD_NAME="longhorn-test-upgrade"
	LONGHORN_TESTS_CUSTOM_IMAGE=${LONGHORN_TESTS_CUSTOM_IMAGE:-"longhornio/longhorn-manager-test:master-head"}

	LONGHORN_TESTS_MANIFEST_FILE_PATH="${LONGHORH_TESTS_REPO_BASEDIR}/manager/integration/deploy/test.yaml"
	LONGHORN_UPGRADE_TESTS_MANIFEST_FILE_PATH="${LONGHORH_TESTS_REPO_BASEDIR}/manager/integration/deploy/upgrade_test.yaml"

	LONGHORN_JUNIT_REPORT_PATH=`yq e '.spec.containers[0].env[] | select(.name == "LONGHORN_JUNIT_REPORT_PATH").value' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"`
	
	local PYTEST_COMMAND_ARGS='''"-s",
                                 "--junitxml='${LONGHORN_JUNIT_REPORT_PATH}'",
                                 "--include-upgrade-test",
                                 "-k", "test_upgrade",
                                 "--upgrade-lh-manager-repo-url", "'${LONGHORN_MANAGER_REPO_URI}'",
                                 "--upgrade-lh-manager-repo-branch", "'${LONGHORN_MANAGER_BRANCH}'",
                                 "--upgrade-lh-manager-image", "'${CUSTOM_LONGHORN_MANAGER_IMAGE}'",
                                 "--upgrade-lh-engine-image", "'${CUSTOM_LONGHORN_ENGINE_IMAGE}'",
                                 "--upgrade-lh-instance-manager-image", "'${CUSTOM_LONGHORN_INSTANCE_MANAGER_IMAGE}'",
                                 "--upgrade-lh-share-manager-image", "'${CUSTOM_LONGHORN_SHARE_MANAGER_IMAGE}'",
                                 "--upgrade-lh-backing-image-manager-image", "'${CUSTOM_LONGHORN_BACKING_IMAGE_MANAGER_IMAGE}'"
                              '''

	## generate upgrade_test pod manifest
    yq e 'select(.spec.containers[0] != null).spec.containers[0].args=['"${PYTEST_COMMAND_ARGS}"']' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}" > ${LONGHORN_UPGRADE_TESTS_MANIFEST_FILE_PATH}
	yq e -i 'select(.spec.containers[0] != null).spec.containers[0].image="'${LONGHORN_TESTS_CUSTOM_IMAGE}'"' ${LONGHORN_UPGRADE_TESTS_MANIFEST_FILE_PATH}
	yq e -i 'select(.spec.containers[0] != null).metadata.name="'${LONGHORN_UPGRADE_TEST_POD_NAME}'"' ${LONGHORN_UPGRADE_TESTS_MANIFEST_FILE_PATH}

	kubectl apply -f ${LONGHORN_UPGRADE_TESTS_MANIFEST_FILE_PATH}

	# wait upgrade test pod to start running
    while [[ -n "`kubectl get pods longhorn-test-upgrade --no-headers=true | awk '{print $3}' | grep -v \"Running\|Completed\"`"  ]]; do
		echo "waiting upgrade test pod to be in running state ... rechecking in 10s"
		sleep 10s
    done

    # wait upgrade test to complete
    while [[ -z "`kubectl get pods longhorn-test-upgrade --no-headers=true | awk '{print $3}' | grep -v Running`"  ]]; do
        echo "upgrade test still running ... rechecking in 30s"
        sleep 30s
    done

	# get upgrade test junit xml report
	kubectl logs ${LONGHORN_UPGRADE_TEST_POD_NAME} >> "${TF_VAR_tf_workspace}/longhorn-test-upgrade-junit-report.xml"
}


run_longhorn_tests(){
	LONGHORH_TESTS_REPO_BASEDIR=${1}

	LONGHORN_TESTS_CUSTOM_IMAGE=${LONGHORN_TESTS_CUSTOM_IMAGE:-"longhornio/longhorn-manager-test:master-head"}
	LONGHORN_TESTS_MANIFEST_FILE_PATH="${LONGHORH_TESTS_REPO_BASEDIR}/manager/integration/deploy/test.yaml"

	LONGHORN_JUNIT_REPORT_PATH=`yq e '.spec.containers[0].env[] | select(.name == "LONGHORN_JUNIT_REPORT_PATH").value' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"`

	local PYTEST_COMMAND_ARGS='"-s", "--junitxml='${LONGHORN_JUNIT_REPORT_PATH}'"'
	if [[ -n ${PYTEST_CUSTOM_OPTIONS} ]]; then
        PYTEST_CUSTOM_OPTIONS=(${PYTEST_CUSTOM_OPTIONS})

        for OPT in ${PYTEST_CUSTOM_OPTIONS[@]}; do
            PYTEST_COMMAND_ARGS=${PYTEST_COMMAND_ARGS}', "'${OPT}'"'
        done
    fi

	## generate test pod manifest
    yq e -i 'select(.spec.containers[0] != null).spec.containers[0].args=['"${PYTEST_COMMAND_ARGS}"']' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"
    yq e -i 'select(.spec.containers[0] != null).spec.containers[0].image="'${LONGHORN_TESTS_CUSTOM_IMAGE}'"' ${LONGHORN_TESTS_MANIFEST_FILE_PATH}

	set +x
	## inject aws cloudprovider and credentials env variables from created secret
	yq e -i 'select(.spec.containers[0].env != null).spec.containers[0].env += {"name": "CLOUDPROVIDER", "value": "aws"}' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"
	yq e -i 'select(.spec.containers[0].env != null).spec.containers[0].env += {"name": "AWS_ACCESS_KEY_ID", "valueFrom": {"secretKeyRef": {"name": "aws-cred-secret", "key": "AWS_ACCESS_KEY_ID"}}}' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"
	yq e -i 'select(.spec.containers[0].env != null).spec.containers[0].env += {"name": "AWS_SECRET_ACCESS_KEY", "valueFrom": {"secretKeyRef": {"name": "aws-cred-secret", "key": "AWS_SECRET_ACCESS_KEY"}}}' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"
	yq e -i 'select(.spec.containers[0].env != null).spec.containers[0].env += {"name": "AWS_DEFAULT_REGION", "valueFrom": {"secretKeyRef": {"name": "aws-cred-secret", "key": "AWS_DEFAULT_REGION"}}}' "${LONGHORN_TESTS_MANIFEST_FILE_PATH}"
	set -x

	LONGHORN_TEST_POD_NAME=`yq e 'select(.spec.containers[0] != null).metadata.name' ${LONGHORN_TESTS_MANIFEST_FILE_PATH}`

	kubectl apply -f ${LONGHORN_TESTS_MANIFEST_FILE_PATH}

	local RETRY_COUNTS=60
	local RETRIES=0
	# wait longhorn tests pod to start running
    while [[ -n "`kubectl get pods "${LONGHORN_TEST_POD_NAME}" --no-headers=true | awk '{print $3}' | grep -v \"Running\|Completed\"`"  ]]; do
        echo "waiting longhorn test pod to be in running state ... rechecking in 10s"
        sleep 10s
		RETRIES=$((RETRIES+1))

		if [[ ${RETRIES} -eq ${RETRY_COUNTS} ]]; then echo "Error: longhorn test pod start timeout"; exit 1 ; fi
    done

    # wait longhorn tests to complete
    while [[ -z "`kubectl get pods ${LONGHORN_TEST_POD_NAME} --no-headers=true | awk '{print $3}' | grep -v Running`"  ]]; do
        echo "Longhorn tests still running ... rechecking in 5m"
        sleep 5m
    done

	kubectl logs ${LONGHORN_TEST_POD_NAME}  >> "${TF_VAR_tf_workspace}/longhorn-test-junit-report.xml"
}


main(){
	set_kubeconfig_envvar ${TF_VAR_arch} ${TF_VAR_tf_workspace}
	create_longhorn_namespace
	install_backupstores
	create_aws_secret
	install_csi_snapshotter_crds
	generate_longhorn_yaml_manifest "${TF_VAR_tf_workspace}"

	if [[ "${LONGHORN_UPGRADE_TEST}" == true || "${LONGHORN_UPGRADE_TEST}" == True ]]; then
		install_longhorn_stable
		run_longhorn_upgrade_test ${WORKSPACE}
		run_longhorn_tests ${WORKSPACE}
	else
		install_longhorn_master "${TF_VAR_tf_workspace}/longhorn.yaml"
		run_longhorn_tests ${WORKSPACE}
	fi
}

main
