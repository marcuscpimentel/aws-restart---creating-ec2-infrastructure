variable "aws_region" {
  description = "Região onde o laboratório será criado."
  type        = string
  default     = "us-east-1"
  nullable    = false
}

variable "project_name" {
  description = "Prefixo dos nomes e das tags dos recursos."
  type        = string
  default     = "ec2-lab"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,31}$", var.project_name))
    error_message = "Use de 3 a 32 caracteres: letras minúsculas, números e hífen; comece com uma letra."
  }
}

variable "existing_subnet_id" {
  description = "Sub-rede pública já existente. null cria uma VPC e uma sub-rede próprias."
  type        = string
  default     = null

  validation {
    condition     = var.existing_subnet_id == null ? true : can(regex("^subnet-[0-9a-f]+$", var.existing_subnet_id))
    error_message = "Informe um ID de sub-rede válido ou null."
  }
}

variable "ami_id" {
  description = "AMI Amazon Linux 2023 x86_64 opcional. null consulta o parâmetro público da AWS."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null ? true : can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "Informe um ID de AMI válido ou null."
  }
}

variable "instance_type" {
  description = "Tipo da instância nas duas etapas do laboratório."
  type        = string
  default     = "t3.micro"
  nullable    = false

  validation {
    condition     = contains(["t3.micro", "t3.small"], var.instance_type)
    error_message = "Este laboratório usa t3.micro ou t3.small."
  }
}

variable "root_volume_size" {
  description = "Tamanho do EBS em GiB. Começa em 8; a etapa de resize usa 10."
  type        = number
  default     = 8
  nullable    = false

  validation {
    condition     = var.root_volume_size >= 8 && var.root_volume_size <= 32 && floor(var.root_volume_size) == var.root_volume_size
    error_message = "Use um tamanho inteiro entre 8 e 32 GiB. EBS não permite reduzir um volume existente."
  }
}

variable "allow_http" {
  description = "Libera a porta TCP 80. false mantém o Security Group sem regras de entrada."
  type        = bool
  default     = false
  nullable    = false
}

variable "http_cidr" {
  description = "Origem IPv4 do HTTP. O padrão reproduz o acesso público do laboratório."
  type        = string
  default     = "0.0.0.0/0"
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.http_cidr))
    error_message = "Use um CIDR IPv4 válido, como 0.0.0.0/0 ou seu IP público com /32."
  }
}

variable "termination_protection" {
  description = "Proteção contra término pela API do EC2. Desative antes de destruir o laboratório."
  type        = bool
  default     = true
  nullable    = false
}
