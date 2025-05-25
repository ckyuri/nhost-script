#!/bin/bash

# Nhost Self-Hosting Setup Script for Ubuntu
# Domain: https://nhost.kyuri.xyz

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="kyuri.xyz"
NHOST_SUBDOMAIN="nhost"
EMAIL="" # Will be prompted
POSTGRES_PASSWORD=""
GRAPHQL_ADMIN_SECRET=""
JWT_SECRET=""
STORAGE_ACCESS_KEY=""
STORAGE_SECRET_KEY=""
RUNNING_AS_ROOT=false

# Print colored output
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
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_warning "Running as root detected"
        print_warning "This script can run as root, but it's generally safer to run as a regular user"
        read -p "Do you want to continue as root? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Setup cancelled"
            exit 1
        fi
        RUNNING_AS_ROOT=true
    else
        RUNNING_AS_ROOT=false
    fi
}

# Collect user input
collect_input() {
    echo -e "${BLUE}=== Nhost Self-Hosting Setup ===${NC}"
    echo
    
    # Email for Let's Encrypt
    while [[ -z "$EMAIL" ]]; do
        read -p "Enter your email for Let's Encrypt certificates: " EMAIL
        if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            print_error "Invalid email format"
            EMAIL=""
        fi
    done
    
    echo
    print_warning "The script will set up Nhost with the following subdomains:"
    echo "  - https://auth.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  - https://dashboard.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  - https://graphql.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  - https://functions.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  - https://storage.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  - https://mailhog.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Setup cancelled"
        exit 1
    fi
}

# Generate secure passwords and keys
generate_secrets() {
    print_status "Generating secure passwords and keys..."
    
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    GRAPHQL_ADMIN_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    # Generate JWT secret
    JWT_KEY=$(openssl rand -hex 32)
    JWT_SECRET='{"type":"HS256", "key":"'$JWT_KEY'","issuer":"hasura-auth"}'
    
    STORAGE_ACCESS_KEY=$(openssl rand -base64 20 | tr -d "=+/" | cut -c1-16)
    STORAGE_SECRET_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    print_success "Secrets generated successfully"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if Git is installed
    if ! command -v git &> /dev/null; then
        print_status "Installing Git..."
        if [[ $RUNNING_AS_ROOT == true ]]; then
            apt update
            apt install -y git
        else
            sudo apt update
            sudo apt install -y git
        fi
    fi
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        print_status "Installing curl..."
        if [[ $RUNNING_AS_ROOT == true ]]; then
            apt install -y curl
        else
            sudo apt install -y curl
        fi
    fi
    
    # Check if openssl is installed
    if ! command -v openssl &> /dev/null; then
        print_status "Installing openssl..."
        if [[ $RUNNING_AS_ROOT == true ]]; then
            apt install -y openssl
        else
            sudo apt install -y openssl
        fi
    fi
    
    print_success "Prerequisites checked"
}

# Install Docker
install_docker() {
    if command -v docker &> /dev/null; then
        print_success "Docker is already installed"
        return
    fi
    
    print_status "Installing Docker..."
    
    # Remove old versions
    if [[ $RUNNING_AS_ROOT == true ]]; then
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Install dependencies
        apt-get update
        apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Install dependencies
        sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        # Add current user to docker group
        sudo usermod -aG docker $USER
        
        print_warning "You may need to log out and back in for Docker group changes to take effect"
    fi
    
    print_success "Docker installed successfully"
}

