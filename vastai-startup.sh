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

# Wait for network
wait_for_network() {
  local max_attempts=30
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      echo "Network is available"
      return 0
    fi
    echo "Waiting for network... attempt $((attempt + 1))/$max_attempts"
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Warning: Network check timeout, continuing anyway"
  return 0
}

wait_for_network

# Check if Docker is already installed and working
check_docker() {
  if command -v docker >/dev/null 2>&1; then
    if docker --version >/dev/null 2>&1; then
      echo "Docker is already installed: $(docker --version)"
      if docker info >/dev/null 2>&1; then
        echo "Docker daemon is running"
        return 0
      else
        echo "Docker installed but daemon not running, starting service..."
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        sleep 2
        if docker info >/dev/null 2>&1; then
          echo "Docker daemon started successfully"
          return 0
        fi
      fi
    fi
  fi
  return 1
}

# Install Docker if needed
if ! check_docker; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh || {
    echo "ERROR: Docker installation failed, but continuing..."
    check_docker || echo "WARNING: Docker may not be available"
  }
fi

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

# Configure docker daemon wait helper
wait_for_docker_daemon() {
  local max_attempts=20
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if docker info >/dev/null 2>&1; then
      echo "Docker daemon is running"
      return 0
    fi
    echo "Waiting for Docker daemon... attempt $((attempt + 1))/$max_attempts"
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    sleep 3
    attempt=$((attempt + 1))
  done
  echo "ERROR: Docker daemon did not become ready"
  return 1
}

wait_for_docker_daemon || exit 1

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

# Configure firewall (if ufw is available)
if command -v ufw >/dev/null 2>&1; then
  echo "Configuring firewall..."
  ufw allow 8765/tcp || true
  ufw allow 3478/udp || true
  ufw --force enable || true
  echo "Firewall configured"
else
  echo "ufw not available, skipping firewall configuration"
fi

echo "=== Tensordock Setup Completed at $(date) ==="

