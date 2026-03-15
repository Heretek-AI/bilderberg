# RAGFlow Tarball Installation Guide

This guide explains how to build and install RAGFlow from a pre-built tarball archive.

## Overview

The tarball build process creates self-contained archives for RAGFlow that include:
- Pre-compiled Python virtual environment with all dependencies
- Pre-built frontend (web application)
- Required models and resources (HuggingFace models, NLTK data, Tika, etc.)
- Chrome/ChromeDriver for document processing
- Launch scripts for easy deployment

**This is a Docker-free installation method.** RAGFlow runs directly on your host system without containerization.

## Building the Tarball

### Prerequisites for Building

| Requirement | Version | Notes |
|-------------|---------|-------|
| Ubuntu | 24.04+ | Target platform |
| Python | 3.12 | Required for uv package manager |
| Node.js | 20.x | For frontend build |
| Rust | Stable | For C extensions |

**Note:** Docker is NOT required. The build process runs directly on the host system.

### Automated Build (GitHub Actions)

The repository includes a GitHub Actions workflow (`.github/workflows/build-ragflow-tarball.yml`) that automatically builds tarballs for both AMD64 and ARM64 architectures.

#### Triggering a Build

1. **Release Build**: Create a new release in GitHub - tarballs are automatically uploaded to the release
2. **Manual Build**: Use the "workflow_dispatch" trigger in GitHub Actions UI

#### Build Configuration Options

| Input | Description | Default |
|-------|-------------|---------|
| `use_china_mirrors` | Use China-accessible mirrors for downloads | `false` |

### Manual Build Process

If you need to build manually outside of GitHub Actions:

```bash
# 1. Clone the repository
git clone https://github.com/infiniflow/ragflow.git
cd ragflow

# 2. Install system dependencies
sudo apt-get update
sudo apt-get install -y \
  libglib2.0-0 libglx-mesa0 libgl1 \
  pkg-config libicu-dev libgdiplus \
  default-jdk \
  libatk-bridge2.0-0 \
  libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev \
  libjemalloc-dev \
  gnupg unzip curl wget git vim less \
  ghostscript pandoc texlive \
  fonts-freefont-ttf fonts-noto-cjk \
  postgresql-client \
  unixodbc-dev

# 3. Install NGINX
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu/ noble nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
sudo apt-get update
sudo apt-get install -y nginx

# 4. Install uv package manager
curl -LsSf https://github.com/astral-sh/uv/releases/download/0.9.16/uv-x86_64-unknown-linux-gnu.tar.gz | tar xz
sudo cp uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/

# 5. Download dependencies (models, Chrome, Tika, etc.)
python download_deps.py

# 6. Install Python dependencies
uv sync --python 3.12 --frozen

# 7. Build frontend
cd web
npm install
npm run build
cd ..

# 8. Create version file
git describe --tags --match=v* --first-parent --always > VERSION

# 9. Create tarball staging directory
mkdir -p staging/ragflow
cp -r web admin api conf deepdoc rag agent mcp common memory bin staging/ragflow/
cp -r .venv staging/ragflow/
cp pyproject.toml uv.lock VERSION staging/ragflow/
cp docker/service_conf.yaml.template staging/ragflow/conf/
cp docker/entrypoint.sh staging/ragflow/
chmod +x staging/ragflow/entrypoint.sh

# 10. Copy resources
cp -r huggingface.co staging/ragflow/
cp -r nltk_data staging/ragflow/
cp tika-server-standard-3.2.3.jar staging/ragflow/
cp cl100k_base.tiktoken staging/ragflow/

# 11. Create tarball
cd staging
tar -czvf ../ragflow-$(cat ../VERSION)-$(uname -m).tar.gz ragflow
```

## Installation from Tarball

### Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| MySQL | 8.0+ | Or MariaDB 10.5+ |
| MinIO | Latest | Object storage |
| Redis/Valkey | 7.x+ | Caching layer |
| Elasticsearch | 8.x | Optional, for search |
| NGINX | Latest | Reverse proxy |

**No Docker required!** All services can be installed directly on the host or accessed from remote servers.

### Step 1: Download and Extract

