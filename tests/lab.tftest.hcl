mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a"] }
  }

  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }

  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-0123456789abcdef0" }
  }
}

variables {
  aws_region             = "us-east-1"
  project_name           = "ec2-lab"
  existing_subnet_id     = null
  ami_id                 = null
  instance_type          = "t3.micro"
  root_volume_size       = 8
  allow_http             = false
  http_cidr              = "0.0.0.0/0"
  termination_protection = true
}

run "initial_state" {
  command = plan

  assert {
    condition     = length(aws_security_group.web.ingress) == 0
    error_message = "A primeira etapa deve bloquear todo o tráfego de entrada."
  }

  assert {
    condition     = aws_instance.web.instance_type == "t3.micro" && aws_instance.web.root_block_device[0].volume_size == 8
    error_message = "A configuração inicial deve ser t3.micro com EBS de 8 GiB."
  }

  assert {
    condition     = aws_instance.web.disable_api_termination
    error_message = "A instância deve iniciar com proteção contra término."
  }

  assert {
    condition     = aws_instance.web.metadata_options[0].http_tokens == "required" && aws_instance.web.root_block_device[0].encrypted
    error_message = "IMDSv2 e criptografia do disco são requisitos do projeto."
  }

  assert {
    condition     = aws_instance.web.root_block_device[0].delete_on_termination && !aws_instance.web.monitoring
    error_message = "O disco deve ser removido com a instância e o monitoramento deve ser básico."
  }

  assert {
    condition     = aws_instance.web.credit_specification[0].cpu_credits == "standard"
    error_message = "A instância não deve usar créditos excedentes do modo Unlimited."
  }

  assert {
    condition     = length(aws_vpc.lab) == 1 && length(aws_subnet.public) == 1 && length(aws_internet_gateway.lab) == 1
    error_message = "Sem uma sub-rede existente, o projeto deve criar sua própria rede."
  }

  assert {
    condition     = one(aws_route_table.public[0].route).cidr_block == "0.0.0.0/0" && aws_instance.web.associate_public_ip_address
    error_message = "A rede própria deve fornecer rota pública e IPv4 público à instância."
  }
}

run "http_enabled" {
  command = plan
  variables { allow_http = true }

  assert {
    condition = length(aws_security_group.web.ingress) == 1 && alltrue([
      for rule in aws_security_group.web.ingress :
      rule.from_port == 80 && rule.to_port == 80 && rule.protocol == "tcp" &&
      length(rule.cidr_blocks) == 1 && contains(rule.cidr_blocks, "0.0.0.0/0") && !rule.self &&
      length(rule.ipv6_cidr_blocks) == 0 && length(rule.security_groups) == 0
    ])
    error_message = "Somente HTTP público deve estar liberado; nenhuma regra SSH deve existir."
  }
}

run "http_restricted_to_client" {
  command = plan
  variables {
    allow_http = true
    http_cidr  = "203.0.113.10/32"
  }

  assert {
    condition     = length(one(aws_security_group.web.ingress).cidr_blocks) == 1 && contains(one(aws_security_group.web.ingress).cidr_blocks, "203.0.113.10/32")
    error_message = "A origem personalizada deve substituir o acesso público."
  }
}

run "resized_state" {
  command = plan
  variables {
    allow_http       = true
    instance_type    = "t3.small"
    root_volume_size = 10
  }

  assert {
    condition     = aws_instance.web.instance_type == "t3.small" && aws_instance.web.root_block_device[0].volume_size == 10
    error_message = "A etapa de resize deve usar t3.small e EBS de 10 GiB."
  }

  assert {
    condition     = aws_instance.web.disable_api_termination && length(aws_security_group.web.ingress) == 1
    error_message = "O resize deve preservar a proteção contra término e o HTTP."
  }
}

run "cleanup_ready" {
  command = plan
  variables {
    allow_http             = true
    instance_type          = "t3.small"
    root_volume_size       = 10
    termination_protection = false
  }

  assert {
    condition     = !aws_instance.web.disable_api_termination
    error_message = "A última etapa deve permitir o término da instância."
  }
}

run "reuse_existing_subnet" {
  command = plan
  variables { existing_subnet_id = "subnet-0123456789abcdef0" }

  assert {
    condition = (
      length(aws_vpc.lab) == 0 && length(aws_subnet.public) == 0 &&
      length(aws_internet_gateway.lab) == 0 && length(aws_route_table.public) == 0 &&
      length(aws_route_table_association.public) == 0 &&
      aws_instance.web.subnet_id == "subnet-0123456789abcdef0" &&
      aws_security_group.web.vpc_id == "vpc-0123456789abcdef0"
    )
    error_message = "Reutilizar uma sub-rede não deve criar nem gerenciar a rede existente."
  }
}

run "explicit_ami" {
  command = plan
  variables { ami_id = "ami-0fedcba9876543210" }

  assert {
    condition     = length(data.aws_ssm_parameter.al2023) == 0 && aws_instance.web.ami == "ami-0fedcba9876543210"
    error_message = "Uma AMI explícita deve dispensar a consulta ao parâmetro público."
  }
}

run "reject_other_instance_types" {
  command = plan
  variables { instance_type = "m5.large" }
  expect_failures = [var.instance_type]
}

run "reject_small_disk" {
  command = plan
  variables { root_volume_size = 7 }
  expect_failures = [var.root_volume_size]
}

run "reject_fractional_disk" {
  command = plan
  variables { root_volume_size = 8.5 }
  expect_failures = [var.root_volume_size]
}

run "reject_ipv6_http_source" {
  command = plan
  variables { http_cidr = "::/0" }
  expect_failures = [var.http_cidr]
}