# Setup Nhost project
setup_nhost() {
    print_status "Setting up Nhost project..."
    
    # Clone repository if not exists
    if [[ ! -d "nhost" ]]; then
        git clone https://github.com/nhost/nhost.git
    fi
    
    cd nhost/examples/docker-compose
    
    # Create .env file
    print_status "Creating environment configuration..."
    
    cat > .env << EOF
# Generated by Nhost setup script
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAPHQL_ADMIN_SECRET=${GRAPHQL_ADMIN_SECRET}
JWT_SECRET=${JWT_SECRET}
STORAGE_ACCESS_KEY=${STORAGE_ACCESS_KEY}
STORAGE_SECRET_KEY=${STORAGE_SECRET_KEY}

# Domain configuration
AUTH_URL=auth.${NHOST_SUBDOMAIN}.${DOMAIN}
CONSOLE_URL=graphql.${NHOST_SUBDOMAIN}.${DOMAIN}
DASHBOARD_URL=dashboard.${NHOST_SUBDOMAIN}.${DOMAIN}
DB_URL=db.${NHOST_SUBDOMAIN}.${DOMAIN}
FUNCTIONS_URL=functions.${NHOST_SUBDOMAIN}.${DOMAIN}
GRAPHQL_URL=graphql.${NHOST_SUBDOMAIN}.${DOMAIN}
MAILHOG_URL=mailhog.${NHOST_SUBDOMAIN}.${DOMAIN}
STORAGE_URL=storage.${NHOST_SUBDOMAIN}.${DOMAIN}

# Production settings
AUTH_EMAIL_SIGNIN_EMAIL_VERIFIED_REQUIRED=true

# ACME Email for Let's Encrypt
ACME_EMAIL=${EMAIL}
EOF
    
    print_success "Environment configuration created"
}

