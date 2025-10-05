#!/usr/bin/env python3

import os
import sys
import subprocess
import time
from pathlib import Path

# Colors for output
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'

def print_status(message):
    print(f"{Colors.BLUE}[INFO]{Colors.NC} {message}")

def print_success(message):
    print(f"{Colors.GREEN}[SUCCESS]{Colors.NC} {message}")

def print_warning(message):
    print(f"{Colors.YELLOW}[WARNING]{Colors.NC} {message}")

def print_error(message):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {message}")

def run_command(cmd, shell=False):
    """Run a command and return success status"""
    try:
        if shell:
            result = subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        else:
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as e:
        print_error(f"Command failed: {e}")
        return False

def check_docker():
    """Check if Docker is installed and running"""
    print_status("Checking Docker installation...")
    if not run_command(["docker", "--version"]):
        print_error("Docker is not installed. Please install Docker first.")
        sys.exit(1)
    
    if not run_command(["docker", "info"]):
        print_error("Docker daemon is not running. Please start Docker first.")
        sys.exit(1)
    
    print_success("Docker is installed and running")

def get_user_input():
    """Get user input interactively"""
    print_status("Traefik Setup Configuration")
    print("==================================")
    
    email = input("Enter your email for Let's Encrypt (optional): ").strip()
    test_domain = input("Enter test domain/subdomain (optional, e.g., test.yourdomain.com): ").strip()
    
    if test_domain:
        confirm = input("Test page will auto-remove after 10 minutes. Continue? (y/n): ").strip().lower()
        if confirm not in ['y', 'yes']:
            print_status("Setup cancelled.")
            sys.exit(0)
    
    return email, test_domain

