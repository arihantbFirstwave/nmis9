#!/bin/sh
# a set of common functions for dealing with yum (and apt) repositories
# use POSIX functionality only, no bashisms!
#
# note: common_funtions.sh must be loaded

# small helper function that determines whether the installer
# can access the internet (actually just web).
# returns 0 if access works, 1 otherwise
is_web_available()
{
		printBanner "Checking if Web is accessible..."
		# curl is available even on minimal centos install
		if type curl >/dev/null 2>&1 && execPrint "curl --insecure -L -s -m 10 --retry 2 -o /dev/null https://opmantek.com/robots.txt 2>/dev/null";
		then
				echolog "Web access is OK."
				return 0
		fi

		# hmm, maybe we have wget?
		if type wget >/dev/null 2>&1 && execPrint "wget --no-check-certificate -q -T 10 --tries=3 -O /dev/null https://opmantek.com/robots.txt 2>/dev/null"; then
				echolog "Web access is OK."
				return 0
		fi

		echolog "No Web access!"
		return 1
}

# yum is fairly silly wrt caches etc, so we need to make sure it's happy FIRST
# returns yum makecache's exit code
# note: needs internet access
prime_yum() {
		# and ditch rpm/repoforge, it's dead...
		# rpm doesn't have any useful exit codes :-(
		if rpm -qa rpmforge-release 2>&1 | fgrep -q rpmforge-release;
		then
				printBanner "Removing dead Repoforge repository"
				rpm -e rpmforge-release;
		fi
		printBanner "Updating YUM metadata cache..."
		yum makecache
		return $?
}

prime_apt() {
		printBanner "Updating packages, please wait..."
		apt-get update -qq
		return $?
}

# tests whether the given repository is active
# args: repository name
# returns 0 if ok, 1 if not active, 2 if error
#
# note: must be run only AFTER prime_yum()!
is_repo_enabled() {
		local REPONAME
		REPONAME=$1

		[ -z "$REPONAME" ] && return 2

		if yum -C -v repolist $REPONAME 2>/dev/null | grep -qE '^Repo-status *: *enabled'; then
				return 0
		else
				return 1
		fi
}

# tests whether the given debian/ubuntu distribution is active
# args: distribution name
# returns 0 if ok, 1 if not active, 2 if error
is_distro_enabled() {
		local DISTRONAME
		DISTRONAME=$1
		[ -z "$DISTRONAME" ] && return 2

		if cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -qE "^deb[[:space:]]+[^[:space:]]+[[:space:]]+$DISTRONAME[[:space:]]" 2>/dev/null; then
				return 0
		else
				return 1
		fi
}

# small helper that enables a debian/ubuntu distro,
# which also sets up preferences to NEVER auto-pull from there
# args: distribution name (the logical name, testing/unstable, NOT the code name!)
# relies on $OSFLAVOUR to switch between ubuntu and debian
enable_distro()
{
		local DISTRONAME
		DISTRONAME=$1

		printBanner "Enabling $DISTRONAME distribution"
		if [ "$OSFLAVOUR" = "debian" ]; then

				cat >/etc/apt/sources.list.d/opmantek-$DISTRONAME.list <<EOF
deb http://deb.debian.org/debian $DISTRONAME main contrib non-free
EOF
				cat >/etc/apt/preferences.d/opmantek-$DISTRONAME <<EOF
# apt-get should not consider this distribution,
# unless the package isn't available in another distribution.
Package: *
Pin: release o=Debian,a=$DISTRONAME
Pin-Priority: 10

EOF
		elif [ "$OSFLAVOUR" = "ubuntu" ]; then
				cat >/etc/apt/sources.list.d/opmantek-$DISTRONAME.list <<EOF
deb http://archive.ubuntu.com/ubuntu/ $DISTRONAME main restricted universe multiverse
EOF
				cat >/etc/apt/preferences.d/opmantek-$DISTRONAME <<EOF
# apt-get should not consider this distribution,
# unless the package isn't available in another distribution.
Package: *
Pin: release o=Ubuntu,a=$DISTRONAME
Pin-Priority: 10

EOF
		fi
		# reload the package list to finish
		prime_apt;
}


