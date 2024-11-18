#!/bin/bash

# Check environment
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Check OS and version
if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

if [ "x$VERSION_ID" != "x24.04" ]; then
  echo "This script is only supported on Ubuntu 24.04"
  exit 1
fi

# Check if ubuntu-desktop is installed
if [ -n "$(dpkg -l | grep ubuntu-desktop)" ]; then
  echo "This script is not supported on Ubuntu Desktop"
  exit 1
fi

echo "Updating package list and installing 'dialog' for this script's UI"
apt update

apt -y install dialog

dialog --stderr --no-tags --checklist 'Select additional areas to fix:' 20 70 18 \
  snap 'Remove snap(s)' on \
  cron 'Remove all cronjobs and timers except logrotate and fstrim' off \
  ifupdown 'Revert networking to ifupdown (DANGEROUS!)' off \
  misc 'Remove misc useless packages (see script source)' off \
  2> /tmp/desystemd_choices

if (( $? != 0 )); then
  exit 1
fi

useless_packages="lxd-installer systemd-resolved multipath-tools polkitd libpolkit-gobject-1-0 udisks2 open-iscsi systemd-hwe-hwdb"
useless_packages="$useless_packages landscape-common apport uuid-runtime apparmor plymouth"

should_remove_snap=""
should_purge_cron=""
should_setup_ifupdown=""
packages_to_remove="systemd-timesyncd systemd-resolved python3-systemd"
should_purge_useless="o"

for i in `cat /tmp/desystemd_choices`; do
  case $i in
    snap)
      should_remove_snap="on"
      ;;
    cron)
      should_purge_cron="on"
      ;;
    misc)
      packages_to_remove="$packages_to_remove $useless_packages"
      should_purge_useless="on"
      ;;
    ifupdown)
      # install separately
      should_setup_ifupdown="on"
      ;;
  esac
done

apt -y install chrony
apt -y purge --auto-remove $packages_to_remove

# Fix resolver after removal of systemd-resolved
xattr -i /etc/resolv.conf # just in case we ran this script before
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf

echo "Fixed resolver"

# ifupdown may overwrite /etc/resolv.conf and that's okay. What's not okay is systemd-resolved reinstalling itself and overwriting it.
if [ "x$should_setup_ifupdown" != "xon" ]; then
  chattr +i /etc/resolv.conf
  echo "Made /etc/resolv.conf immutable"
fi

# Enable chrony instead of timesyncd
systemctl enable --now chrony
echo "Enabled chrony"

# Bring back ssh daemon and get rid of socket activation
systemctl disable --now ssh.socket
systemctl mask ssh.socket
systemctl enable --now ssh.service
echo "Removed fake systemd sshd listener and reverted for sshd to listen on it's own"

# Get rid of journald
# FIXME research all of these
SHIT="systemd-journal-flush.service systemd-journald-audit.socket systemd-journald-dev-log.socket systemd-journald.service systemd-journald.socket"
systemctl stop $SHIT
systemctl disable $SHIT
systemctl mask $SHIT

rm -rf /var/log/journal

echo "Disabled systemd-journald"

if [ "x$should_remove_snap" = "xon" ]; then
  which snap
  if (( $? = 0 )); then
    snap list | awk '{print $1}' | grep -v '^Name' | xargs -n1 snap remove
    echo "Removed all snaps"
    apt -y purge snapd
  else
    echo "Snap not installed"
  fi
fi

if [ "x$should_purge_cron" = "xon" ]; then
  # FIXME Research security upgrade procedures and make these a choice
  SHIT="apt-daily-upgrade.service apt-daily.service"
  systemctl stop $SHIT
  systemctl disable $SHIT
  systemctl mask $SHIT

  # Not sure if we need these: FIXME
  systemctl kill --kill-who=all apt-daily.service
  systemctl kill --kill-who=all apt-daily-upgrade.service

  # Get rid of systemd timers, all of them FIXME research
  for i in `systemctl list-unit-files --type=timer --all --plain --no-legend | awk '{print $1}'`
  do
    systemctl disable $i
    systemctl mask $i
  done

  # Get rid of "useful" cronjobs, as in: updating motd, updating apt, rebuilding man pages, etc
  # FIXME research
  rm -v /etc/cron.*/*

  # Bring back basic cron stuff that is actually needed
  echo '/usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.daily/logrotate
  echo 'fstrim -v -a' > /etc/cron.weekly/fstrim
  chmod +x /etc/cron.*/*

  echo "Removed systemd timers and useless cronjobs"
fi

if [ "x$should_setup_ifupdown" = "xon" ]; then
  # Figure out the first network interface
  interface=`ip -o link list| grep -v 'LOOPBACK'| awk '{print $2}' | sed 's/://g'`
  echo "First interface is ${interface}"

  apt -y install ifupdown
  apt -y purge netplan.io netplan-generator python3-netplan libnetplan1 networkd-dispatcher

  # write down basic interfaces
  cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback
auto $interface
iface $interface inet dhcp
EOF

  ifup $interface

  # Cleanup after cleanup
  rm -rf /usr/share/netplan/netplan_cli/cli/commands /usr/lib/python3/dist-packages/netplan /etc/netplan

  systemctl mask systemd-networkd.service systemd-networkd.socket # FIXME research

  echo "Installed ifupdown and set first network interface ${interface} as dhcp client"
fi

if [ "x$should_purge_useless" != "x" ]; then
  # FIXME research all of these
  rm -rf /lib/udev/hwdb.d /etc/apparmor.d/ /etc/xml /etc/sgml /usr/lib/systemd/system-shutdown /etc/cloud

  # FIXME research all of these
  SHIT="dm-event.socket systemd-fsckd.socket systemd-logind.service systemd-rfkill.socket"

  systemctl stop $SHIT
  systemctl disable $SHIT
  systemctl mask $SHIT

  # FIXME research all of these
  # Remove systemd and capabilities from pam chain
  cd /etc/pam.d
  cat common-session | grep -v systemd > tmp && mv tmp common-session
  cat common-auth | grep -v pam_cap.so > tmp && mv tmp common-auth
  cd -
fi

# There is no going back to proper filesystem, so just remove the flag
rm -rf /*is-merged*

# At this point there should be no packages in "uninstalled not purged" state, but let's keep the command line here for refs
packages_to_purge=`dpkg -l | grep ^rc | awk '{print $2}'`

if [ "x$packages_to_purge" != "x" ]; then
  dpkg --purge $packages_to_purge
fi


echo "Finished!"
