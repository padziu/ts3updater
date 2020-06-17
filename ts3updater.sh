#!/bin/sh
# Script Name: ts3updater.sh
# Author: eminga
# Version: 1.7.1
# Description: Installs and updates TeamSpeak 3 servers
# License: MIT License

cd "$(dirname "$0")" || exit 1

# show usage
if echo "$@" | grep -- '--help' > /dev/null 2>&1; then
    echo 'Usage:'
    echo "$0 [--help]             - show this help"
    echo "$0 [--dont-start]       - do not start server after update"
    echo "$0 [--check-only]       - do not update - only check for new version"
    echo "$0 [--accept-license]   - accept license"
    exit 0
fi

# '--dont-start' switch
if echo "$@" | grep -- '--dont-start' > /dev/null 2>&1; then
    dont_start=1
fi

# '--accept-license' switch
if echo "$@" | grep -- '--accept-license' > /dev/null 2>&1; then
    accept_license=1
fi

# '--check-only' switch
if echo "$@" | grep -- '--check-only' > /dev/null 2>&1; then
    check_only=1
fi

# check whether the dependencies curl, jq, and tar are installed
if ! command -v curl > /dev/null 2>&1; then
    echo 'curl not found' 1>&2
    exit 1
elif ! command -v jq > /dev/null 2>&1; then
    echo 'jq not found' 1>&2
    exit 1
elif ! command -v tar > /dev/null 2>&1; then
    echo 'tar not found' 1>&2
    exit 1
fi

# determine os and cpu architecture
os=$(uname -s)
if [ "$os" = 'Darwin' ]; then
    jqfilter='.macos'
else
    if [ "$os" = 'Linux' ]; then
        jqfilter='.linux'
    elif [ "$os" = 'FreeBSD' ]; then
        jqfilter='.freebsd'
    else
        echo 'Could not detect operating system. If you run Linux, FreeBSD, or macOS and get this error, please open an issue on Github.' 1>&2
        exit 1
    fi

    architecture=$(uname -m)
    if [ "$architecture" = 'x86_64' ] || [ "$architecture" = 'amd64' ]; then
        jqfilter="${jqfilter}.x86_64"
    else
        jqfilter="${jqfilter}.x86"
    fi
fi

# download JSON file which provides information on server versions and checksums
if server=$(curl -Ls 'https://www.teamspeak.com/versions/server.json' | jq "$jqfilter"); then
    echo 'Downloading information from https://www.teamspeak.com/versions/server.json was successful.'
else
    echo 'Unable to get server.json. Exiting.'
    exit 1
fi

new_version=$(printf '%s' "$server" | jq -r '.version')

# determine installed version by parsing the most recent entry of the CHANGELOG file
if [ -e 'CHANGELOG' ]; then
    current_version=$(grep -iwo "Server $new_version" logs/* | head -1 | grep -iwo $new_version)
else
    current_version='-1'
fi

# compare available and installed versions
if [ "$current_version" = "$new_version" ]; then
    echo "The installed server is up-to-date. Version: $current_version"
    exit
else
    echo "New version available: $new_version"
fi

if [[ "$check_only" -eq 1 ]]; then
    exit
fi

# create temp directory
if working_dir=$(mktemp -d); then
    echo "Working directory: $working_dir"
else
    echo 'Unable to create working directory. Exiting.'
    exit 1
fi

# try to download from mirrors until download is successful or all mirrors tried
links=$(printf '%s' "$server" | jq -r '.mirrors | values[]')
for link in $links
do
    echo "Downloading the file $link"
    if curl --location --silent --output "$working_dir/teamspeak.tar.bz2" "$link"; then
        echo 'File saved as' "$working_dir/teamspeak.tar.bz2"
        break
    fi
done

# verify checksum
if command -v sha256sum > /dev/null 2>&1; then
    sha256=$(sha256sum "$working_dir/teamspeak.tar.bz2" | cut -b 1-64)
elif command -v shasum > /dev/null 2>&1; then
    sha256=$(shasum -a 256 "$working_dir/teamspeak.tar.bz2" | cut -b 1-64)
elif command -v sha256 > /dev/null 2>&1; then
    sha256=$(sha256 -q "$working_dir/teamspeak.tar.bz2")
else
    echo 'Could not generate SHA256 hash. Please make sure at least one of these commands is available: sha256sum, shasum, sha256' 1>&2
    rm -r "$working_dir"
    exit 1
fi
checksum=$(printf '%s' "$server" | jq -r '.checksum')
if [ "$checksum" = "$sha256" ]; then
    echo 'Checksum is OK' 1>&2
else
    echo 'Checksum of downloaded file is incorrect!' 1>&2
    rm -r "$working_dir"
    exit 1
fi

tsdir=$(tar -tf "$working_dir/teamspeak.tar.bz2" | grep -m1 /)
if [ $accept_license -eq 1 ] || [ -e '.ts3server_license_accepted' ]; then
    echo 'License accepted'
elif [ ! -e '.ts3server_license_accepted' ]; then
    # display server license
    tar --to-stdout -xf "$working_dir/teamspeak.tar.bz2" "$tsdir"LICENSE
    echo -n "Accept license agreement (y/N)? "
    read -r answer
    if ! echo "$answer" | grep -iq "^y" ; then
        rm -r "$working_dir"
        exit 1
    fi
fi
if [ -e 'ts3server_startscript.sh' ]; then
    # check if server is running
    if [ -e 'ts3server.pid' ]; then
        server_started=1
        ./ts3server_startscript.sh stop
    fi
else
    mkdir "$tsdir" 2>/dev/null || { echo 'Could not create installation directory. If you wanted to upgrade an existing installation, make sure to place this script INSIDE the existing installation directory.' 1>&2; rm -r "$working_dir"; exit 1; }
    cd "$tsdir" && cp ../"$(basename "$0")" .
fi

# extract the archive into the installation directory and overwrite existing files
tar --strip-components 1 -xf "$working_dir/teamspeak.tar.bz2" "$tsdir"
touch .ts3server_license_accepted
if [[ "$dont_start" -ne 1 || "$server_started" -eq 1 ]]; then
    ./ts3server_startscript.sh start "$@"
fi

# cleanup
rm -r "$working_dir"
echo 'Done'