# small helper that disables an enabled debian/ubuntu distro,
# args: distribution name (the logical name, testing/unstable, NOT the code name!)
# relies on $OSFLAVOUR to switch between ubuntu and debian
disable_distro()
{
		local DISTRONAME
		DISTRONAME=$1

		printBanner "Disabling $DISTRONAME distribution"
		if [ "$OSFLAVOUR" = "debian" ] || [ "$OSFLAVOUR" = "ubuntu" ]; then
				execPrint "rm -f /etc/apt/sources.list.d/opmantek-$DISTRONAME.list";
				execPrint "rm -f /etc/apt/preferences.d/opmantek-$DISTRONAME"
		fi
		# reload the package list to finish
		prime_apt;
}


# small helper that enables one of the known custom repos
# args: repo name (epel or rpmforge/repoforge)
# returns: 0 if ok, 1 otherwise
# note: requires that flavour() has been run
enable_custom_repo() {
		local REPONAME
		REPONAME=$1

		[ -z "$REPONAME" ] && return 1

		# epel: comfy for centos, not so for rh
		# ghettoforge: doesn't seem problematic,
		# repoforge: uncomfy everywhere, besides stone-dead...
		if [ "$REPONAME" = "epel" ]; then
				printBanner "Enabling EPEL repository"
				if [ "$OS_ISCENTOS" = 1 ]; then
						execPrint yum -y install epel-release
				else
						# default RHEL7 and RHEL8 installs come with EPEL enabled but needed RHEL repos disabled
						# variable RHEL_EPEL_REPOS_ENABLED gets set here, further below, and also gets checked in calling function install_package() that is further below
						if [ "${RHEL_EPEL_REPOS_ENABLED:-0}" != 1 ]; then
							# https://fedoraproject.org/wiki/EPEL
							# extra rh repos absolutely required for epel to work. grrr.
							echolog "Enabling RHEL ${OS_MAJOR} Repositories"
							if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-server-optional-rpms" | grep Enabled | grep 0)" ]; then
								execPrint "subscription-manager repos --enable=rhel-${OS_MAJOR}-server-optional-rpms 2>&1"||:;
							fi;
							if [ "$OS_MAJOR" = 7 ]; then
									if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-server-extras-rpms" | grep Enabled | grep 0)" ]; then
										execPrint "subscription-manager repos --enable=rhel-${OS_MAJOR}-server-extras-rpms 2>&1"||:;
									fi;
							elif [ "$OS_MAJOR" = 8 ]; then
									if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-for-x86_64-supplementary-rpms" | grep Enabled | grep 0)" ]; then
										execPrint "subscription-manager repos --enable=rhel-${OS_MAJOR}-for-x86_64-supplementary-rpms 2>&1"||:;
									fi;
									if [ -n "$(subscription-manager repos | grep -A4 "codeready-builder-for-rhel-${OS_MAJOR}-x86_64-rpms" | grep Enabled | grep 0)" ]; then
										execPrint "subscription-manager repos --enable=codeready-builder-for-rhel-${OS_MAJOR}-x86_64-rpms 2>&1"||:;
									fi;
							fi
							# variable RHEL_EPEL_REPOS_ENABLED only gets set here
							RHEL_EPEL_REPOS_ENABLED=1;
						fi
						# default RHEL7 and RHEL8 installs come with EPEL enabled but needed RHEL repos disabled
						# variable THIS_REPO_IS_ENABLED gets set in calling function install_package() that is further below
						if [ "${THIS_REPO_IS_ENABLED:-0}" != 1 ]; then
							# then finally the epel repo itself
							execPrint yum -y install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
						fi;
				fi

		elif [ "$REPONAME" = "gf" ]; then
				# variable THIS_REPO_IS_ENABLED gets set in calling function install_package() that is further below
				if [ "${THIS_REPO_IS_ENABLED:-0}" != 1 ]; then
					printBanner "Enabling Ghettoforge repository";
					execPrint yum -y install "http://mirror.ghettoforge.org/distributions/gf/gf-release-latest.gf.el${OS_MAJOR}.noarch.rpm"
				fi

		elif [ "$REPONAME" = "repoforge" -o "$REPONAME" = "rpmforge" ]; then
				# variable THIS_REPO_IS_ENABLED gets set in calling function install_package() that is further below
				if [ "${THIS_REPO_IS_ENABLED:-0}" != 1 ]; then
					printBanner "Enabling RepoForge repository"
					execPrint yum -y install "http://pkgs.repoforge.org/rpmforge-release/rpmforge-release-0.5.3-1.el${OS_MAJOR}.rf.x86_64.rpm"
				fi
		else
				return 1
		fi

		return 0
}


