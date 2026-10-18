#!/bin/bash
# User data script for the web/app EC2 instances in the ASG.
# Runs as root on first boot. Installs Python, pulls the app from S3
# (or installs inline for sandbox), starts it on port 80 via gunicorn.
# Logs go to /var/log/ha3tier-app.log and /var/log/cloud-init-output.log.

set -euo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "=== user data start $(date) ==="

APP_DIR="/opt/ha3tier"
S3_BUCKET="${app_s3_bucket:-}"   # set via Terraform; empty in sandbox mode
S3_KEY="${app_s3_key:-app/app.tar.gz}"
APP_PORT=80
REGION="${aws_region:-us-east-1}"
DB_SECRET_NAME="${db_secret_name:-ha3tier/db/master}"
DB_NAME="${db_name:-appdb}"

# Disable strict default yum behavior that can break on AL2023 minimal images
yum -y install --skip-broken shadow-utils >/dev/null 2>&1 || true

# 1. Install Python 3.11, pip, mysql client, amazon-cloudwatch-agent
dnf install -y python3.11 python3.11-pip mysql mariadb-connector-c unzip curl >/dev/null
pip3.11 install --upgrade pip >/dev/null

# 2. Create app directory and app user
mkdir -p "$APP_DIR"
id -u appuser >/dev/null 2>&1 || useradd -r -s /sbin/nologin appuser

# 3. Get app code
if [ -n "$S3_BUCKET" ]; then
  echo "Downloading app from s3://$S3_BUCKET/$S3_KEY"
  aws s3 cp "s3://$S3_BUCKET/$S3_KEY" /tmp/app.tar.gz
  tar -xzf /tmp/app.tar.gz -C "$APP_DIR"
else
  echo "No S3 bucket configured; assuming image has app baked in or using fallback"
fi

# 4. Install Python deps (idempotent)
cd "$APP_DIR" || true
if [ -f requirements.txt ]; then
  pip3.11 install -r requirements.txt
else
  pip3.11 install flask==3.0.3 PyMySQL==1.1.1 boto3==1.34.140 gunicorn==22.0.0
fi

# 5. Write environment file used by systemd
cat >/etc/ha3tier.env <<EOF
AWS_REGION=$REGION
DB_SECRET_NAME=$DB_SECRET_NAME
DB_NAME=$DB_NAME
EOF
chmod 600 /etc/ha3tier.env

# 6. systemd unit
cat >/etc/systemd/system/ha3tier.service <<'EOF'
[Unit]
Description=ha3tier Flask app
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=appuser
Group=appuser
EnvironmentFile=/etc/ha3tier.env
WorkingDirectory=/opt/ha3tier
ExecStart=/usr/bin/python3.11 -m gunicorn \
  --workers 2 --threads 4 --bind 0.0.0.0:80 \
  --access-logfile - --error-logfile - \
  app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 7. Set ownership
chown -R appuser:appuser "$APP_DIR"

# 8. Start the app
systemctl daemon-reload
systemctl enable ha3tier.service
systemctl restart ha3tier.service

# 9. Wait briefly and confirm
sleep 5
systemctl is-active --quiet ha3tier.service \
  && echo "ha3tier service active" \
  || echo "ha3tier service FAILED to start (check journalctl -u ha3tier)"

# 10. Configure CloudWatch Agent to push memory and disk metrics
cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF' 2>/dev/null || true
{
  "agent": { "metrics_collection_interval": 60, "run_as_user": "cwagent" },
  "metrics": {
    "namespace": "ha3tier/App",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "aggregation_dimensions": [["InstanceId"]],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "resources": ["/"], "measurement": ["used_percent"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/ha3tier-app.log", "log_group_name": "ha3tier/app" },
          { "file_path": "/var/log/user-data.log", "log_group_name": "ha3tier/user-data" }
        ]
      }
    }
  }
}
EOF

# Run the CloudWatch Agent if installed
if command -v amazon-cloudwatch-agent-ctl >/dev/null 2>&1; then
  amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json || true
fi

echo "=== user data end $(date) ==="
