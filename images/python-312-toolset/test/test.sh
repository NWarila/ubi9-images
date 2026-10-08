# images/python-312-toolset/test/test.sh - what ubi9-python-312-toolset
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# The toolset compiles the C extension module in extension/ against the
# Python headers, and the module is then imported by ubi9-python-312-runtime,
# which is built here: native code built in the toolset runs on the runtime.

# shellcheck shell=bash disable=SC2154,SC2034

check 'has pip' podman_run "$image_ref" python3.12 -m pip --version
check 'has a C compiler' podman_run "$image_ref" gcc --version

# toolset <command...>: run in the toolset as this machine's user, so the
# files it writes in $work belong to us.
toolset() {
  podman_run --userns=keep-id --user "$(id -u):$(id -g)" \
    --volume "$work:/work:z" --workdir /work/extension "$image_ref" "$@"
}

cp -R "$test_dir/extension" "$work/extension" \
  || fail_setup 'cannot copy the extension source'

# The single quotes are deliberate: bash in the toolset expands them.
# shellcheck disable=SC2016
check 'compiles a C extension module' toolset bash -c \
  'gcc -shared -fPIC $(python3.12-config --includes) probe_ext.c \
     -o probe_ext$(python3.12-config --extension-suffix)'

# The runtime runs as user 65532: make the module readable to it.
chmod -R a+rX "$work/extension" \
  || fail_setup 'cannot make the module readable'

build_partner python-312-runtime
capture podman_run --volume "$work/extension:/app:ro,z" "$partner_ref" \
  -c 'import sys; sys.path.insert(0, "/app"); import probe_ext; \
print(probe_ext.where())'
expect_line 'the module imports on ubi9-python-312-runtime' \
  'compiled in the toolset'

end_of_test