# args: package names
# sets $MISSING to a space-sep list of missing packages
# returns 0 if no missing pkgs, 1 otherwise
check_missing_packages() {
		local PKG
		MISSING=''
		for PKG in "$@"; do
				if [ "$OSFLAVOUR" = "redhat" ]; then
						if [ -z "`rpm -qa $PKG`" ]; then
								MISSING="$MISSING $PKG";
								echolog "Package $PKG is NOT installed."
						else
								echolog "Package $PKG is installed.";
						fi
				elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
						if ! `dpkg -l $PKG 2>/dev/null | grep -qE ^[hi]i`; then
								MISSING="$MISSING $PKG"
								echolog "Package $PKG is NOT installed."
						else
								echolog "Package $PKG is installed."
						fi
				fi
		done
		[ -z "$MISSING" ] && return 0
		return 1
}

# args: one (or more) package name
# uses $REPO, $NEEDREPO, $REPONAME and $REPOURL, $CANUSEWEB on redhat,
# $NEEDDISTRO on debian/ubuntu
# and enables the repo in question if required
#
# execprints yum or apt-get, but captures only the last package's installer status
# returns: 0 if ok, 1 otherwise
# note: requires that flavour() has been run
install_package() {
		local pkg
		for pkg in "$@"; do
				if [ "$OSFLAVOUR" = "redhat" ]; then
						if [ -n "$NEEDREPO" ]; then
								# default RHEL7 and RHEL8 installs come with EPEL enabled but needed RHEL repos disabled
								# variable THIS_REPO_IS_ENABLED also gets checked in enable_custom_repo() function which is called within this block
								local THIS_REPO_IS_ENABLED;
								if is_repo_enabled $NEEDREPO; then
									THIS_REPO_IS_ENABLED=1;
								else
									THIS_REPO_IS_ENABLED=0;
								fi;

								local DO_ENABLE_THIS_REPO;
								# default RHEL7 and RHEL8 installs come with EPEL enabled but needed RHEL repos disabled
								# variable RHEL_EPEL_REPOS_ENABLED gets set in enable_custom_repo() function which is called within this block
								if [ "$OS_ISCENTOS" != 1 ] && [ "$NEEDREPO" = "epel" ] && [ "${RHEL_EPEL_REPOS_ENABLED:-0}" != 1 ]; then
										DO_ENABLE_THIS_REPO=1;
								elif [ "${THIS_REPO_IS_ENABLED}" != 1 ]; then
										DO_ENABLE_THIS_REPO=1;
								fi;
								if [ "${DO_ENABLE_THIS_REPO:-0}" = 1 ]; then
										unset DO_ENABLE_THIS_REPO;
										if [ "$CANUSEWEB" != 1 ]; then
											printBanner "Cannot enable repository $REPONAME!"

											cat <<EOF

The $REPONAME repository is required for installing $pkg, but
your system does not have web access and thus cannot
download anything from that repository.

You will have install $pkg manually, downloadable
from $REPOURL.

EOF
											exit 1
										else
											enable_custom_repo $NEEDREPO
										fi
								else
										unset DO_ENABLE_THIS_REPO;
								fi
								unset THIS_REPO_IS_ENABLED;
						fi

						local MESSAGE
						MESSAGE="Using yum to install $pkg"
						[ -n "$REPO" ] && MESSAGE="$MESSAGE (from repository $REPONAME)"
						echolog $MESSAGE
						execPrint "yum -y $REPO install $pkg"
						RES=$?

				elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
						if [ -n "$NEEDDISTRO" ] && ! is_distro_enabled $NEEDDISTRO; then
								if [ "$CANUSEWEB" != 1 ]; then
										printBanner "Cannot enable distribution $NEEDDISTRO!"

										cat <<EOF

Access to the $NEEDDISTRO distribution is required for installing
$pkg, but your system does not have web access and thus cannot
download anything from that repository.

You will have install $pkg manually.

EOF
										exit 1
								else
										logmsg "Enabling distro $NEEDDISTRO for $pkg"
										enable_distro $NEEDDISTRO
								fi
						fi

						DEBIAN_FRONTEND=noninteractive
						export DEBIAN_FRONTEND
						DEBCONF_NONINTERACTIVE_SEEN=true
						export DEBCONF_NONINTERACTIVE_SEEN

						echolog "Using apt-get to install $pkg"
						local PRECISEPACKAGE
						PRECISEPACKAGE=$pkg
						[ -n "$NEEDDISTRO" ] && PRECISEPACKAGE=$PRECISEPACKAGE/$NEEDDISTRO
						execPrint "apt-get -yq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install $PRECISEPACKAGE"
						RES=$?
				fi
		done
		return $RES
}