# Create production docker-compose with SSL
create_production_compose() {
    print_status "Creating production Docker Compose configuration..."
    
    cat > docker-compose.prod.yaml << 'EOF'
services:
    traefik:
        image: traefik:v3.1
        command:
            - --api.insecure=false
            - --providers.docker=true
            - --providers.docker.exposedbydefault=false
            - --entrypoints.web.address=:80
            - --entrypoints.websecure.address=:443
            - --certificatesresolvers.myresolver.acme.tlschallenge=true
            - --certificatesresolvers.myresolver.acme.email=${ACME_EMAIL}
            - --certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json
            # Redirect HTTP to HTTPS
            - --entrypoints.web.http.redirections.entrypoint.to=websecure
            - --entrypoints.web.http.redirections.entrypoint.scheme=https
        ports:
            - "80:80"
            - "443:443"
        volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
            - ./letsencrypt:/letsencrypt
        restart: always

    postgres:
        image: postgres:16
        environment:
            POSTGRES_DB: postgres
            POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
            POSTGRES_USER: postgres
        healthcheck:
            test:
                - CMD-SHELL
                - pg_isready -U postgres -d postgres -q
            timeout: 60s
            interval: 5s
            start_period: 60s
        volumes:
            - pgdata:/var/lib/postgresql/data
            - ./initdb.d:/docker-entrypoint-initdb.d:ro
        restart: always

    graphql:
        image: nhost/graphql-engine:v2.36.9-ce
        depends_on:
            postgres:
                condition: service_healthy
        environment:
            HASURA_GRAPHQL_ADMIN_SECRET: ${GRAPHQL_ADMIN_SECRET}
            HASURA_GRAPHQL_DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
            HASURA_GRAPHQL_ENABLE_CONSOLE: "true"
            HASURA_GRAPHQL_DEV_MODE: "false"
            HASURA_GRAPHQL_CORS_DOMAIN: 'https://${DASHBOARD_URL}'
            HASURA_GRAPHQL_JWT_SECRET: ${JWT_SECRET}
            HASURA_GRAPHQL_UNAUTHORIZED_ROLE: public
            HASURA_GRAPHQL_ADMIN_INTERNAL_ERRORS: "false"
            HASURA_GRAPHQL_LOG_LEVEL: warn
        healthcheck:
            test:
                - CMD-SHELL
                - curl http://localhost:8080/healthz > /dev/null 2>&1
            timeout: 60s
            interval: 5s
            start_period: 60s
        labels:
            traefik.enable: "true"
            traefik.http.routers.graphql.rule: Host(`${GRAPHQL_URL}`)
            traefik.http.routers.graphql.entrypoints: websecure
            traefik.http.routers.graphql.tls.certresolver: myresolver
            traefik.http.services.graphql.loadbalancer.server.port: "8080"
        restart: always

    auth:
        image: nhost/hasura-auth:0.37.1
        depends_on:
            graphql:
                condition: service_healthy
            postgres:
                condition: service_healthy
        environment:
            AUTH_ACCESS_CONTROL_ALLOWED_REDIRECT_URLS: "https://${DASHBOARD_URL}"
            AUTH_CLIENT_URL: https://${DASHBOARD_URL}
            AUTH_SERVER_URL: https://${AUTH_URL}/v1
            AUTH_EMAIL_SIGNIN_EMAIL_VERIFIED_REQUIRED: "${AUTH_EMAIL_SIGNIN_EMAIL_VERIFIED_REQUIRED}"
            AUTH_PASSWORD_MIN_LENGTH: "12"
            AUTH_PASSWORD_HIBP_ENABLED: "true"
            AUTH_CONCEAL_ERRORS: "true"
            AUTH_HOST: 0.0.0.0
            AUTH_PORT: "4000"
            AUTH_JWT_CUSTOM_CLAIMS: '{}'
            AUTH_USER_DEFAULT_ROLE: user
            AUTH_USER_DEFAULT_ALLOWED_ROLES: user,me
            HASURA_GRAPHQL_ADMIN_SECRET: ${GRAPHQL_ADMIN_SECRET}
            HASURA_GRAPHQL_DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
            HASURA_GRAPHQL_GRAPHQL_URL: http://graphql:8080/v1/graphql
            HASURA_GRAPHQL_JWT_SECRET: ${JWT_SECRET}
            # SMTP Configuration - Update these for production
            AUTH_SMTP_HOST: mailhog
            AUTH_SMTP_PORT: "1025"
            AUTH_SMTP_USER: user
            AUTH_SMTP_PASS: password
            AUTH_SMTP_SENDER: noreply@${DOMAIN}
            AUTH_SMTP_SECURE: "false"
        healthcheck:
            test:
                - CMD
                - wget
                - --spider
                - -S
                - http://localhost:4000/healthz
            timeout: 60s
            interval: 5s
            start_period: 60s
        labels:
            traefik.enable: "true"
            traefik.http.routers.auth.rule: Host(`${AUTH_URL}`)
            traefik.http.routers.auth.entrypoints: websecure
            traefik.http.routers.auth.tls.certresolver: myresolver
            traefik.http.services.auth.loadbalancer.server.port: "4000"
        restart: always
        volumes:
            - ./nhost/emails:/app/email-templates:ro

    storage:
        image: nhost/hasura-storage:0.7.1
        depends_on:
            graphql:
                condition: service_healthy
            minio:
                condition: service_started
            postgres:
                condition: service_healthy
        command:
            - serve
        environment:
            BIND: :5000
            HASURA_ENDPOINT: http://graphql:8080/v1
            HASURA_GRAPHQL_ADMIN_SECRET: ${GRAPHQL_ADMIN_SECRET}
            HASURA_METADATA: "1"
            POSTGRES_MIGRATIONS: "1"
            POSTGRES_MIGRATIONS_SOURCE: postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres?sslmode=disable
            PUBLIC_URL: https://${STORAGE_URL}
            S3_ACCESS_KEY: ${STORAGE_ACCESS_KEY}
            S3_BUCKET: nhost
            S3_ENDPOINT: http://minio:9000
            S3_REGION: ""
            S3_ROOT_FOLDER: ""
            S3_SECRET_KEY: ${STORAGE_SECRET_KEY}
        labels:
            traefik.enable: "true"
            traefik.http.routers.storage.rule: Host(`${STORAGE_URL}`) && PathPrefix(`/v1`)
            traefik.http.routers.storage.entrypoints: websecure
            traefik.http.routers.storage.tls.certresolver: myresolver
            traefik.http.services.storage.loadbalancer.server.port: "5000"
        restart: always

    functions:
        image: nhost/functions:22-1.4.0
        environment:
            HASURA_GRAPHQL_ADMIN_SECRET: ${GRAPHQL_ADMIN_SECRET}
            HASURA_GRAPHQL_DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/postgres
            HASURA_GRAPHQL_GRAPHQL_URL: http://graphql:8080/v1/graphql
            HASURA_GRAPHQL_JWT_SECRET: ${JWT_SECRET}
        healthcheck:
            test:
                - CMD
                - wget
                - --spider
                - -S
                - http://localhost:3000/healthz
            timeout: 600s
            interval: 5s
            start_period: 600s
        labels:
            traefik.enable: "true"
            traefik.http.middlewares.functions-strip.stripprefix.prefixes: /v1
            traefik.http.routers.functions.rule: Host(`${FUNCTIONS_URL}`) && PathPrefix(`/v1`)
            traefik.http.routers.functions.middlewares: functions-strip
            traefik.http.routers.functions.entrypoints: websecure
            traefik.http.routers.functions.tls.certresolver: myresolver
            traefik.http.services.functions.loadbalancer.server.port: "3000"
        restart: always
        volumes:
            - ./functions:/opt/project/functions:ro
            - functions_node_modules:/opt/project/functions/node_modules

    dashboard:
        image: nhost/dashboard:2.20.0
        environment:
            NEXT_PUBLIC_NHOST_ADMIN_SECRET: ${GRAPHQL_ADMIN_SECRET}
            NEXT_PUBLIC_NHOST_AUTH_URL: https://${AUTH_URL}/v1
            NEXT_PUBLIC_NHOST_FUNCTIONS_URL: https://${FUNCTIONS_URL}/v1
            NEXT_PUBLIC_NHOST_GRAPHQL_URL: https://${GRAPHQL_URL}/v1/graphql
            NEXT_PUBLIC_NHOST_HASURA_API_URL: https://${GRAPHQL_URL}
            NEXT_PUBLIC_NHOST_HASURA_CONSOLE_URL: https://${GRAPHQL_URL}/console
            NEXT_PUBLIC_NHOST_HASURA_MIGRATIONS_API_URL: https://${GRAPHQL_URL}
            NEXT_PUBLIC_NHOST_STORAGE_URL: https://${STORAGE_URL}/v1
            NEXT_PUBLIC_NHOST_PLATFORM: "false"
        labels:
            traefik.enable: "true"
            traefik.http.routers.dashboard.rule: Host(`${DASHBOARD_URL}`)
            traefik.http.routers.dashboard.entrypoints: websecure
            traefik.http.routers.dashboard.tls.certresolver: myresolver
            traefik.http.services.dashboard.loadbalancer.server.port: "3000"
        restart: always

    minio:
        image: minio/minio:RELEASE.2025-02-28T09-55-16Z
        entrypoint:
            - /bin/sh
        command:
            - -c
            - mkdir -p /data/nhost && /usr/bin/minio server --address :9000 /data
        environment:
            MINIO_ROOT_USER: ${STORAGE_ACCESS_KEY}
            MINIO_ROOT_PASSWORD: ${STORAGE_SECRET_KEY}
        restart: always
        volumes:
            - minio_data:/data

    mailhog:
        image: jcalonso/mailhog:v1.0.1
        labels:
            traefik.enable: "true"
            traefik.http.routers.mailhog.rule: Host(`${MAILHOG_URL}`)
            traefik.http.routers.mailhog.entrypoints: websecure
            traefik.http.routers.mailhog.tls.certresolver: myresolver
            traefik.http.services.mailhog.loadbalancer.server.port: "8025"
        restart: always
        volumes:
            - mailhog_data:/maildir

volumes:
    pgdata:
    minio_data:
    mailhog_data:
    functions_node_modules:
EOF
    
    print_success "Production Docker Compose configuration created"
}

