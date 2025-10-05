#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TRAEFIK_DIR="/opt/traefik"
CONFIG_DIR="/etc/traefik"
DOCKER_NETWORK="traefik"
TEST_CONTAINER_NAME="traefik-test-page"
TEST_DURATION=600  # 10 minutes in seconds

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root or with sudo"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    print_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Function to get user input
get_user_input() {
    print_status "Traefik Setup Configuration"
    echo "=================================="
    
    read -p "Enter your email for Let's Encrypt (optional): " email
    read -p "Enter test domain/subdomain (optional, e.g., test.yourdomain.com): " test_domain
    
    if [ -n "$test_domain" ]; then
        read -p "Test page will auto-remove after 10 minutes. Continue? (y/n): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            print_status "Setup cancelled."
            exit 0
        fi
    fi
}

# Function to create directories
create_directories() {
    print_status "Creating directories..."
    
    mkdir -p "$TRAEFIK_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR/certs"
    
    print_success "Directories created"
}

# Function to create Traefik configuration
create_traefik_config() {
    print_status "Creating Traefik configuration..."
    
    cat > "$CONFIG_DIR/traefik.yml" << EOF
# Traefik Global Configuration
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${email:-"admin@example.com"}
      storage: /etc/traefik/certs/acme.json
      httpChallenge:
        entryPoint: web
EOF

    print_success "Traefik configuration created"
}

# Function to create Docker Compose file for Traefik only
create_traefik_compose() {
    print_status "Creating Traefik Docker Compose configuration..."
    
    cat > "$TRAEFIK_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    networks:
      - traefik
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $CONFIG_DIR/traefik.yml:/etc/traefik/traefik.yml:ro
      - $CONFIG_DIR/certs:/etc/traefik/certs
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`traefik.\${TEST_DOMAIN:-localhost}\`)"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"

networks:
  traefik:
    external: true
    name: $DOCKER_NETWORK
EOF

    print_success "Docker Compose configuration created"
}

# Function to create test page Docker Compose
create_test_compose() {
    if [ -n "$test_domain" ]; then
        print_status "Creating test page configuration..."
        
        cat > "$TRAEFIK_DIR/docker-compose-test.yml" << EOF
version: '3.8'

services:
  test-page:
    image: softsweb/traefik-test-page:latest
    container_name: $TEST_CONTAINER_NAME
    restart: no
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.test-page.rule=Host(\`$test_domain\`)"
      - "traefik.http.routers.test-page.entrypoints=websecure"
      - "traefik.http.routers.test-page.tls.certresolver=letsencrypt"

networks:
  traefik:
    external: true
    name: $DOCKER_NETWORK
EOF
        print_success "Test page configuration created"
    fi
}

# Function to create environment file
create_env_file() {
    if [ -n "$test_domain" ]; then
        print_status "Creating environment file..."
        echo "TEST_DOMAIN=$test_domain" > "$TRAEFIK_DIR/.env"
        print_success "Environment file created"
    fi
}

# Function to setup Docker network
setup_docker_network() {
    print_status "Setting up Docker network..."
    
    if ! docker network ls | grep -q "$DOCKER_NETWORK"; then
        docker network create "$DOCKER_NETWORK"
        print_success "Docker network '$DOCKER_NETWORK' created"
    else
        print_warning "Docker network '$DOCKER_NETWORK' already exists"
    fi
}

# Function to deploy Traefik
deploy_traefik() {
    print_status "Deploying Traefik..."
    
    cd "$TRAEFIK_DIR"
    
    # Use docker-compose or docker compose based on availability
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD="docker compose"
    fi
    
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d
    
    print_success "Traefik deployed successfully"
}

# Function to deploy and auto-remove test page
deploy_test_page() {
    if [ -n "$test_domain" ]; then
        print_status "Deploying test page (will auto-remove in 10 minutes)..."
        
        cd "$TRAEFIK_DIR"
        
        if command -v docker-compose &> /dev/null; then
            docker-compose -f docker-compose-test.yml up -d
        else
            docker compose -f docker-compose-test.yml up -d
        fi
        
        print_success "Test page deployed at https://$test_domain"
        
        # Schedule automatic removal
        nohup bash -c "
        sleep $TEST_DURATION
        echo ''
        echo '⏰ Time is up! Removing test page...'
        if command -v docker-compose &> /dev/null; then
            docker-compose -f $TRAEFIK_DIR/docker-compose-test.yml down
        else
            docker compose -f $TRAEFIK_DIR/docker-compose-test.yml down
        fi
        rm -f $TRAEFIK_DIR/docker-compose-test.yml
        echo '✅ Test page removed successfully'
        " > /dev/null 2>&1 &
        
        # Store the PID for the cleanup process
        echo $! > "$TRAEFIK_DIR/test-cleanup.pid"
        
        # Show countdown message
        print_warning "Test page will auto-remove in 10 minutes (at $(date -d "+10 minutes" "+%H:%M:%S"))"
    fi
}

# Function to display final information
display_final_info() {
    print_success "Traefik setup completed!"
    echo ""
    echo "Summary:"
    echo "--------"
    echo "• Traefik configuration: $CONFIG_DIR/"
    echo "• Docker Compose files: $TRAEFIK_DIR/"
    echo "• Docker network: $DOCKER_NETWORK"
    echo ""
    
    if [ -n "$test_domain" ]; then
        echo "🎉 Your test page is available at:"
        echo "  • https://$test_domain"
        echo ""
        echo "⏰ Test page will auto-remove at: $(date -d "+10 minutes" "+%H:%M:%S")"
        echo ""
        echo "🔧 Traefik dashboard:"
        echo "  • https://traefik.$test_domain"
    else
        echo "No test domain provided - only Traefik is running."
        echo "You can add services by:"
        echo "1. Adding them to the 'traefik' network"
        echo "2. Setting appropriate Traefik labels"
    fi
    
    echo ""
    echo "To manage Traefik:"
    echo "  cd $TRAEFIK_DIR && docker-compose [logs|restart|down]"
    echo ""
    echo "To manually remove test page early:"
    if [ -n "$test_domain" ]; then
        echo "  cd $TRAEFIK_DIR && docker-compose -f docker-compose-test.yml down"
    fi
}

# Function to cleanup on script exit
cleanup() {
    if [ -f "$TRAEFIK_DIR/test-cleanup.pid" ]; then
        kill $(cat "$TRAEFIK_DIR/test-cleanup.pid") 2>/dev/null || true
        rm -f "$TRAEFIK_DIR/test-cleanup.pid"
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# Main execution
main() {
    print_status "Starting Traefik automated setup..."
    
    get_user_input
    create_directories
    create_traefik_config
    create_traefik_compose
    create_test_compose
    create_env_file
    setup_docker_network
    deploy_traefik
    deploy_test_page
    display_final_info
    
    print_success "Setup complete! 🎉"
}

# Run main function
main "$@"