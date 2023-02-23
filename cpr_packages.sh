#!/bin/sh
#export LN='/bin/ln -f'
export PKG_SUFX=txz
export PACKAGES=/packages
export DISABLE_VULNERABILITIES=yes

export PATH="/usr/lib/distcc/bin:$PATH"
#export CCACHE_PREFIX="/usr/local/bin/distcc"
export CCACHE_PATH="/usr/bin:/usr/local/bin"
export PATH="/usr/local/libexec/ccache:$PATH:/usr/local/bin:/usr/local/sbin"
#export LC_ALL=en_US.UTF-8

LOGFILE="/tmp/packages.log"
BUILDLOG="/tmp/build.log"

# fatal error for interactive session.
err()
{
	exitval=$1
	shift
	echo "$*" 1>&2
	echo "$*" >> ${LOGFILE}
	exit $exitval
}

# defaults
ccache=0
distcc=0

while getopts "c:d:" opt; do
	case "$opt" in
		c) ccache="${OPTARG}" ;;
		d) distcc="${OPTARG}" ;;
	esac
	shift $(($OPTIND - 1))
done

if [ "${ccache}" = "1" ]; then
	echo "*** Ccache enabled ***"
	export PATH=/usr/local/libexec/ccache:${PATH}
	export CCACHE_PATH=/usr/bin:/usr/local/bin
	export CCACHE_DIR=/root/.ccache
	CCACHE_SIZE="8"
	/usr/local/bin/ccache -M ${CCACHE_SIZE}
fi

[ -f /tmp/cpr_error ] && rm -f /tmp/cpr_error

status_file="/tmp/cpr_build_status.txt"
descr_status_file="/root/system/descr"

truncate -s0 ${status_file}

truncate -s0 ${LOGFILE} ${BUILDLOG}
rm -f /tmp/port_log* > /dev/null 2>&1 ||true

PORT_DIRS=$( /bin/cat /tmp/ports_list.txt )

cat > /tmp/fetch-recursive.sh <<EOF
#!/bin/sh
EOF

chmod +x /tmp/fetch-recursive.sh

for dir in $PORT_DIRS; do
	echo "make -C ${dir} fetch-recursive" >> /tmp/fetch-recursive.sh
done

/usr/sbin/daemon -f /tmp/fetch-recursive.sh

#determine how we have free ccachefs
#CCACHE_SIZE=`df -m /root/.ccache | tail -n1 |/usr/bin/awk '{print $2}'`
#[ -z "${CCACHE_SIZE}" ] && CCACHE_SIZE="4096"
#/usr/local/bin/ccache -M ${CCACHE_SIZE}m >>${LOGFILE} 2>&1|| err 1 "Cannot set ccache size"

find /tmp/usr/ports -type d -name work -exec rm -rf {} \; || true

mkdir -p ${PACKAGES}/All >>${LOGFILE} 2>&1 || err 1 "Cannot create PACKAGES/All directory!"

