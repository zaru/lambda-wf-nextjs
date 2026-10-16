# Lambda が Connector の ENI を作るときに引き受けるロール（実行ロールとは別）
data "aws_iam_policy_document" "connector_operator_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "connector_operator" {
  name               = "${var.project}-connector-operator"
  assume_role_policy = data.aws_iam_policy_document.connector_operator_assume.json
}

data "aws_iam_policy_document" "connector_operator" {
  statement {
    sid     = "CreateENI"
    actions = ["ec2:CreateNetworkInterface"]
    resources = concat(
      ["arn:aws:ec2:${var.region}:${local.account_id}:network-interface/*"],
      [for subnet in aws_subnet.private : subnet.arn],
      [aws_security_group.web_connector.arn],
    )
  }

  statement {
    sid       = "TagENI"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:ManagedResourceOperator"
      values   = ["network-connectors.lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "connector_operator" {
  name   = "manage-connector-enis"
  role   = aws_iam_role.connector_operator.id
  policy = data.aws_iam_policy_document.connector_operator.json
}

resource "aws_lambdacore_network_connector" "web" {
  name          = "${var.project}-web"
  operator_role = aws_iam_role.connector_operator.arn

  configuration {
    vpc_egress_configuration {
      subnet_ids                        = [for subnet in aws_subnet.private : subnet.id]
      security_group_ids                = [aws_security_group.web_connector.id]
      network_protocol                  = "IPv4"
      associated_compute_resource_types = ["WebFunction"]
    }
  }

  # ENI の作成には最大 10 分ほどかかる
  timeouts {
    create = "20m"
    update = "20m"
    delete = "20m"
  }

  # 権限が付く前に作成が始まると失敗するため
  depends_on = [aws_iam_role_policy.connector_operator]
}
