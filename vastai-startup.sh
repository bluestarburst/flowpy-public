#!/bin/bash
set -o pipefail

# Log file for debugging
LOG_FILE="/tmp/tensordock-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Tensordock Setup Started at $(date) ==="
echo "Vast.ai Environment Variables:"
echo "  VAST_TCP_PORT_70000: ${VAST_TCP_PORT_70000:-not-set}"
echo "  VAST_UDP_PORT_70001: ${VAST_UDP_PORT_70001:-not-set}"
echo "  PUBLIC_IPADDR: ${PUBLIC_IPADDR:-not-set}"

# Wait for network (VMs take longer to boot, so timeout is expected)
wait_for_network() {
  local max_attempts=30
  local attempt=0
  echo "Waiting for network connectivity (VMs may take longer to boot)..."
  while [ $attempt -lt $max_attempts ]; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      echo "Network is available (attempt $((attempt + 1)))"
      return 0
    fi
    if [ $((attempt % 5)) -eq 0 ]; then
      echo "Waiting for network... attempt $((attempt + 1))/$max_attempts"
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Network check timeout after $max_attempts attempts (this is normal for VMs during boot) - continuing anyway"
  return 0
}

wait_for_network

# Check if we're running on a VM (VastAI Ubuntu 22.04 VM template)
# VMs have systemd, containers typically don't
is_vm() {
  # Check if systemctl works (VMs have it, containers typically don't)
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --version >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1 2>/dev/null; then
      return 0  # It's a VM
    fi
  fi
  
  # Check for systemd system directory (VMs have this)
  if [ -d /run/systemd/system ] && [ -d /sys/fs/cgroup/systemd ]; then
    return 0  # Likely a VM
  fi
  
  return 1  # Likely a container
}

# Check if Docker is already installed and working
check_docker() {
  if command -v docker >/dev/null 2>&1; then
    if docker --version >/dev/null 2>&1; then
      echo "Docker client is installed: $(docker --version)"
      if docker info >/dev/null 2>&1; then
        echo "Docker daemon is accessible and running"
        return 0
      else
        echo "Docker client installed but cannot connect to daemon"
        return 1
      fi
    fi
  fi
  return 1
}

# Setup Docker based on environment
if is_vm; then
  echo "Detected VM environment - using systemd for Docker management"
  echo "Docker should be pre-installed on VastAI Ubuntu 22.04 VM template"
  
  # Docker is pre-installed on VM template, just verify/start it
  if ! docker info >/dev/null 2>&1; then
    echo "Docker not running, starting via systemd..."
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    sleep 3
    
    if ! docker info >/dev/null 2>&1; then
      echo "ERROR: Docker failed to start on VM. Checking status..."
      systemctl status docker 2>&1 | head -20 || true
      echo "Attempting to install Docker if missing..."
      
      # Defensive fallback: install Docker if somehow missing
      if ! command -v docker >/dev/null 2>&1; then
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh || {
          echo "ERROR: Docker installation failed"
          exit 1
        }
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        sleep 3
      fi
      
      if ! docker info >/dev/null 2>&1; then
        echo "FATAL ERROR: Docker failed to start on VM after all attempts"
        exit 1
      fi
    fi
  fi
  echo "Docker is running and verified"
else
  echo "Detected container environment - setting up Docker-in-Docker..."
  
  # Check if Docker socket is mounted from host
  if [ -S /var/run/docker.sock ]; then
    echo "Docker socket found at /var/run/docker.sock (using host Docker)"
    
    # Install Docker CLI if not present
    if ! command -v docker >/dev/null 2>&1; then
      echo "Installing Docker CLI..."
      apt-get update -qq && apt-get install -y -qq docker.io >/dev/null 2>&1 || {
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
      }
    fi
    
    # Verify we can use Docker
    if docker info >/dev/null 2>&1; then
      echo "Successfully connected to Docker daemon via socket"
    else
      echo "ERROR: Cannot connect to Docker daemon. Checking permissions..."
      ls -la /var/run/docker.sock
      echo "Current user: $(whoami), UID: $(id -u), GID: $(id -g)"
      
      # Try to fix permissions (VastAI containers typically run as root)
      if [ "$(id -u)" -eq 0 ]; then
        chmod 666 /var/run/docker.sock 2>/dev/null || true
        echo "Adjusted socket permissions"
      fi
      
      # Try again
      if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Still cannot connect to Docker daemon"
        echo "Attempting to start Docker daemon in background..."
        
        # Start dockerd in background (for true Docker-in-Docker)
        dockerd --host=unix:///var/run/docker.sock --host=tcp://0.0.0.0:2375 >/tmp/dockerd.log 2>&1 &
        DOCKERD_PID=$!
        echo "Docker daemon started with PID: $DOCKERD_PID"
        
        # Wait for daemon to be ready
        for i in {1..30}; do
          if docker info >/dev/null 2>&1; then
            echo "Docker daemon is now ready"
            break
          fi
          echo "Waiting for Docker daemon... attempt $i/30"
          sleep 2
        done
      fi
    fi
  else
    echo "No Docker socket found - starting Docker daemon..."
    
    # Install Docker if needed
    if ! command -v docker >/dev/null 2>&1; then
      echo "Installing Docker..."
      curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
      sh /tmp/get-docker.sh
    fi
    
    # Start Docker daemon in background
    dockerd --host=unix:///var/run/docker.sock --host=tcp://0.0.0.0:2375 >/tmp/dockerd.log 2>&1 &
    DOCKERD_PID=$!
    echo "Docker daemon started with PID: $DOCKERD_PID"
    
    # Wait for daemon to be ready
    for i in {1..30}; do
      if docker info >/dev/null 2>&1; then
        echo "Docker daemon is now ready"
        break
      fi
      echo "Waiting for Docker daemon... attempt $i/30"
      sleep 2
    done
  fi