# Check DNS configuration
check_dns() {
    print_status "Checking DNS configuration..."
    
    subdomains=("auth" "dashboard" "graphql" "functions" "storage" "mailhog")
    
    for subdomain in "${subdomains[@]}"; do
        hostname="${subdomain}.${NHOST_SUBDOMAIN}.${DOMAIN}"
        print_status "Checking DNS for ${hostname}..."
        
        if nslookup ${hostname} >/dev/null 2>&1; then
            print_success "DNS resolved for ${hostname}"
        else
            print_warning "DNS not resolved for ${hostname}"
            print_warning "Please ensure you have set up the following DNS A records:"
            for sub in "${subdomains[@]}"; do
                echo "  ${sub}.${NHOST_SUBDOMAIN}.${DOMAIN} → YOUR_SERVER_IP"
            done
            echo
            read -p "Press Enter when DNS records are configured..."
        fi
    done
}

# Create necessary directories and files
setup_directories() {
    print_status "Setting up directories and files..."
    
    # Create Let's Encrypt directory
    mkdir -p letsencrypt
    
    # Create initdb directory if it doesn't exist
    if [[ ! -d "initdb.d" ]]; then
        mkdir -p initdb.d
        cat > initdb.d/0001-create-schema.sql << 'EOF'
-- auth schema
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
-- https://github.com/hasura/graphql-engine/issues/3657
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
CREATE OR REPLACE FUNCTION public.set_current_timestamp_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
declare _new record;
begin _new := new;
_new."updated_at" = now();
return _new;
end;
$$;
EOF
    fi
    
    # Create functions directory with sample function
    if [[ ! -d "functions" ]]; then
        mkdir -p functions
        cat > functions/hello.js << 'EOF'
export default (req, res) => {
  res.status(200).send(`Hello, ${req.query.name || 'World'}!`)
}
EOF
    fi
    
    print_success "Directories and files set up"
}