```bash
# Create installation directory
sudo mkdir -p /opt/ragflow
cd /opt/ragflow

# Download tarball (replace VERSION and ARCH)
wget https://github.com/your-org/ragflow/releases/download/vVERSION/ragflow-VERSION-ARCH.tar.gz

# Extract
sudo tar -xzvf ragflow-VERSION-ARCH.tar.gz
```

### Step 2: Set Up External Services

You can install these services directly on your host system OR use remote/managed services. Docker examples are provided for convenience only.

#### MySQL

**Option A: Install directly on host (recommended for production)**
```bash
# Ubuntu/Debian
sudo apt-get install mysql-server

# Create database and user
sudo mysql
CREATE USER 'ragflow'@'localhost' IDENTIFIED BY 'your-secure-password';
CREATE DATABASE ragflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ragflow.* TO 'ragflow'@'localhost';
FLUSH PRIVILEGES;
```

**Option B: Use remote/managed MySQL**
- AWS RDS, Google Cloud SQL, Azure Database for MySQL
- Self-hosted MySQL on another server

**Option C: Docker (development only)**
```bash
docker run -d --name mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=your-secure-password \
  -e MYSQL_DATABASE=ragflow \
  mysql:8.0
```

#### MinIO

**Option A: Install directly on host**
```bash
# Download MinIO binary
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio
sudo mv minio /usr/local/bin/

# Create data directory
sudo mkdir -p /var/lib/minio

# Start MinIO (create systemd service for production)
MINIO_ROOT_USER=ragflow MINIO_ROOT_PASSWORD=your-secure-password \
  minio server /var/lib/minio --console-address ":9001"
```

**Option B: Use remote/managed object storage**
- AWS S3 (with S3-compatible API)
- Google Cloud Storage
- Azure Blob Storage
- Self-hosted MinIO on another server

**Option C: Docker (development only)**
```bash
docker run -d --name minio -p 9000:9000 -p 9001:9001 \
  -v /var/lib/minio:/data \
  -e MINIO_ROOT_USER=ragflow \
  -e MINIO_ROOT_PASSWORD=your-secure-password \
  quay.io/minio/minio server /data --console-address ":9001"
```

#### Redis

**Option A: Install directly on host (recommended)**
```bash
# Ubuntu/Debian
sudo apt-get install redis-server

# Configure password
sudo sed -i 's/# requirepass foobared/requirepass your-secure-password/' /etc/redis/redis.conf
sudo sed -i 's/maxmemory.*/maxmemory 128mb/' /etc/redis/redis.conf
sudo sed -i 's/# maxmemory-policy.*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

# Restart Redis
sudo systemctl restart redis
```

**Option B: Use remote/managed Redis**
- AWS ElastiCache
- Google Cloud Memorystore
- Azure Cache for Redis
- Self-hosted Redis on another server

**Option C: Docker (development only)**
```bash
docker run -d --name redis -p 6379:6379 \
  valkey/valkey:8 \
  redis-server --requirepass your-secure-password --maxmemory 128mb --maxmemory-policy allkeys-lru
```

### Step 3: Configure Environment

Create an environment file:

```bash
cat > /opt/ragflow/.env << 'EOF'
# MySQL Configuration
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_USER=ragflow
MYSQL_PASSWORD=your-secure-password

# MinIO Configuration
MINIO_HOST=localhost
MINIO_PORT=9000
MINIO_USER=ragflow
MINIO_PASSWORD=your-secure-password

# Redis Configuration
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=your-secure-password

# Optional: Elasticsearch (if using)
ES_HOST=localhost
ES_PORT=9200
ES_PASSWORD=your-elastic-password

# Optional: HuggingFace mirror (China users)
# HF_ENDPOINT=https://hf-mirror.com
EOF
```

### Step 4: Configure RAGFlow

Edit the configuration file:

```bash
cp /opt/ragflow/conf/service_conf.yaml.template /opt/ragflow/conf/service_conf.yaml
vim /opt/ragflow/conf/service_conf.yaml
```

Update the following settings:

