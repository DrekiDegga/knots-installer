#!/bin/bash

# Script to install and configure Bitcoin Knots and Tor on Ubuntu/Debian
# Run with sudo: sudo ./install_bitcoin_knots.sh

# Exit on error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_VERSION="28.1.knots20250305"
DEFAULT_ARCH="x86_64-linux-gnu"
DEFAULT_USER="bitcoin"
DEFAULT_DATA_DIR="$HOME/.bitcoin"
DEFAULT_PRUNE_SIZE="10000" # 10 GB
BITCOIN_PORT="8333"

# Function to print messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to validate input
validate_input() {
    local input=$1
    local prompt=$2
    while [[ -z "$input" ]]; do
        read -p "$prompt" input
    done
    echo "$input"
}

# Function to validate yes/no input
validate_yes_no() {
    local prompt=$1
    local response
    while true; do
        read -p "$prompt (y/n): " response
        case "$response" in
            [Yy]* ) echo "yes"; break;;
            [Nn]* ) echo "no"; break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_message "$RED" "This script must be run as root (use sudo)."
    exit 1
fi

# Check if system is Ubuntu or Debian
if ! lsb_release -a 2>/dev/null | grep -qE "Ubuntu|Debian"; then
    print_message "$YELLOW" "This script is designed for Ubuntu or Debian systems. Proceed with caution."
    if [[ $(validate_yes_no "Continue anyway?") == "no" ]]; then
        exit 1
    fi
fi

# Prompt for user inputs
print_message "$GREEN" "Bitcoin Knots Installation Script"
read -p "Enter Bitcoin Knots version (default: $DEFAULT_VERSION): " VERSION
VERSION=${VERSION:-$DEFAULT_VERSION}

read -p "Enter system architecture (default: $DEFAULT_ARCH): " ARCH
ARCH=${ARCH:-$DEFAULT_ARCH}

read -p "Enter current user name (default: $DEFAULT_USER): " CURRENT_USER
CURRENT_USER=${CURRENT_USER:-$DEFAULT_USER}

read -p "Enter data directory for Bitcoin Knots (default: $DEFAULT_DATA_DIR): " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}

RPC_USER=$(validate_input "" "Enter RPC username for Bitcoin Knots: ")
RPC_PASSWORD=$(validate_input "" "Enter RPC password for Bitcoin Knots: ")
TOR_PASSWORD=$(validate_input "" "Enter Tor control password: ")

PRUNE=$(validate_yes_no "Enable pruning to save disk space? (Recommended for limited storage)")
if [[ "$PRUNE" == "yes" ]]; then
    read -p "Enter prune size in MB (default: $DEFAULT_PRUNE_SIZE): " PRUNE_SIZE
    PRUNE_SIZE=${PRUNE_SIZE:-$DEFAULT_PRUNE_SIZE}
fi

# Get current user
#CURRENT_USER=$(who | awk '{print $1}' | head -n 1)
#CURRENT_USER=dreki
# Update system
print_message "$GREEN" "Updating system packages..."
apt update && apt upgrade -y

# Install dependencies
print_message "$GREEN" "Installing dependencies..."
apt install -y wget gnupg ufw tor

# Download Bitcoin Knots
print_message "$GREEN" "Downloading Bitcoin Knots version $VERSION..."
BASE_URL="https://bitcoinknots.org/files/28.x/$VERSION"
TARBALL="bitcoin-$VERSION-$ARCH.tar.gz"
wget "$BASE_URL/$TARBALL"
wget "$BASE_URL/SHA256SUMS"
wget "$BASE_URL/SHA256SUMS.asc"

# Verify checksum
print_message "$GREEN" "Verifying checksum..."
sha256sum --ignore-missing --check SHA256SUMS || {
    print_message "$RED" "Checksum verification failed!"
    exit 1
}

# Import and verify GPG keys (I downloaded and manually imported the keys from here: https://github.com/bitcoinknots/guix.sigs/tree/knots/builder-keys)
#print_message "$GREEN" "Verifying GPG signature..."
#gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys E463A93F5F3117EEDE6C7316BD02942421F4889F || {
#    print_message "$YELLOW" "GPG key import failed. Trying to proceed..."
#}
gpg --verify SHA256SUMS.asc SHA256SUMS || {
    print_message "$RED" "GPG signature verification failed!"
    exit 1
}

# Extract and install Bitcoin Knots
print_message "$GREEN" "Installing Bitcoin Knots..."
tar -xvf "$TARBALL"
install -m 0755 -o root -g root -t /usr/local/bin "bitcoin-$VERSION/bin/"*

# Create data directory
print_message "$GREEN" "Creating data directory at $DATA_DIR..."
mkdir -p "$DATA_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$DATA_DIR"

# Configure Bitcoin Knots
print_message "$GREEN" "Configuring Bitcoin Knots..."
cat > "$DATA_DIR/bitcoin.conf" <<EOF
daemon=1
server=1
rpcuser=$RPC_USER
rpcpassword=$RPC_PASSWORD
rpcallowip=127.0.0.1
listen=1
txindex=1
rejectparasites=1
datacarrier=0
permitbaremultisig=0
torcontrol=127.0.0.1:9051
torpassword=$TOR_PASSWORD
EOF

# Add pruning if enabled
if [[ "$PRUNE" == "yes" ]]; then
    echo "prune=$PRUNE_SIZE" >> "$DATA_DIR/bitcoin.conf"
fi

# Secure configuration file
chmod 600 "$DATA_DIR/bitcoin.conf"
chown "$CURRENT_USER:$CURRENT_USER" "$DATA_DIR/bitcoin.conf"

# Configure Tor
print_message "$GREEN" "Configuring Tor..."
cat > /etc/tor/torrc <<EOF
ControlPort 9051
CookieAuthentication 1
HiddenServiceDir /var/lib/tor/bitcoin-service/
HiddenServicePort 8333 127.0.0.1:8333
EOF

# Set Tor permissions
chown -R debian-tor:debian-tor /var/lib/tor
chmod -R 700 /var/lib/tor

# Restart Tor to apply changes
print_message "$GREEN" "Restarting Tor..."
systemctl restart tor

# Configure firewall
print_message "$GREEN" "Configuring firewall..."
ufw allow $BITCOIN_PORT
ufw allow 9050
ufw allow 9051
ufw --force enable

# Create systemd service for Bitcoin Knots
print_message "$GREEN" "Creating systemd service..."
cat > /etc/systemd/system/bitcoind.service <<EOF
[Unit]
Description=Bitcoin Knots Daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/bitcoind -daemon -conf=$DATA_DIR/bitcoin.conf -datadir=$DATA_DIR
User=$CURRENT_USER
Group=$CURRENT_USER
Type=forking
PIDFile=$DATA_DIR/bitcoind.pid
Restart=on-failure
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
print_message "$GREEN" "Starting Bitcoin Knots service..."
systemctl daemon-reload
systemctl enable bitcoind.service
systemctl start bitcoind.service

# Display completion message
print_message "$GREEN" "Installation and configuration complete!"
print_message "$YELLOW" "Bitcoin Knots is now running and syncing the blockchain. This may take hours or days."
print_message "$YELLOW" "To check sync status, run: bitcoin-cli -datadir=$DATA_DIR getblockchaininfo"
print_message "$YELLOW" "Your Tor onion address is in /var/lib/tor/bitcoin-service/hostname"
print_message "$YELLOW" "Backup your wallet file at $DATA_DIR/wallet.dat if using Bitcoin Knots as a wallet."

exit 0