# Start services
start_services() {
    print_status "Starting Nhost services..."
    
    # Start services
    docker compose -f docker-compose.prod.yaml up -d
    
    print_success "Services started successfully!"
    
    echo
    print_success "=== Setup Complete! ==="
    echo
    print_status "Your Nhost instance is now running at:"
    echo "  Dashboard: https://dashboard.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  GraphQL:   https://graphql.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  Auth:      https://auth.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  Storage:   https://storage.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  Functions: https://functions.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo "  Mailhog:   https://mailhog.${NHOST_SUBDOMAIN}.${DOMAIN}"
    echo
    print_status "Admin credentials:"
    echo "  GraphQL Admin Secret: ${GRAPHQL_ADMIN_SECRET}"
    echo "  Postgres Password:    ${POSTGRES_PASSWORD}"
    echo
    print_warning "Important:"
    echo "  1. Save these credentials securely"
    echo "  2. Configure your SMTP settings in production"
    echo "  3. Remove Mailhog in production environments"
    echo "  4. Set up regular database backups"
    echo
    print_status "Logs: docker compose -f docker-compose.prod.yaml logs -f"
    print_status "Stop:  docker compose -f docker-compose.prod.yaml down"
}

# Save configuration
save_config() {
    print_status "Saving configuration..."
    
    cat > nhost-config.txt << EOF
# Nhost Configuration
# Generated on $(date)

Domain: ${DOMAIN}
Nhost Subdomain: ${NHOST_SUBDOMAIN}
Email: ${EMAIL}

# Credentials (KEEP SECURE!)
Postgres Password: ${POSTGRES_PASSWORD}
GraphQL Admin Secret: ${GRAPHQL_ADMIN_SECRET}
Storage Access Key: ${STORAGE_ACCESS_KEY}
Storage Secret Key: ${STORAGE_SECRET_KEY}

# URLs
Dashboard: https://dashboard.${NHOST_SUBDOMAIN}.${DOMAIN}
GraphQL: https://graphql.${NHOST_SUBDOMAIN}.${DOMAIN}
Auth: https://auth.${NHOST_SUBDOMAIN}.${DOMAIN}
Storage: https://storage.${NHOST_SUBDOMAIN}.${DOMAIN}
Functions: https://functions.${NHOST_SUBDOMAIN}.${DOMAIN}
Mailhog: https://mailhog.${NHOST_SUBDOMAIN}.${DOMAIN}

# Commands
Start: docker compose -f docker-compose.prod.yaml up -d
Stop: docker compose -f docker-compose.prod.yaml down
Restart: docker compose -f docker-compose.prod.yaml restart
Logs: docker compose -f docker-compose.prod.yaml logs -f
Update: docker compose -f docker-compose.prod.yaml pull && docker compose -f docker-compose.prod.yaml up -d
EOF
    
    chmod 600 nhost-config.txt
    print_success "Configuration saved to nhost-config.txt"
}

# Main execution
main() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════╗"
    echo "║        Nhost Self-Hosting Setup      ║"
    echo "║          Domain: ${DOMAIN}         ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    collect_input
    generate_secrets
    check_prerequisites
    install_docker
    setup_nhost
    create_production_compose
    setup_directories
    check_dns
    start_services
    save_config
    
    print_success "Setup completed successfully!"
}

# Run main function
main "$@"