```yaml
# Database
mysql:
  host: ${MYSQL_HOST}
  port: ${MYSQL_PORT}
  user: ${MYSQL_USER}
  password: ${MYSQL_PASSWORD}
  database: ragflow

# Object Storage
minio:
  host: ${MINIO_HOST}
  port: ${MINIO_PORT}
  access_key: ${MINIO_USER}
  secret_key: ${MINIO_PASSWORD}

# Redis
redis:
  host: ${REDIS_HOST}
  port: ${REDIS_PORT}
  password: ${REDIS_PASSWORD}
```

### Step 5: Run RAGFlow

```bash
cd /opt/ragflow
source .env
./launch.sh
```

## Running as a Systemd Service

Create a systemd service file:

```bash
sudo cat > /etc/systemd/system/ragflow.service << 'EOF'
[Unit]
Description=RAGFlow Server
After=network.target mysql.service redis.service

[Service]
Type=simple
User=ragflow
WorkingDirectory=/opt/ragflow
EnvironmentFile=/opt/ragflow/.env
ExecStart=/opt/ragflow/launch.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable ragflow
sudo systemctl start ragflow
```

## Architecture Support

The build process supports two architectures:

| Architecture | Runner | Notes |
|-------------|--------|-------|
| AMD64 | `ubuntu-latest` | Standard x86_64 servers |
| ARM64 | `ubuntu-24.04-arm` | ARM servers, Raspberry Pi, AWS Graviton |

## Troubleshooting

### Database Connection Issues

```bash
# Test MySQL connection
mysql -h $MYSQL_HOST -P $MYSQL_PORT -u $MYSQL_USER -p$MYSQL_PASSWORD -e "SELECT 1"

# Check MySQL logs (if installed locally)
sudo journalctl -u mysql
```

### MinIO Connection Issues

```bash
# Test MinIO connection
curl -I http://$MINIO_HOST:$MINIO_PORT/minio/health/live

# Check MinIO logs (if installed locally)
sudo journalctl -u minio
```

### Redis Connection Issues

```bash
# Test Redis connection
redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD ping

# Check Redis logs (if installed locally)
sudo journalctl -u redis
```

### Chrome/ChromeDriver Issues

The tarball includes Chrome and ChromeDriver for document processing. If you encounter issues:

```bash
# Verify Chrome is accessible
ls -la /opt/ragflow/opt/chrome/

# Verify ChromeDriver
ls -la /opt/ragflow/usr/local/bin/chromedriver
```

### Memory Issues

RAGFlow uses jemalloc for memory management. If you see memory-related errors:

```bash
# Verify jemalloc is installed
pkg-config --variable=libdir jemalloc

# Check available memory
free -h
```

## Environment Variables Reference

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `MYSQL_HOST` | MySQL server host | `localhost` |
| `MYSQL_PORT` | MySQL server port | `3306` |
| `MYSQL_USER` | MySQL username | `ragflow` |
| `MYSQL_PASSWORD` | MySQL password | `secure-password` |
| `MINIO_HOST` | MinIO server host | `localhost` |
| `MINIO_PORT` | MinIO server port | `9000` |
| `MINIO_USER` | MinIO access key | `ragflow` |
| `MINIO_PASSWORD` | MinIO secret key | `secure-password` |
| `REDIS_HOST` | Redis server host | `localhost` |
| `REDIS_PORT` | Redis server port | `6379` |
| `REDIS_PASSWORD` | Redis password | `secure-password` |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TIKA_SERVER_JAR` | Path to Tika JAR | Bundled |
| `HF_ENDPOINT` | HuggingFace mirror | `https://huggingface.co` |
| `PYTHONPATH` | Python module path | `/opt/ragflow` |

## Why Tarball Instead of Docker?

| Aspect | Tarball Installation | Docker Installation |
|--------|---------------------|---------------------|
| Performance | Native performance | Slight overhead |
| Resource usage | Direct system access | Container isolation overhead |
| Deployment | Single tarball extraction | Multiple containers needed |
| Debugging | Direct access to processes | Container debugging required |
| Integration | Easy integration with host services | Network/port mapping needed |
| Updates | Replace tarball directory | Rebuild/restart containers |
| Best for | Production servers, bare metal | Development, testing, microservices |

## Additional Resources

- [RAGFlow Documentation](https://ragflow.io/docs/)
- [Launch from Source Guide](https://ragflow.io/docs/launch_ragflow_from_source)
- [GitHub Repository](https://github.com/infiniflow/ragflow)