#!/bin/bash

# Exit on any error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Prompt for required inputs
echo "Please provide the following details:"
read -p "Enter ETH Sepolia RPC URL: " RPC_URL
read -p "Enter ETH Beacon Sepolia RPC URL: " BEACON_URL
read -p "Enter Sequencer Private Key (0x...): " VALIDATOR_PRIVATE_KEY
read -p "Enter Sequencer Address (0x...): " COINBASE_ADDRESS
read -p "Enter IP VPS: " P2P_IP

# Validate inputs
if [ -z "$RPC_URL" ] || [ -z "$BEACON_URL" ] || [ -z "$VALIDATOR_PRIVATE_KEY" ] || [ -z "$COINBASE_ADDRESS" ] || [ -z "$P2P_IP" ]; then
    echo "Error: All inputs are required."
    exit 1
fi

echo "Starting Aztec Sequencer node setup..."

# Step 1: Update packages
echo "Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y

# Step 2: Install required packages
echo "Installing required packages..."
sudo apt install -y curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip

# Step 3: Install Docker if not already installed
if ! command_exists docker; then
    echo "Installing Docker..."
    sudo apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(source /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable docker
    sudo systemctl restart docker
    sudo docker run hello-world
else
    echo "Docker is already installed, skipping..."
fi

# Step 4: Install Aztec Tools as current user
echo "Installing Aztec Tools..."
bash -i <(curl -s https://install.aztec.network) <<< "y"

# Add ~/.aztec/bin to PATH
echo "Adding ~/.aztec/bin to PATH..."
if ! grep -q "$HOME/.aztec/bin" ~/.bashrc; then
    echo 'export PATH=$PATH:$HOME/.aztec/bin' >> ~/.bashrc
fi
if [ -f ~/.bash_profile ] && ! grep -q "$HOME/.aztec/bin" ~/.bash_profile; then
    echo 'export PATH=$PATH:$HOME/.aztec/bin' >> ~/.bash_profile
fi

source ~/.bashrc || true
source ~/.bash_profile || true

# Verify Aztec installation
echo "Verifying Aztec installation..."
if command_exists aztec; then
    echo "Aztec installed successfully. Version: $(aztec --version)"
else
    echo "Error: Aztec not found in PATH. Check ~/.aztec/bin manually."
    exit 1
fi

# Update Aztec to alpha-testnet
echo "Updating Aztec to alpha-testnet..."
aztec-up alpha-testnet

# Step 5: Configure firewall
echo "Configuring firewall..."
sudo ufw allow 22
sudo ufw allow ssh
sudo ufw allow 40400
sudo ufw allow 8080
echo "y" | sudo ufw enable
sudo ufw reload

# Step 6: Start tmux session
echo "Starting tmux session..."
if ! command_exists tmux; then
    sudo apt install -y tmux
fi
tmux new-session -d -s aztec

# Step 7: Run Aztec Sequencer Node
echo "Starting Aztec Sequencer Node in tmux..."
NODE_COMMAND="aztec start --node --archiver --sequencer --network alpha-testnet --l1-rpc-urls \"$RPC_URL\" --l1-consensus-host-urls \"$BEACON_URL\" --sequencer.validatorPrivateKey \"$VALIDATOR_PRIVATE_KEY\" --sequencer.coinbase \"$COINBASE_ADDRESS\" --p2p.p2pIp \"$P2P_IP\" --p2p.maxTxPoolSize 1000000000"
tmux send-keys -t aztec "$NODE_COMMAND" C-m

# Step 8: Check if node is reachable
echo "Waiting for node to start..."
sleep 60

check_node() {
    curl -s -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"node_getL2Tips","params":[],"id":67}' \
        http://localhost:8080 >/dev/null 2>&1
    return $?
}

MAX_WAIT=600
WAIT_INTERVAL=10
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if check_node; then
        echo "Node is reachable!"
        break
    fi
    echo "Waiting... ($ELAPSED/$MAX_WAIT seconds)"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "Node not reachable. Showing recent logs..."
    CONTAINER_ID=$(sudo docker ps -a -q --filter ancestor=aztecprotocol/aztec | head -n 1)
    if [ -n "$CONTAINER_ID" ]; then
        sudo docker logs --tail 50 "$CONTAINER_ID"
    else
        echo "No Aztec container found."
    fi
    echo "Check tmux: tmux attach -t aztec"
    exit 1
fi

echo "Aztec Sequencer Node setup complete."
