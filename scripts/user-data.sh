#!/usr/bin/env bash
set -euo pipefail

dnf install -y httpd

cat > /var/www/html/index.html <<'HTML'
<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>EC2 Lab</title>
  </head>
  <body>
    <h1>Servidor EC2 em funcionamento</h1>
    <p id="lab-marker">ec2-lab-ready</p>
    <p>Amazon Linux 2023, Apache e Terraform.</p>
  </body>
</html>
HTML

chmod 0644 /var/www/html/index.html
systemctl enable --now httpd
