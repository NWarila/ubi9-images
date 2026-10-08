# images/dotnet-runtime-deps/test/test.sh - what ubi9-dotnet-runtime-deps
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# This image runs self-contained .NET applications, which bring their own
# runtime. The self-contained probe (cultures, time zones, Brotli, TLS, the
# FIPS behaviour) runs in the test of ubi9-dotnet-10-toolset, which builds
# it and this image.

# shellcheck shell=bash disable=SC2154,SC2034

if has_file_matching '^usr/(bin/dotnet|lib64/dotnet/)'; then
  fail 'has no .NET runtime of its own'
else
  pass 'has no .NET runtime of its own'
fi
check 'has ICU, for cultures and time zones' \
  has_file_matching '^usr/lib64/libicuuc\.so\.[0-9]+$'
check 'has the C++ standard library' has_file usr/lib64/libstdc++.so.6

capture image_env "$image_ref"
expect_line 'ASP.NET Core listens on port 8080 by default' \
  'ASPNETCORE_HTTP_PORTS=8080'
expect_line '.NET knows it runs in a container' \
  'DOTNET_RUNNING_IN_CONTAINER=true'

end_of_test
