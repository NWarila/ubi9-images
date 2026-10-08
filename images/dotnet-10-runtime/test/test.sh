# images/dotnet-10-runtime/test/test.sh - what ubi9-dotnet-10-runtime
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# A .NET program has to be compiled, and this image has no compiler, so the
# probe that exercises it (cultures, time zones, Brotli, TLS, the FIPS
# behaviour, a web server on port 8080) runs in the test of
# ubi9-dotnet-10-toolset, which builds this image and runs the probe on it.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" --list-runtimes
expect 'has the .NET 10 runtime' 'Microsoft.NETCore.App 10.0.'
expect 'has the ASP.NET Core 10 shared framework' \
  'Microsoft.AspNetCore.App 10.0.'

capture image_env "$image_ref"
expect_line 'ASP.NET Core listens on port 8080 by default' \
  'ASPNETCORE_HTTP_PORTS=8080'
expect_line '.NET knows it runs in a container' \
  'DOTNET_RUNNING_IN_CONTAINER=true'

end_of_test