ALLPORTS=$( /usr/bin/grep -v ^# /tmp/ports_list.txt |/usr/bin/grep . |/usr/bin/wc -l | /usr/bin/awk '{printf $1}')
PROGRESS=0
PASS=0
FAILED=0
FAILED_LIST=""

#set +o errexit
# config recursive while 
for dir in $PORT_DIRS; do
	PROGRESS=$((PROGRESS + 1))
	pkg info -e $( make -C ${dir} -V PKGNAME) && continue
	#this is hack for determine that we have no options anymore - script dup stdout then we can grep for Dialog-Ascii-specific symbol
#	NOCONF=0
#	while [ $NOCONF -eq 0 ]; do
		echo -e "\033[40;35m Do config-recursive while not set for all options: ${PROGRESS}/${ALLPORTS} \033[0m"
		# script -q /tmp/test.$$ 
#		make config-recursive -C ${dir}
		PASS=$(( PASS + 1 ))
		[ ${PASS} -gt ${ALLPORTS} ] && NOCONF=1
		# || break
#		grep "\[" /tmp/test.$$
#		[ $? -eq 1 ] && NOCONF=1
#	done
done

rm -f /tmp/test.$$
# reject any potential dialog popup from misc. broken for save options ports for build stage
echo "BATCH=yes" >> /etc/make.conf

sysrc -qf ${status_file} pkg_all="${ALLPORTS}"
sysrc -qf ${descr_status_file} pkg_all="${ALLPORTS}"

PROGRESS=${ALLPORTS}
#set -o errexit

st_date=$( /bin/date +%s )
sysrc -qf ${status_file} start_time="${st_date}"


for dir in $PORT_DIRS; do
	PROGRESS=$((PROGRESS - 1))
	echo -e "\033[40;35m Working on ${dir}. ${PROGRESS}/${ALLPORTS} ports left. \033[0m"
	# skip if ports already registered

	sysrc -qf ${status_file} current_build="${dir}"
	sysrc -qf ${status_file} pkg_left="${PROGRESS}"

	sysrc -qf ${descr_status_file} current_build="${dir}"
	sysrc -qf ${descr_status_file} pkg_left="${PROGRESS}"

	if [ ! -d "${dir}" ]; then
		FAILED=$(( FAILED + 1 ))
		FAILED_LIST="${FAILED_LIST} ${dir}"
		sysrc -qf ${status_file} FAILED="${FAILED}"
		sysrc -qf ${status_file} FAILED_LIST="${FAILED_LIST}"
		sysrc -qf ${descr_status_file} FAILED="${FAILED}"
		sysrc -qf ${descr_status_file} FAILED_LIST="${FAILED_LIST}"
		echo -e "\033[40;35m Warning: skip port, no such directory: \033[0;32m${dir} \033[0m"
		continue
	fi

	#PORTNAME=$( make -C ${dir} -V PKGNAME )
	PORTNAME=$( make -C ${dir} -V PORTNAME )

	if [ -f /tmp/buildcontinue ]; then
		cd /tmp/packages
		pkg info -e ${PORTNAME} >/dev/null 2>&1 || {
			# errcode =1 when no package
			[ -f "./${PORTNAME}.txz" ] && env ASSUME_ALWAYS_YES=yes pkg add ./${PORTNAME}.txz && echo -e "\033[40;35m ${PORTNAME} found and added from cache. \033[0m"
		}
	fi

	echo "CHECK for $PORTNAME installed"
	pkg info -e ${PORTNAME}
	ret=$?

	if [ ${ret} -eq 0 ]; then
		echo "Already installed"
		continue
	fi

	echo "Not installed: ${PORTNAME} ( pkg info -e ${PORTNAME} )"
	#read p

	/bin/rm -f ${BUILDLOG}
	make -C ${dir} install |tee ${BUILDLOG}
	ret=$?


	# additional check for package installed
	pkg info -e ${PORTNAME} >/dev/null 2>&1
	[ $? -ne 0 ] && ret=1

	if [ ${ret} -ne 0 ]; then
		# debug
		echo "Second attemplt for ${dir}" >> /tmp/second.txt
		# second attempt
		make -C ${dir} clean
		/usr/bin/env MAKE_JOBS_UNSAFE=yes /usr/bin/env DISABLE_MAKE_JOBS=yes make -C ${dir} install |tee ${BUILDLOG}
		ret=$?
	fi

	rm -rf /tmp/usr/ports

	#set +o errexit
	if [ $ret -ne 0 ]; then
		FAILED=$(( FAILED + 1 ))
		FAILED_LIST="${FAILED_LIST} 1:${dir}"
		cp ${BUILDLOG} /tmp/log-${PORTNAME}.log
	else
		# additional check via pkg
		pkg info -e ${PORTNAME} >/dev/null 2>&1 || {
			# errcode =1 when no package
			FAILED=$(( FAILED + 1 ))
			FAILED_LIST="${FAILED_LIST} 2:${dir}"
			cp ${BUILDLOG} /tmp/log-${PORTNAME}.log
		}
	fi

	sysrc -qf ${status_file} FAILED="${FAILED}"
	sysrc -qf ${status_file} FAILED_LIST="${FAILED_LIST}"
	sysrc -qf ${descr_status_file} FAILED="${FAILED}"
	sysrc -qf ${descr_status_file} FAILED_LIST="${FAILED_LIST}"
done

end_date=$( /bin/date +%s )
sysrc -qf ${status_file} end_date="${end_date}"

diff_time=$(( end_date - st_date ))
run_time=$(( diff_time / 60 ))
sysrc -qf ${status_file} run_time="${run_time}"
sysrc -qf ${descr_status_file} run_time="${run_time}"

/bin/rm -f ${status_file} /tmp/cpr_error

exit 0
