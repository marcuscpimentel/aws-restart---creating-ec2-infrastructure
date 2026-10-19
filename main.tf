data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "web" {
  name_prefix = "${var.project_name}-web-"
  description = "HTTP opcional; sem acesso SSH"
  vpc_id      = local.vpc_id

  # A lista vazia também remove regras de entrada acrescentadas fora do Terraform.
  ingress = var.allow_http ? [{
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = [var.http_cidr]
    ipv6_cidr_blocks = []
    prefix_list_ids  = []
    security_groups  = []
    self             = false
  }] : []

  # O bootstrap precisa alcançar os repositórios de pacotes do Amazon Linux.
  egress {
    description = "Saida IPv4"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-web" }
}

resource "aws_instance" "web" {
  ami                         = var.ami_id != null ? var.ami_id : nonsensitive(data.aws_ssm_parameter.al2023[0].value)
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true
  disable_api_termination     = var.termination_protection
  monitoring                  = false
  user_data                   = file("${path.module}/scripts/user-data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "${var.project_name}-web" }

  # Evita iniciar o bootstrap antes da rota de saída estar associada à sub-rede.
  depends_on = [aws_route_table_association.public]

  lifecycle {
    # O parâmetro público muda com novos releases. O resize mantém a AMI original.
    ignore_changes = [ami]
  }
}
