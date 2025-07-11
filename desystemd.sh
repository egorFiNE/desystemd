#!/bin/bash

function remove_snap() {
  which snap
  local snap_installed=$?

  if (( snap_installed == 0 )); then
    # FIXME better:
    snap list --all | awk '{ print $1 }' | grep -v '^Name' | xargs -n1 snap remove
    echo "Removed all snaps"
    apt -y purge --auto-remove snapd

    systemctl stop snapd.mounts-pre.target
    systemctl mask snapd.mounts-pre.target

    rm -rf /var/run/snapd*
  else
    echo "Snap not installed"
  fi
}

function remove_timers() {
  # Those are disabled permanently, so we can remove them
  local SHIT="sysstat-collect.XXX fwupd-refresh.XXX dpkg-db-backup.XXX sysstat-rotate.XXX sysstat-summary.XXX motd-news.XXX apt-daily-upgrade.XXX \
    man-db.XXX apt-daily.XXX update-notifier-download.XXX update-notifier-motd.XXX apport-autoreport.XXX ua-timer.XXX"

  local timers=$(echo $SHIT | sed 's/\.XXX/.timer/g')
  local services=$(echo $SHIT | sed 's/\.XXX/.service/g')

  systemctl stop $timers $services
  systemctl mask $timers $services

  # Those we will need to bring back to cron, so this is why it's listed separately
  SHIT="e2scrub_all.XXX logrotate.XXX systemd-tmpfiles-clean.XXX fstrim.XXX"

  timers=$(echo $SHIT | sed 's/\.XXX/.timer/g')
  services=$(echo $SHIT | sed 's/\.XXX/.service/g')

  systemctl stop $timers $services
  systemctl mask $timers $services

  # Get rid of "useful" cronjobs, as in: updating motd, updating apt, rebuilding man pages, etc
  rm -v /etc/cron.*/*

  mkdir -p /etc/cron.daily /etc/cron.weekly

  # Bring back basic cron stuff that is actually needed
  echo '/usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.daily/logrotate-desystemd
  echo '/sbin/fstrim --listed-in /etc/fstab:/proc/self/mountinfo --verbose --quiet-unsupported' > /etc/cron.weekly/fstrim-desystemd
  echo '/sbin/e2scrub_all -A -r' > /etc/cron.daily/e2scrub_all-desystemd
  echo 'systemd-tmpfiles --clean' > /etc/cron.daily/systemd-tmpfiles-clean-desystemd

  chmod +x /etc/cron.*/*

  echo "Removed systemd timers and useless cronjobs"
}

function setup_ifupdown() {
  # Figure out the first network interface
  local interface=$(ip -o link list| grep -v 'LOOPBACK' | awk '{ print $2 }' | sed 's/://g')

  if [[ -z "$interface" ]]; then
    echo "No network interfaces found, cannot set up ifupdown"
    exit 1
  fi

  echo "First interface is ${interface}"

  apt -y install ifupdown
  apt -y purge --auto-remove netplan.io libnetplan1 netplan-generator python3-netplan cloud-init cloud-init-base networkd-dispatcher

  # write down basic interfaces
  cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback
auto $interface
iface $interface inet dhcp
EOF

  ifup $interface

  # Cleanup after cleanup
  rm -rf /usr/share/netplan /etc/netplan

  systemctl mask systemd-networkd.service systemd-networkd.socket

  echo "Installed ifupdown and set first network interface $interface as dhcp client"
}

function remove_systemd_from_pam() {
  cd /etc/pam.d

  for i in *; do
    cat $i | grep -v systemd > tmp && mv tmp $i
  done

  cd -
}

function make_logind_useless() {
  cat > /etc/systemd/logind.conf <<EOF
[Login]
KillUserProcesses=no
RemoveIPC=no
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleRebootKey=ignore
HandleRebootKeyLongPress=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=0
EOF

  systemctl restart systemd-logind
}

