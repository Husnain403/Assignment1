#!/bin/bash
# UniEvent EC2 user-data script
# Runs on first boot of each EC2 instance launched by the Auto Scaling Group.
# Installs Python + Flask, drops the app onto the box, and registers it as a
# systemd service so it survives reboots and crashes (Restart=always).

set -x

dnf install -y python3 python3-pip
pip3 install flask requests boto3

cat > /opt/app.py <<'PY'
__APP_PY_PLACEHOLDER__
PY

cat > /etc/systemd/system/unievent.service <<SVC
[Unit]
Description=UniEvent Flask Application
After=network.target

[Service]
Environment="TM_KEY=__TM_KEY__"
Environment="S3_BUCKET=__S3_BUCKET__"
ExecStart=/usr/bin/python3 /opt/app.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now unievent
sleep 3
systemctl status unievent --no-pager
curl -s http://localhost/health
