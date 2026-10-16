# 既存 VPC とは完全に分離した専用 VPC。ピアリングや Transit Gateway は作らない
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# 既定の SG はルールを空にして、誤って使っても通信できないようにする
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-default-unused" }
}

# Connector の ENI と Valkey を置く
resource "aws_subnet" "private" {
  for_each = { for index, az in var.availability_zones : az => index }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1 + each.value)

  tags = { Name = "${var.project}-private-${each.key}" }
}

# NAT Gateway だけを置く（検証用なので 1 台、先頭の AZ のみ）
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zones[0]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 101)

  tags = { Name = "${var.project}-public-${var.availability_zones[0]}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${var.project}-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway は 1 台なので、Private Subnet は 1 つのルートテーブルを共有する
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
