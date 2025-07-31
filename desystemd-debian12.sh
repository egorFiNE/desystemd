#!/bin/bash

# Cleanup Debian 12 installation from systemd and other stuff that is not needed on a server.

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

if [[ "${VERSION_ID:-}" != "12" ]]; then
  echo "This script is only supported on Debian 12"
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

# FIXME maybe keep for now?
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

# FIXME maybe give up on switching back to cron?
####################################################################################################
# Remove systemd timers and replace them all with small set of cron jobs
####################################################################################################

# Those are disabled permanently, so we can remove them
SHIT="dpkg-db-backup.XXX apt-daily.XXX apt-daily-upgrade.XXX man-db.XXX"

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

  SHIT="netplan.io libnetplan0 cloud-init"
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
# logind can be removed on Debian
####################################################################################################

systemctl mask systemd-logind
systemctl stop systemd-logind

echo "Disabled systemd-logind"

####################################################################################################
# Remove misc packages that are not needed
####################################################################################################

SHIT="uuid-runtime polkitd unattended-upgrades libpam-systemd"
apt -y purge --auto-remove $SHIT

####################################################################################################
# Remove systemd and capabilities from pam chain
####################################################################################################

for i in /etc/pam.d/*; do
  cat $i | grep -v systemd > tmp && mv tmp $i
done

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

rm -rf /var/log/unattended-upgrades

####################################################################################################

echo "Finished. Please reboot!"
