#!/bin/bash
set -euo pipefail

# Get OS and architecture details.
source /etc/os-release
ARCH=$(uname -m)
DISTRO_CODE="${DISTRO_CODE:-${ID}_${VERSION_ID//./}}"

WORKING_DIRECTORY=/usr/libexec/osbuild-composer
IMAGE_TEST_CASE_RUNNER=/usr/libexec/osbuild-composer-test/osbuild-image-tests
IMAGE_TEST_CASES_PATH=/usr/share/tests/osbuild-composer/manifests

# aarch64 machines in AWS don't supported nested KVM so we run only
# testing against cloud vendors, don't boot with qemu-kvm!
if [[ "${ARCH}" == "aarch64" ]]; then
    IMAGE_TEST_CASE_RUNNER="${IMAGE_TEST_CASE_RUNNER} --disable-local-boot"
fi

PASSED_TESTS=()
FAILED_TESTS=()

# Print out a nice test divider so we know when tests stop and start.
test_divider () {
    printf "%0.s-" {1..78} && echo
}

# Get a list of test cases.
get_test_cases () {
    TEST_CASE_SELECTOR="${DISTRO_CODE}-${ARCH}"
    pushd $IMAGE_TEST_CASES_PATH > /dev/null
        ls "$TEST_CASE_SELECTOR"*.json
    popd > /dev/null
}

# Run a test case and store the result as passed or failed.
run_test_case () {
    TEST_RUNNER=$1
    TEST_CASE_FILENAME=$2
    TEST_NAME=$(basename "$TEST_CASE_FILENAME")

    echo
    test_divider
    echo "🏃🏻 Running test: ${TEST_NAME}"
    test_divider

    # Set up the testing command with Azure secrets in the environment.
    #
    # This works by having a text file stored in Jenkins credentials.
    # In Jenkinsfile, the following line assigns the path to this secret file
    # to an environment variable called AZURE_CREDS:
    # AZURE_CREDS = credentials('azure')
    #
    # The file is in the following format:
    # KEY1=VALUE1
    # KEY2=VALUE2
    #
    # Using `env $(cat $AZURE_CREDS)` we can take all the key-value pairs and
    # save them as environment variables.
    # Read test/README.md to see all required environment variables for Azure
    # uploads
    #
    # AZURE_CREDS might not be defined in all cases (e.g. Azure doesn't
    # support aarch64), therefore the following line sets AZURE_CREDS to
    # /dev/null if the variable is undefined.
    AWS_CREDS=${AWS_IMAGE_TEST_CREDS-/dev/null}
    AZURE_CREDS=${AZURE_CREDS-/dev/null}
    OPENSTACK_CREDS=${OPENSTACK_CREDS-/dev/null}
    VCENTER_CREDS=${VCENTER_CREDS-/dev/null}
    TEST_CMD="env $(cat "$AWS_CREDS" "$AZURE_CREDS" "$OPENSTACK_CREDS" "$VCENTER_CREDS") BRANCH_NAME=${BRANCH_NAME-main} BUILD_ID=$BUILD_ID DISTRO_CODE=$DISTRO_CODE $TEST_RUNNER -test.v ${IMAGE_TEST_CASES_PATH}/${TEST_CASE_FILENAME}"

    # Run the test and add the test name to the list of passed or failed
    # tests depending on the result.
    # shellcheck disable=SC2086 # We need to pass multiple arguments here.
    if sudo $TEST_CMD 2>&1 | tee "${WORKSPACE}"/"${TEST_NAME}".log; then
        PASSED_TESTS+=("$TEST_NAME")
    else
        FAILED_TESTS+=("$TEST_NAME")
    fi

    test_divider
    echo
}

# Provision the software under tet.
/usr/libexec/osbuild-composer-test/provision.sh

# Change to the working directory.
cd $WORKING_DIRECTORY

# Run each test case.
for TEST_CASE in $(get_test_cases); do
    run_test_case "$IMAGE_TEST_CASE_RUNNER" "$TEST_CASE"
done

# Print a report of the test results.
test_divider
echo "😃 Passed tests: " "${PASSED_TESTS[@]}"
echo "☹ Failed tests: " "${FAILED_TESTS[@]}"
test_divider

# Exit with a failure if tests were executed and any of them failed.
if [ ${#PASSED_TESTS[@]} -gt 0 ] && [ ${#FAILED_TESTS[@]} -eq 0 ]; then
    echo "🎉 All tests passed."
    exit 0
else
    echo "🔥 One or more tests failed."
    exit 1
fi
