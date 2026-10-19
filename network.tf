locals {
  create_network = var.existing_subnet_id == null
  subnet_id      = local.create_network ? aws_subnet.public[0].id : data.aws_subnet.existing[0].id
  vpc_id         = local.create_network ? aws_vpc.lab[0].id : data.aws_subnet.existing[0].vpc_id
}

data "aws_availability_zones" "available" {
  count = local.create_network ? 1 : 0
  state = "available"
}

data "aws_subnet" "existing" {
  count = local.create_network ? 0 : 1
  id    = var.existing_subnet_id
}

resource "aws_vpc" "lab" {
  count = local.create_network ? 1 : 0

  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "public" {
  count = local.create_network ? 1 : 0

  vpc_id                  = aws_vpc.lab[0].id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available[0].names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public" }
}

resource "aws_internet_gateway" "lab" {
  count = local.create_network ? 1 : 0

  vpc_id = aws_vpc.lab[0].id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "public" {
  count = local.create_network ? 1 : 0

  vpc_id = aws_vpc.lab[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab[0].id
  }
  tags = { Name = "${var.project_name}-public" }
}

resource "aws_route_table_association" "public" {
  count = local.create_network ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}
