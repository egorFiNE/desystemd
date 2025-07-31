#!/bin/bash

# Cleanup ubuntu installation from systemd and other stuff that is not needed on a server.

####################################################################################################
# Please read me before running!
#
# In order to enforce this rule, there is an exit statement somewhere in the middle of the script
# prior to the actual work. Review the script, make sure you understand what it does, then
# remove the exit statement and run as root.
####################################################################################################

# If set to true, all network management software will be removed and ifupdown will be installed
# for simple and sane configuration. Make sure you truly understand what this means before
# enabling this, because it might render your server offline.
should_setup_ifupdown="false"

# Check user
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
if dpkg -s ubuntu-desktop >/dev/null 2>&1; then
  echo "This script is not supported on Ubuntu Desktop"
  exit 1
fi

echo "Updating package list"
apt update
apt -y upgrade

####################################################################################################
# Enable chrony instead of timesyncd
####################################################################################################

exit
# This will also remove timesyncd
apt -y install chrony
# At this point systemd-timesyncd is already removed but it doesn't hurt to ask for removal anyway
apt -y purge --auto-remove systemd-timesyncd

systemctl enable --now chrony

echo "Enabled chrony"

####################################################################################################
# Fix resolver
####################################################################################################

apt -y purge --auto-remove systemd-resolved

rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

echo "Got rid of systemd-resolved and set up resolv.conf with public DNS servers"

####################################################################################################
# Bring back ssh daemon and get rid of socket activation
####################################################################################################

systemctl disable --now ssh.socket
systemctl mask ssh.socket
systemctl enable --now ssh.service

echo "Removed fake systemd sshd listener and reverted for sshd to listen on it's own"

####################################################################################################
# Journald can't be removed, so we have to thoroughly disable it
####################################################################################################

SHIT="systemd-journal-catalog-update.service systemd-journal-flush.service \
  systemd-journald-audit.socket systemd-journald-dev-log.socket systemd-journald.service \
  systemd-journald.socket"

systemctl stop $SHIT
systemctl mask $SHIT

rm -rf /var/log/journal

echo "Disabled systemd-journald"

####################################################################################################
# Remove snaps
####################################################################################################

if command -v snap >/dev/null 2>&1; then
  snaps=$(snap list --all | awk '{ print $1 }' | grep -v '^Name')
  if [[ -n "$snaps" ]]; then
    snap remove --purge $snaps
  fi

  echo "Removed all snaps"

  apt -y purge --auto-remove snapd

  systemctl stop snapd.mounts-pre.target
  systemctl mask snapd.mounts-pre.target

  rm -rf /var/run/snapd*

  echo "Removed snapd completely"
fi

####################################################################################################
# Remove systemd timers and replace them all with small set of cron jobs
####################################################################################################

# Those are disabled permanently, so we can remove them
SHIT="sysstat-collect.XXX fwupd-refresh.XXX dpkg-db-backup.XXX sysstat-rotate.XXX \
  sysstat-summary.XXX motd-news.XXX apt-daily-upgrade.XXX man-db.XXX apt-daily.XXX \
  update-notifier-download.XXX update-notifier-motd.XXX apport-autoreport.XXX ua-timer.XXX"

timers=$(echo $SHIT | sed 's/\.XXX/.timer/g')
services=$(echo $SHIT | sed 's/\.XXX/.service/g')

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

####################################################################################################
# Remove whatever is it used today for the network management and replace it with ifupdown
####################################################################################################

if [[ $should_setup_ifupdown ]]; then
  # Figure out the first network interface
  # ip -o link show up lists only interfaces that are UP.
  # The awk filters out any with "LOOPBACK" or named "lo".
  # The first match is printed and the loop exits.
  interface=$(ip -o link show up | awk -F': ' '!/LOOPBACK/ && $2 !~ /lo|docker|veth|br-|virbr|vmnet|tap|tun/ { print $2; exit }')

  if [[ -z "$interface" ]]; then
    echo "No network interfaces found, cannot set up ifupdown"
    exit 1
  fi

  echo "First interface is ${interface}"

  apt -y install ifupdown

  SHIT="netplan.io libnetplan1 netplan-generator python3-netplan cloud-init cloud-init-base \
    networkd-dispatcher"
  apt -y purge --auto-remove $SHIT

  # Write down basic interfaces file
  cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback
auto $interface
iface $interface inet dhcp
EOF

  SHIT="systemd-networkd.service systemd-networkd.socket"

  # network down
  systemctl stop $SHIT

  # network up
  ifup -a

  # Disable systemd
  systemctl mask $SHIT

  # Cleanup after cleanup
  rm -rf /usr/share/netplan /etc/netplan

  echo "Installed ifupdown and set first network interface $interface as dhcp client"
fi

####################################################################################################
# Remove systemd and capabilities from pam chain
####################################################################################################

for i in /etc/pam.d/*; do
  cat $i | grep -v systemd > tmp && mv tmp $i
done

####################################################################################################
# logind cannot be removed, but we can make it useless
####################################################################################################

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

echo "Disabled most of the systemd-logind"

####################################################################################################
# Remove misc packages that are not needed
####################################################################################################

# Those cannot be removed so we have to stop and disable them
SHIT="apport-forward.socket apport systemd-rfkill.socket systemd-rfkill.service udisks2.service \
  multipathd.service dm-event.socket dm-event.service systemd-fsckd.socket systemd-fsckd.service \
  unattended-upgrades.service polkit.service"

systemctl stop $SHIT
systemctl mask $SHIT

# Thos can be removed
SHIT="python3-systemd modemmanager uuid-runtime open-iscsi systemd-hwe-hwdb landscape-common \
  plymouth unattended-upgrades"
apt -y purge --auto-remove $SHIT

####################################################################################################
# Cleanup apt of zombie packages
####################################################################################################

# At this point there should be no packages in "uninstalled not purged"
# state, but let's make sure.

packages_to_purge=$(dpkg -l | grep ^rc | awk '{ print $2 }')

if [[ $packages_to_purge ]]; then
  dpkg --purge $packages_to_purge
fi

apt -y autoremove

####################################################################################################
# Delete misc directories
####################################################################################################

rm -rf /var/lib/update-notifier /var/lib/ubuntu-release-upgrader /var/log/unattended-upgrades
rm -rf /lib/udev/hwdb.d

# Unfortunately there is no going back to proper /usr vs / layout
rm -rf /*is-merged*

####################################################################################################

echo "Finished. Please reboot!"