fi

# Final verification
if ! docker info >/dev/null 2>&1; then
  echo "FATAL ERROR: Docker is not accessible after all setup attempts"
  echo "Docker info output:"
  docker info 2>&1 || true
  exit 1
fi

echo "Docker setup complete and verified"

# Get instance ID from Vast.ai environment or use hostname
# Vast.ai doesn't provide a pod ID, so we'll use a combination of hostname and timestamp
INSTANCE_ID_VAL="${PUBLIC_IPADDR:-${HOSTNAME:-vast-unknown-instance}}"
echo "Instance ID: $INSTANCE_ID_VAL"
export INSTANCE_ID_VAL

# Generate Jupyter token if not provided in env var
if [ -z "$JUPYTER_TOKEN" ]; then
  export JUPYTER_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32 || echo "default-token-$(date +%s)")
fi

# Create control plane directory
mkdir -p /opt/tensordock-control-plane || {
  echo "ERROR: Failed to create control plane directory"
  exit 1
}

# Create start script
cat > /opt/tensordock-control-plane/start-control-plane.sh << 'STARTSCRIPT'
#!/bin/bash
set -o pipefail

# All these values are already set by Vast.ai from env field, just export them
export USER_ID="$USER_ID"
export INSTANCE_ID="$INSTANCE_ID_VAL"
export RESOURCE_TYPE="$RESOURCE_TYPE"
export FIREBASE_CREDENTIALS="$FIREBASE_CREDENTIALS"
export START_TURN="$START_TURN"
export JUPYTER_TOKEN="$JUPYTER_TOKEN"
export USER_CONTAINER_IMAGE="$USER_CONTAINER_IMAGE"
export CONTROL_PLANE_IMAGE="$CONTROL_PLANE_IMAGE"

# Validate required variables
if [ -z "$USER_ID" ] || [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "" ]; then
  echo "ERROR: Required environment variables are missing!"
  echo "  USER_ID: [${USER_ID:-<empty>}]"
  echo "  INSTANCE_ID: [${INSTANCE_ID:-<empty>}]"
  exit 1
fi

echo "Starting control plane with:"
echo "  USER_ID=$USER_ID"
echo "  INSTANCE_ID=$INSTANCE_ID"
echo "  RESOURCE_TYPE=$RESOURCE_TYPE"
echo "  START_TURN=$START_TURN"

# Pull image with retry
pull_attempts=0
max_pull_attempts=3
while [ $pull_attempts -lt $max_pull_attempts ]; do
  if docker pull "$CONTROL_PLANE_IMAGE"; then
    break
  fi
  pull_attempts=$((pull_attempts + 1))
  if [ $pull_attempts -lt $max_pull_attempts ]; then
    echo "Docker pull failed, retrying in 10 seconds..."
    sleep 10
  fi
done

# Remove existing container if it exists
docker rm -f tensordock-control-plane 2>/dev/null || true

# Verify Docker is still accessible (already checked in main script)
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker connection lost"
  exit 1
fi
echo "Docker connection verified"

# Start container
# Use Vast.ai port mappings: VAST_TCP_PORT_70000 for 8765, VAST_UDP_PORT_70001 for 3478
TURN_PORT=${VAST_UDP_PORT_70001:-3478}
TENSORDOCK_PORT=${VAST_TCP_PORT_70000:-8765}

docker run -d \
  --name tensordock-control-plane \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p $TENSORDOCK_PORT:8765 \
  -p $TURN_PORT:3478/udp \
  -e USER_ID="$USER_ID" \
  -e INSTANCE_ID="$INSTANCE_ID" \
  -e RESOURCE_TYPE="$RESOURCE_TYPE" \
  -e FIREBASE_CREDENTIALS="$FIREBASE_CREDENTIALS" \
  -e START_TURN="$START_TURN" \
  -e JUPYTER_TOKEN="$JUPYTER_TOKEN" \
  -e USER_CONTAINER_IMAGE="$USER_CONTAINER_IMAGE" \
  "$CONTROL_PLANE_IMAGE" || {
    echo "ERROR: Failed to start control plane container"
    exit 1
  }

echo "Control plane container started successfully"
echo "Using ports: TCP=$TENSORDOCK_PORT, UDP=$TURN_PORT"
STARTSCRIPT

chmod +x /opt/tensordock-control-plane/start-control-plane.sh || {
  echo "ERROR: Failed to make start script executable"
  exit 1
}

# Run the start script
/opt/tensordock-control-plane/start-control-plane.sh || {
  echo "ERROR: Control plane start script failed"
}

# Configure firewall (only on VMs, not in containers)
if is_vm && command -v ufw >/dev/null 2>&1; then
  echo "Configuring firewall on VM..."
  ufw allow 8765/tcp || true
  ufw allow 3478/udp || true
  ufw --force enable || true
  echo "Firewall configured"
else
  echo "Skipping firewall configuration (not needed or not available)"
fi

echo "=== Tensordock Setup Completed at $(date) ==="