function clean_and_purge_dpkg() {
  local packages_to_purge=$(dpkg -l | grep ^rc | awk '{ print $2 }')

  if [[ $packages_to_purge ]]; then
    dpkg --purge $packages_to_purge
  fi

  apt -y autoremove
}

function get_rid_of_journald() {
  local SHIT="systemd-journal-catalog-update.service systemd-journal-flush.service systemd-journald-audit.socket systemd-journald-dev-log.socket \
    systemd-journald.service systemd-journald.socket"
  systemctl stop $SHIT
  systemctl mask $SHIT
  rm -rf /var/log/journal
  echo "Disabled systemd-journald"
}

function make_ssh_great_again() {
  systemctl disable --now ssh.socket
  systemctl mask ssh.socket
  systemctl enable --now ssh.service
  echo "Removed fake systemd sshd listener and reverted for sshd to listen on it's own"
}

function enable_chrony() {
  apt -y install chrony # this will also remove timesyncd
  systemctl enable --now chrony
  # At this point systemd-resolved is already removed but it doesn't hurt to ask for removal anyway
  apt -y purge --auto-remove systemd-timesyncd
  echo "Enabled chrony"
}

function fix_resolver() {
  apt -y purge --auto-remove systemd-resolved

  rm -f /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf

  echo "Fixed resolver"
}

################## MAIN ##################

# Check environment
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Check OS and version
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
fi

if [[ "${VERSION_ID:-}" != "25.04" ]]; then
  echo "This script is only supported on Ubuntu 25.04"
  exit 1
fi

# Check if ubuntu-desktop is installed
if [[ -n "$(dpkg -l | grep ubuntu-desktop)" ]]; then
  echo "This script is not supported on Ubuntu Desktop"
  exit 1
fi

echo "Updating package list"
apt update
apt -y upgrade

should_purge_timers="true"
should_setup_ifupdown="true"

while [ $# -gt 0 ]; do
  case "$1" in
    "--help")
    cat<<EOF
Usage: $0
  --keep-timers        Do not remove systemd timers and useless cronjobs
  --skip-ifupdown      Do not install ifupdown
EOF
    exit 1
    ;;
    "--build-dir")
    BUILD_DIR="$2"
    shift
    ;;
    "--keep-timers")
    should_purge_timers=""
    ;;
    "--skip-ifupdown")
    should_setup_ifupdown=""
    ;;
    *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
  shift
done

# Enable chrony instead of timesyncd
enable_chrony

# Fix resolver after removal of systemd-resolved
fix_resolver

# Bring back ssh daemon and get rid of socket activation
make_ssh_great_again

# Journald can't be removed, so we have to thoroughly disable it
get_rid_of_journald

# Remove snaps completely
remove_snap

# Remove systemd timers and replace with small set of cron jobs
[[ $should_purge_timers ]] && remove_timers

# Remove whatever is it used today for the network management and replace it with ifupdown
[[ $should_setup_ifupdown ]] && setup_ifupdown

SHIT="apport-forward.socket apport systemd-rfkill.socket systemd-rfkill.service udisks2.service multipathd.service \
  dm-event.socket dm-event.service systemd-fsckd.socket systemd-fsckd.service unattended-upgrades.service polkit.service"
systemctl stop $SHIT
systemctl mask $SHIT

SHIT="systemd-resolved python3-systemd modemmanager uuid-runtime open-iscsi systemd-hwe-hwdb landscape-common plymouth unattended-upgrades"
apt -y purge --auto-remove $SHIT

# Remove systemd and capabilities from pam chain
remove_systemd_from_pam

# logind cannot be removed, but we can make it useless
make_logind_useless

# There is no going back to proper filesystem, so just remove the flag
# rm -rf /*is-merged*

# At this point there should be no packages in "uninstalled not purged" state, but let's keep the command line here for refs
clean_and_purge_dpkg

# Delete misc directories
rm -rf /var/lib/update-notifier /var/lib/ubuntu-release-upgrader /var/log/unattended-upgrades /lib/udev/hwdb.d

echo "Finished. Please reboot!"
