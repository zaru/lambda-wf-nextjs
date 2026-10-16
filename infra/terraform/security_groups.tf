resource "aws_security_group" "web_connector" {
  name        = "${var.project}-web-connector"
  description = "Lambda Web Function network connector ENIs"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-web-connector" }
}

resource "aws_security_group" "valkey" {
  name        = "${var.project}-valkey"
  description = "ElastiCache Serverless for Valkey"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-valkey" }
}

# 6379: 読み書き、6380: 読み取り専用（ElastiCache Serverless の 2 つのポート）
resource "aws_vpc_security_group_egress_rule" "web_connector_to_valkey" {
  security_group_id            = aws_security_group.web_connector.id
  description                  = "Valkey"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6380
  referenced_security_group_id = aws_security_group.valkey.id
}

# 祝日 API と Secrets Manager（NAT Gateway 経由）
resource "aws_vpc_security_group_egress_rule" "web_connector_https" {
  security_group_id = aws_security_group.web_connector.id
  description       = "HTTPS to the internet via NAT Gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_web_connector" {
  security_group_id            = aws_security_group.valkey.id
  description                  = "From Lambda Web Function"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6380
  referenced_security_group_id = aws_security_group.web_connector.id
}
