# Tarball Installation Guide

This guide explains how to install and run Drop using the pre-built tarball archives.

## Prerequisites

Before installing Drop from a tarball, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| Node.js | 22.x or later | Required for running the application |
| PostgreSQL | 14.x or later | Database backend |
| NGINX | Any recent version | Reverse proxy (must be on system PATH) |

## Download

Download the appropriate tarball for your architecture from the [GitHub Releases](https://github.com/Drop-OSS/drop/releases) page:

- `drop-{version}-amd64.tar.gz` - For x86_64/AMD64 systems (most servers)
- `drop-{version}-arm64.tar.gz` - For ARM64 systems (Raspberry Pi, AWS Graviton, etc.)

## Installation

### 1. Extract the Tarball

```bash
# Create installation directory
sudo mkdir -p /opt/drop
cd /opt/drop

# Extract the tarball
sudo tar -xzvf /path/to/drop-{version}-{arch}.tar.gz
```

### 2. Set Up PostgreSQL

Create a database and user for Drop:

```bash
# Connect to PostgreSQL
sudo -u postgres psql

# Create user and database
CREATE USER drop WITH PASSWORD 'your-secure-password';
CREATE DATABASE drop OWNER drop;
\q
```

### 3. Create Required Directories

```bash
sudo mkdir -p /var/lib/drop/data
sudo mkdir -p /var/lib/drop/library
sudo chown -R $USER:$USER /var/lib/drop
```

### 4. Configure Environment

Create an environment file or export variables:

```bash
# Create .env file
cat > /opt/drop/.env << 'EOF'
DATABASE_URL=postgres://drop:your-secure-password@localhost:5432/drop
DATA=/var/lib/drop/data
LIBRARY=/var/lib/drop/library
EXTERNAL_URL=http://your-server:3000
EOF
```

Or export directly:

```bash
export DATABASE_URL="postgres://drop:your-secure-password@localhost:5432/drop"
export DATA="/var/lib/drop/data"
export LIBRARY="/var/lib/drop/library"
export EXTERNAL_URL="http://your-server:3000"
```

### 5. Run Drop

```bash
cd /opt/drop
./launch.sh
```

## Environment Variables Reference

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | `postgres://drop:pass@localhost:5432/drop` |
| `DATA` | Directory for Drop data storage | `/var/lib/drop/data` |
| `LIBRARY` | Directory containing game library | `/var/lib/drop/library` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `EXTERNAL_URL` | External URL for the server | `http://localhost:3000` |
| `NGINX_CONFIG` | Path to nginx.conf | `./nginx.conf` |
| `PORT` | Internal application port | `4000` |
| `TORRENTIAL_PATH` | Custom path to torrential binary | (uses bundled binary) |
| `READER_THREADS` | Number of import threads | (auto-detected) |

## Running as a Service

### systemd Example

Create a systemd service file:

```bash
sudo cat > /etc/systemd/system/drop.service << 'EOF'
[Unit]
Description=Drop Game Library Server
After=network.target postgresql.service

[Service]
Type=simple
User=drop
WorkingDirectory=/opt/drop
EnvironmentFile=/opt/drop/.env
ExecStart=/opt/drop/launch.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable drop
sudo systemctl start drop
```

## Troubleshooting

### Database Connection Issues

Ensure PostgreSQL is running and accessible:

```bash
# Check PostgreSQL status
sudo systemctl status postgresql

# Test connection
psql "$DATABASE_URL" -c "SELECT 1"
```

### NGINX Not Found

Ensure NGINX is installed and on the PATH:

```bash
# Install NGINX
sudo apt-get install nginx

# Verify installation
which nginx
```

### Permission Issues

Ensure the user running Drop has access to all required directories:

```bash
# Fix permissions
sudo chown -R drop:drop /opt/drop
sudo chown -R drop:drop /var/lib/drop
```

## Next Steps

After installation, refer to the following guides:

- [Creating a Library](https://docs-next.droposs.org/admin/guides/creating-library/)
- [Importing a Game](https://docs-next.droposs.org/admin/guides/import-game/)
- [Exposing Your Instance](https://docs-next.droposs.org/admin/guides/exposing/)