def check_dns_resolution(domain):
    """Check if domain resolves to this server"""
    print_status(f"Checking DNS resolution for {domain}...")
    
    try:
        # Get server's public IP using external service
        result = subprocess.run(["curl", "-4s", "https://api.ipify.org"], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            server_ip = result.stdout.strip()
            print_warning(f"⚠️  Make sure {domain} DNS A record points to: {server_ip}")
            print_warning("If DNS is not configured, the test page won't be accessible")
            
            # Quick DNS check
            dns_check = subprocess.run(["nslookup", domain], capture_output=True, text=True)
            if dns_check.returncode != 0:
                print_warning(f"❌ DNS lookup failed for {domain}")
            else:
                print_success(f"✅ DNS lookup successful for {domain}")
                
    except Exception as e:
        print_warning(f"Could not determine server IP. Please ensure {domain} points to your server.")

def create_directories():
    """Create necessary directories"""
    directories = [
        "/opt/traefik",
        "/etc/traefik",
        "/etc/traefik/certs"
    ]
    
    for directory in directories:
        Path(directory).mkdir(parents=True, exist_ok=True)
    
    print_success("Directories created")

def create_traefik_config(email):
    """Create Traefik configuration file"""
    config_content = f"""# Traefik Global Configuration
api:
  dashboard: false

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
      email: {email or "admin@example.com"}
      storage: /etc/traefik/certs/acme.json
      httpChallenge:
        entryPoint: web
"""
    
    with open("/etc/traefik/traefik.yml", "w") as f:
        f.write(config_content)
    
    print_success("Traefik configuration created")

def create_traefik_compose():
    """Create Docker Compose file for Traefik"""
    compose_content = """version: '3.8'

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
      - /etc/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik/certs:/etc/traefik/certs

networks:
  traefik:
    external: true
    name: traefik
"""
    
    with open("/opt/traefik/docker-compose.yml", "w") as f:
        f.write(compose_content)
    
    print_success("Docker Compose configuration created")

def create_test_compose(test_domain):
    """Create test page Docker Compose file"""
    if not test_domain:
        return
    
    compose_content = f"""version: '3.8'

services:
  test-page:
    image: softsweb/traefik-test-page:latest
    container_name: traefik-test-page
    restart: no
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.test-page.rule=Host(`{test_domain}`)"
      - "traefik.http.routers.test-page.entrypoints=websecure"
      - "traefik.http.routers.test-page.tls.certresolver=letsencrypt"

networks:
  traefik:
    external: true
    name: traefik
"""
    
    with open("/opt/traefik/docker-compose-test.yml", "w") as f:
        f.write(compose_content)
    
    print_success("Test page configuration created")

def setup_docker_network():
    """Create Docker network if it doesn't exist"""
    print_status("Setting up Docker network...")
    
    result = subprocess.run(["docker", "network", "ls", "--format", "{{.Name}}"], 
                          capture_output=True, text=True)
    
    if "traefik" not in result.stdout:
        if run_command(["docker", "network", "create", "traefik"]):
            print_success("Docker network 'traefik' created")
    else:
        print_warning("Docker network 'traefik' already exists")

def deploy_traefik():
    """Deploy Traefik"""
    print_status("Deploying Traefik...")
    
    os.chdir("/opt/traefik")
    
    # Start services
    if run_command("docker compose up -d", shell=True):
        print_success("Traefik deployed successfully")

def deploy_test_page(test_domain):
    """Deploy test page and schedule auto-removal"""
    if not test_domain:
        return
    
    print_status("Deploying test page (will auto-remove in 10 minutes)...")
    
    os.chdir("/opt/traefik")
    
    if run_command("docker compose -f docker-compose-test.yml up -d", shell=True):
        print_success(f"Test page deployed at https://{test_domain}")
        
        # Schedule auto-removal
        removal_script = f"""#!/bin/bash
sleep 600
echo ""
echo "⏰ Time is up! Removing test page..."
docker compose -f /opt/traefik/docker-compose-test.yml down
rm -f /opt/traefik/docker-compose-test.yml
echo "✅ Test page removed successfully"
"""
        
        with open("/tmp/remove_test_page.sh", "w") as f:
            f.write(removal_script)
        
        run_command("chmod +x /tmp/remove_test_page.sh", shell=True)
        run_command("nohup /tmp/remove_test_page.sh > /dev/null 2>&1 &", shell=True)
        
        removal_time = time.strftime("%H:%M:%S", time.localtime(time.time() + 600))
        print_warning(f"Test page will auto-remove in 10 minutes (at {removal_time})")

def display_final_info(test_domain):
    """Display final setup information"""
    print_success("Traefik setup completed!")
    print("")
    print("Summary:")
    print("--------")
    print("• Traefik configuration: /etc/traefik/")
    print("• Docker Compose files: /opt/traefik/")
    print("• Docker network: traefik")
    print("")
    
    if test_domain:
        print("🎉 Your test page is available at:")
        print(f"  • https://{test_domain}")
        print("")
        print("⏰ Test page will auto-remove in 10 minutes")
    else:
        print("No test domain provided - only Traefik is running.")
        print("You can add services by:")
        print("1. Adding them to the 'traefik' network")
        print("2. Setting appropriate Traefik labels")
    
    print("")
    print("To manage Traefik:")
    print("  cd /opt/traefik && docker compose [logs|restart|down]")
    print("")
    
    if test_domain:
        print("To manually remove test page early:")
        print("  cd /opt/traefik && docker compose -f docker-compose-test.yml down")

def main():
    """Main setup function"""
    print_status("Starting Traefik automated setup...")
    
    # Check prerequisites
    check_docker()
    
    # Get user input
    email, test_domain = get_user_input()
    
    # Check DNS if domain provided
    if test_domain:
        check_dns_resolution(test_domain)
    
    # Setup
    create_directories()
    create_traefik_config(email)
    create_traefik_compose()
    create_test_compose(test_domain)
    setup_docker_network()
    
    # Deploy
    deploy_traefik()
    deploy_test_page(test_domain)
    
    # Final info
    display_final_info(test_domain)
    print_success("Setup complete! 🎉")

if __name__ == "__main__":
    main()